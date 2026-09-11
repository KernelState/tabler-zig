//! Supersampled rasterization of Tabler icons.
//!
//! dvui renders TVG strokes with a fixed 1px feather, which undersamples
//! thin (2px @ 24px) outlines at small display sizes. These helpers build
//! the exact same dvui mesh at 4x size, rasterize it on the CPU with
//! per-sample src-over compositing, and box-downsample to the requested
//! size — true 4x SSAA, independent of the backend.
//!
//! The output is tinted non-premultiplied RGBA for use with
//! `dvui.ImageSource.pixels` (which `dvui.image` uploads and caches):
//!
//! ```zig
//! const r = try tabler.outlineRaster(.home, dvui.Size.all(16), dvui.Color.white);
//! dvui.image(@src(), .{ .source = .{ .pixels = .{
//!     .rgba = r.rgba, .width = r.w, .height = r.h,
//! } } }, .{ .min_size_content = .{ .h = 16 } });
//! ```

const std = @import("std");
const dvui = @import("dvui");

/// Supersample factor. 4x measured ~3-4x closer to a reference renderer
/// than dvui's native 1px-feather mesh at 16px.
pub const ssaa: u32 = 4;

/// Tinted, non-premultiplied RGBA, row-major. Dimensions are
/// `ceil(size)`.
pub const Raster = struct {
    rgba: []const u8,
    w: u32,
    h: u32,
};

/// Raster dimensions for `size`.
pub fn dims(size: dvui.Size) struct { w: u32, h: u32 } {
    return .{
        .w = @intFromFloat(@ceil(size.w)),
        .h = @intFromFloat(@ceil(size.h)),
    };
}

/// Convert SVG bytes to a tinted raster, cached per window under
/// `variant-tag-WxH-color`. Repeat calls are free after the first one.
///
/// Only valid between `Window.begin` and `Window.end`. The returned slice
/// is owned by dvui's per-window data store; do not free it. Mesh building
/// needs a window (clip state), so this cannot run headless.
pub fn cached(
    variant: []const u8,
    tag: []const u8,
    svg: []const u8,
    size: dvui.Size,
    tint: dvui.Color,
) !Raster {
    const d = dims(size);
    if (d.w == 0 or d.h == 0) return .{ .rgba = &.{}, .w = d.w, .h = d.h };

    const rgba = tint.toRGBA();
    var key_buf: [256]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "tabler-raster-{s}-{s}-{d}x{d}-{x}{x}{x}{x}", .{
        variant, tag, d.w, d.h, rgba[0], rgba[1], rgba[2], rgba[3],
    }) catch unreachable;
    const id = dvui.Id.zero.update("tabler-raster");
    if (dvui.dataGetSlice(null, id, key, []u8)) |stored| {
        return .{ .rgba = stored, .w = d.w, .h = d.h };
    }

    const win = dvui.currentWindow();
    const tvg = try dvui.svgToTvg(win.arena(), svg);
    defer win.arena().free(tvg);
    const pixels = try rasterizeTvg(win.arena(), tvg, size, tint);
    defer win.arena().free(pixels);
    dvui.dataSetSlice(null, id, key, pixels);
    return .{ .rgba = dvui.dataGetSlice(null, id, key, []u8).?, .w = d.w, .h = d.h };
}

/// Same conversion without the cache. Needs a window for mesh building
/// (clip state) but the caller owns the result and frees `raster.rgba`
/// with `allocator`.
pub fn uncached(
    svg: []const u8,
    size: dvui.Size,
    tint: dvui.Color,
    allocator: std.mem.Allocator,
) !Raster {
    const d = dims(size);
    if (d.w == 0 or d.h == 0) return .{ .rgba = &.{}, .w = d.w, .h = d.h };
    // svgToTvg is pure; the mesh build below needs begin/end clip state.
    const tvg = try dvui.svgToTvg(allocator, svg);
    defer allocator.free(tvg);
    return .{ .rgba = try rasterizeTvg(allocator, tvg, size, tint), .w = d.w, .h = d.h };
}

/// Build dvui's mesh for `tvg` at 4x `size` and rasterize it down to
/// `ceil(size)` tinted RGBA. Caller owns the result.
fn rasterizeTvg(
    allocator: std.mem.Allocator,
    tvg: []const u8,
    size: dvui.Size,
    tint: dvui.Color,
) ![]u8 {
    const d = dims(size);
    if (d.w > 512 or d.h > 512) return error.RasterTooLarge;

    var mesh_arena = std.heap.ArenaAllocator.init(allocator);
    defer mesh_arena.deinit();
    var mesh = dvui.render_tvg.MeshBuilder.init(mesh_arena.allocator());
    defer mesh.deinit();
    // Same overrides dvui.renderIcon uses; geometry (incl. 1px feather,
    // which becomes 4px in raster space) matches dvui exactly.
    try dvui.render_tvg.appendTvg(mesh_arena.allocator(), &mesh, tvg, .{
        .x = 0,
        .y = 0,
        .w = size.w * ssaa,
        .h = size.h * ssaa,
    }, .{
        .fill_color_override = .white,
        .stroke_color_override = .white,
        .keep_aspect = true,
        .fade = 1.0,
    });

    return rasterizeMesh(allocator, &mesh, d.w, d.h, tint);
}

/// CPU rasterize `mesh` ( authored in a `ssaa * (w,h)` rect at its origin)
/// to `w*h` tinted non-premultiplied RGBA with per-sample PMA src-over
/// compositing in mesh order (exactly what the GPU does), then
/// box-downsample. Pure; needs no window.
pub fn rasterizeMesh(
    allocator: std.mem.Allocator,
    mesh: *dvui.render_tvg.MeshBuilder,
    w: u32,
    h: u32,
    tint: dvui.Color,
) ![]u8 {
    const gw: u32 = w * ssaa;
    const gh: u32 = h * ssaa;
    const acc = try allocator.alloc([4]f32, @as(usize, gw) * gh);
    defer allocator.free(acc);
    @memset(acc, .{ 0, 0, 0, 0 });

    const idx = mesh.idx.items;
    var t: usize = 0;
    while (t + 2 < idx.len) : (t += 3) {
        const v0 = mesh.vtx.items[idx[t]];
        const v1 = mesh.vtx.items[idx[t + 1]];
        const v2 = mesh.vtx.items[idx[t + 2]];
        splatTri(acc, gw, gh, v0, v1, v2);
    }

    const out = try allocator.alloc(u8, @as(usize, w) * h * 4);
    var oy: u32 = 0;
    while (oy < h) : (oy += 1) {
        var ox: u32 = 0;
        while (ox < w) : (ox += 1) {
            var sum: [4]f32 = .{ 0, 0, 0, 0 };
            var sy: u32 = 0;
            while (sy < ssaa) : (sy += 1) {
                var sx: u32 = 0;
                while (sx < ssaa) : (sx += 1) {
                    const s = acc[(oy * ssaa + sy) * gw + ox * ssaa + sx];
                    sum[0] += s[0];
                    sum[1] += s[1];
                    sum[2] += s[2];
                    sum[3] += s[3];
                }
            }
            const n: f32 = @floatFromInt(ssaa * ssaa);
            const a = sum[3] / n;
            const o = (oy * w + ox) * 4;
            if (a <= 1e-6) {
                out[o + 0] = 0;
                out[o + 1] = 0;
                out[o + 2] = 0;
                out[o + 3] = 0;
            } else {
                // Un-premultiply (mesh is white, so this recovers coverage),
                // then apply the tint.
                out[o + 0] = @intFromFloat(@round(@as(f32, @floatFromInt(tint.r)) * (sum[0] / n) / a));
                out[o + 1] = @intFromFloat(@round(@as(f32, @floatFromInt(tint.g)) * (sum[1] / n) / a));
                out[o + 2] = @intFromFloat(@round(@as(f32, @floatFromInt(tint.b)) * (sum[2] / n) / a));
                out[o + 3] = @intFromFloat(@round(a * @as(f32, @floatFromInt(tint.a))));
            }
        }
    }
    return out;
}

fn splatTri(
    acc: [][4]f32,
    gw: u32,
    gh: u32,
    v0: dvui.Vertex,
    v1: dvui.Vertex,
    v2: dvui.Vertex,
) void {
    const ax: f32 = v0.pos.x;
    const ay: f32 = v0.pos.y;
    const bx: f32 = v1.pos.x;
    const by: f32 = v1.pos.y;
    const cx: f32 = v2.pos.x;
    const cy: f32 = v2.pos.y;
    const area2 = (bx - ax) * (cy - ay) - (cx - ax) * (by - ay);
    if (@abs(area2) < 1e-9) return;

    const c0 = pma(v0.col);
    const c1 = pma(v1.col);
    const c2 = pma(v2.col);

    var ymin: u32 = @intFromFloat(@max(0, @floor(@min(ay, @min(by, cy)))));
    var ymax: u32 = @intFromFloat(@min(@as(f32, @floatFromInt(gh)), @ceil(@max(ay, @max(by, cy)))));
    var xmin: u32 = @intFromFloat(@max(0, @floor(@min(ax, @min(bx, cx)))));
    var xmax: u32 = @intFromFloat(@min(@as(f32, @floatFromInt(gw)), @ceil(@max(ax, @max(bx, cx)))));
    ymin = @min(ymin, gh);
    ymax = @min(ymax, gh);
    xmin = @min(xmin, gw);
    xmax = @min(xmax, gw);

    var py = ymin;
    while (py < ymax) : (py += 1) {
        var px = xmin;
        while (px < xmax) : (px += 1) {
            const sx: f32 = @as(f32, @floatFromInt(px)) + 0.5;
            const sy: f32 = @as(f32, @floatFromInt(py)) + 0.5;
            const l0 = ((by - cy) * (sx - cx) + (cx - bx) * (sy - cy)) / area2;
            const l1 = ((cy - ay) * (sx - cx) + (ax - cx) * (sy - cy)) / area2;
            const l2 = 1 - l0 - l1;
            if (l0 < -1e-4 or l1 < -1e-4 or l2 < -1e-4) continue;
            const s = acc[py * gw + px];
            const sa = l0 * c0[3] + l1 * c1[3] + l2 * c2[3];
            acc[py * gw + px] = .{
                l0 * c0[0] + l1 * c1[0] + l2 * c2[0] + s[0] * (1 - sa),
                l0 * c0[1] + l1 * c1[1] + l2 * c2[1] + s[1] * (1 - sa),
                l0 * c0[2] + l1 * c1[2] + l2 * c2[2] + s[2] * (1 - sa),
                sa + s[3] * (1 - sa),
            };
        }
    }
}

fn pma(c: dvui.Color.PMA) [4]f32 {
    const inv = 1.0 / 255.0;
    return .{
        @as(f32, @floatFromInt(c.r)) * inv,
        @as(f32, @floatFromInt(c.g)) * inv,
        @as(f32, @floatFromInt(c.b)) * inv,
        @as(f32, @floatFromInt(c.a)) * inv,
    };
}

fn testMesh(gpa: std.mem.Allocator) !dvui.render_tvg.MeshBuilder {
    // 8x8 raster space (a 2x2 icon at 4x). Right triangle covering x+y<=8
    // in white, plus a translucent red triangle on top inside it.
    var mesh = dvui.render_tvg.MeshBuilder.init(gpa);
    const white: dvui.Color.PMA = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const red_half: dvui.Color.PMA = .{ .r = 128, .g = 0, .b = 0, .a = 128 };
    const V = dvui.Vertex;
    try mesh.vtx.appendSlice(gpa, &.{
        V{ .pos = .{ .x = 0, .y = 0 }, .col = white },
        V{ .pos = .{ .x = 8, .y = 0 }, .col = white },
        V{ .pos = .{ .x = 0, .y = 8 }, .col = white },
        V{ .pos = .{ .x = 1, .y = 1 }, .col = red_half },
        V{ .pos = .{ .x = 3, .y = 1 }, .col = red_half },
        V{ .pos = .{ .x = 1, .y = 3 }, .col = red_half },
    });
    try mesh.idx.appendSlice(gpa, &.{ 0, 1, 2, 3, 4, 5 });
    return mesh;
}

test "rasterize: empty mesh is transparent" {
    var mesh = dvui.render_tvg.MeshBuilder.init(std.testing.allocator);
    defer mesh.deinit();
    const out = try rasterizeMesh(std.testing.allocator, &mesh, 4, 4, .white);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(usize, 4 * 4 * 4), out.len);
    for (out) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "rasterize: coverage, src-over order, tint" {
    var mesh = try testMesh(std.testing.allocator);
    defer mesh.deinit();
    const out = try rasterizeMesh(std.testing.allocator, &mesh, 2, 2, .white);
    defer std.testing.allocator.free(out);
    const px = struct {
        fn at(o: []u8, x: u32, y: u32) [4]u8 {
            const i = (y * 2 + x) * 4;
            return .{ o[i], o[i + 1], o[i + 2], o[i + 3] };
        }
    }.at;
    // Top-left block: fully inside the white triangle, with the red
    // triangle composited on top of some samples (mesh order) -> opaque,
    // red-shifted (proves src-over order; reversed order would stay white).
    const tl = px(out, 0, 0);
    try std.testing.expectEqual(@as(u8, 255), tl[3]);
    try std.testing.expectEqual(@as(u8, 255), tl[0]);
    try std.testing.expect(tl[1] > 100 and tl[1] < 255);
    // Bottom-right block: outside both triangles -> transparent.
    const br = px(out, 1, 1);
    try std.testing.expectEqual(@as(u8, 0), br[3]);
    // Top-right block: partially covered -> partial alpha, still white-ish.
    const tr = px(out, 1, 0);
    try std.testing.expect(tr[3] > 0 and tr[3] < 255);
    try std.testing.expect(tr[0] >= tr[3] - 2);
}

test "rasterize: tint applies" {
    var mesh = try testMesh(std.testing.allocator);
    defer mesh.deinit();
    const out = try rasterizeMesh(std.testing.allocator, &mesh, 2, 2, .{ .r = 255, .g = 0, .b = 0 });
    defer std.testing.allocator.free(out);
    const tl = .{ out[0], out[1], out[2], out[3] };
    try std.testing.expectEqual(@as(u8, 255), tl[3]);
    try std.testing.expectEqual(@as(u8, 255), tl[0]);
    try std.testing.expectEqual(@as(u8, 0), tl[1]);
    try std.testing.expectEqual(@as(u8, 0), tl[2]);
}
