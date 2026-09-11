//! Regenerate the committed SVG assets and Zig bindings from the
//! tabler-icons submodule.
//!
//! Usage (paths are passed by build.zig, all absolute):
//!     generate <outline-svg-dir> <filled-svg-dir> <src-out-dir>
//!
//! For each `<name>.svg` it copies the SVG to
//! `<src-out-dir>/<variant>/<name>.svg` and emits
//! `<src-out-dir>/<variant>.zig` containing:
//!   - `Outline` / `Filled` enum with one variant per icon
//!     (`arrow-big-right` -> `arrow_big_right`, keywords quoted),
//!   - `outline()` / `filled()` returning runtime-converted TVG bytes,
//!     cached per window (plus `outlineUncached()` / `filledUncached()`),
//!   - the `icon` parameter is `comptime`, so only icons you reference
//!     are embedded in your binary.
//!
//! Only dvui is imported here; its build wires its internal svg2tvg
//! dependency itself, so this package needs no other dependency.

const std = @import("std");

const Icon = struct {
    /// Enum variant name, e.g. `arrow_big_right` (or `@"switch"`).
    zig_name: []const u8,
    /// Original file stem, e.g. `arrow-big-right`.
    file_stem: []const u8,
};

const Variant = struct {
    /// "outline" / "filled".
    name: []const u8,
    /// "Outline" / "Filled".
    type_name: []const u8,
    /// "outline" / "filled" (function names).
    fn_name: []const u8,
    svg_dir: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(gpa);
    if (args.len != 4) {
        std.debug.print("Usage: generate <outline-svg-dir> <filled-svg-dir> <src-out-dir>\n", .{});
        std.process.exit(2);
    }

    const variants = [_]Variant{
        .{ .name = "outline", .type_name = "Outline", .fn_name = "outline", .svg_dir = args[1] },
        .{ .name = "filled", .type_name = "Filled", .fn_name = "filled", .svg_dir = args[2] },
    };
    const src_out_dir = args[3];

    for (variants) |variant| {
        const count = try generateVariant(gpa, io, variant, src_out_dir);
        std.debug.print("{s}: {d} icons\n", .{ variant.name, count });
    }
}

fn generateVariant(
    gpa: std.mem.Allocator,
    io: std.Io,
    variant: Variant,
    src_out_dir: []const u8,
) !usize {
    var svg_src_dir = try std.Io.Dir.openDirAbsolute(io, variant.svg_dir, .{ .iterate = true });
    defer svg_src_dir.close(io);

    var src_dir = try std.Io.Dir.openDirAbsolute(io, src_out_dir, .{});
    defer src_dir.close(io);
    var svg_out_dir = try std.Io.Dir.createDirPathOpen(src_dir, io, variant.name, .{});
    defer svg_out_dir.close(io);

    var icons: std.ArrayList(Icon) = .empty;

    var it = svg_src_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".svg")) continue;
        const stem = entry.name[0 .. entry.name.len - ".svg".len];

        const svg_bytes = try readFileAlloc(io, svg_src_dir, gpa, entry.name);
        try writeFile(io, svg_out_dir, entry.name, svg_bytes);

        try icons.append(gpa, .{
            .zig_name = try zigName(gpa, stem),
            .file_stem = try gpa.dupe(u8, stem),
        });
    }

    std.mem.sort(Icon, icons.items, {}, iconLessThan);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;
    try w.print(
        \\/// Tabler {s} icons (https://tabler.io/icons) for dvui.
        \\///
        \\/// Generated from the tabler-icons submodule via `zig build generate`.
        \\/// Do not edit by hand.
        \\const std = @import("std");
        \\const dvui = @import("dvui");
        \\///
        \\/// Every icon, as an enum variant (`arrow-big-right` -> `arrow_big_right`).
        \\pub const {s} = enum {{
        \\
    , .{ variant.name, variant.type_name });
    for (icons.items) |icon| {
        try w.print("    {s},\n", .{icon.zig_name});
    }
    try w.writeAll("};\n\n");
    try w.print(
        \\/// SVG source for `icon`, embedded at compile time.
        \\/// Only icons you reference end up in your binary (`icon` is comptime).
        \\fn svg(comptime icon: {s}) []const u8 {{
        \\    return switch (icon) {{
        \\
    , .{variant.type_name});
    for (icons.items) |icon| {
        try w.print("        .{s} => @embedFile(\"{s}/{s}.svg\"),\n", .{ icon.zig_name, variant.name, icon.file_stem });
    }
    try w.writeAll("    };\n}\n\n");
    try w.print(
        \\/// Convert `icon` to TVG bytes sized for `size`, cached per window so
        \\/// repeat calls are free after the first conversion.
        \\///
        \\/// The TVG is resolution-independent; `size` selects the cache entry and
        \\/// is the size you should display it at (e.g. `min_size_content`). dvui
        \\/// renders TVG icons anti-aliased (1px feather, round joins/caps for
        \\/// strokes) and caches the rasterized mesh per display size itself.
        \\///
        \\/// Only valid between `Window.begin` and `Window.end`. The returned
        \\/// slice is owned by dvui's per-window data store; do not free it.
        \\pub fn {s}(comptime icon: {s}, size: dvui.Size) ![]const u8 {{
        \\    const tag = @tagName(icon);
        \\    var key_buf: [256]u8 = undefined;
        \\    const key = std.fmt.bufPrint(&key_buf, "tabler-{s}-{{s}}-{{d}}x{{d}}", .{{ tag, size.w, size.h }}) catch unreachable;
        \\    const id = dvui.Id.zero.update("tabler-{s}");
        \\    if (dvui.dataGetSlice(null, id, key, []u8)) |tvg| return tvg;
        \\    const arena = dvui.currentWindow().arena();
        \\    const tvg = try dvui.svgToTvg(arena, svg(icon));
        \\    defer arena.free(tvg);
        \\    dvui.dataSetSlice(null, id, key, tvg);
        \\    return dvui.dataGetSlice(null, id, key, []u8).?;
        \\}}
        \\///
        \\/// Same conversion without the cache. Needs no window; the caller owns
        \\/// the returned slice and must free it with `allocator`.
        \\pub fn {s}Uncached(comptime icon: {s}, size: dvui.Size, allocator: std.mem.Allocator) ![]const u8 {{
        \\    // TVG is resolution-independent, so the bytes don't depend on size;
        \\    // it is kept for symmetry with `{s}` (and the size you display at).
        \\    _ = size;
        \\    return try dvui.svgToTvg(allocator, svg(icon));
        \\}}
        \\// Smoke-test a few icons through the uncached path (needs no window).
        \\test {{
        \\    const size = dvui.Size.all(16);
        \\    inline for (.{{
    , .{ variant.fn_name, variant.type_name, variant.fn_name, variant.fn_name, variant.fn_name, variant.type_name, variant.fn_name });
    try w.writeAll("\n");
    for (icons.items[0..@min(4, icons.items.len)]) |icon| {
        try w.print("        {s}.{s},\n", .{ variant.type_name, icon.zig_name });
    }
    try w.print(
        \\    }}) |icon| {{
        \\        const tvg = try {s}Uncached(icon, size, std.testing.allocator);
        \\        defer std.testing.allocator.free(tvg);
        \\        try std.testing.expect(tvg.len > 2);
        \\        try std.testing.expectEqualStrings("rV", tvg[0..2]);
        \\    }}
        \\}}
        \\
    , .{variant.fn_name});

    const zig_file_name = try std.mem.concat(gpa, u8, &.{ variant.name, ".zig" });
    try writeFile(io, src_dir, zig_file_name, aw.written());

    return icons.items.len;
}

fn readFileAlloc(io: std.Io, dir: std.Io.Dir, gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    var file = try dir.openFile(io, name, .{});
    defer file.close(io);
    var buf: [8192]u8 = undefined;
    var reader = file.reader(io, &buf);
    return reader.interface.allocRemaining(gpa, .limited(8 * 1024 * 1024));
}

fn writeFile(io: std.Io, dir: std.Io.Dir, name: []const u8, data: []const u8) !void {
    var file = try dir.createFile(io, name, .{});
    defer file.close(io);
    var buf: [8192]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll(data);
    try writer.interface.flush();
}

fn iconLessThan(_: void, a: Icon, b: Icon) bool {
    return std.mem.order(u8, a.zig_name, b.zig_name) == .lt;
}

/// `arrow-big-right` -> `arrow_big_right`; Zig keywords become `@"..."`.
fn zigName(gpa: std.mem.Allocator, stem: []const u8) ![]const u8 {
    const snake = try gpa.dupe(u8, stem);
    for (snake) |*c| {
        if (c.* == '-') c.* = '_';
    }
    if (isZigKeyword(snake)) {
        return try std.mem.concat(gpa, u8, &.{ "@\"", snake, "\"" });
    }
    return snake;
}

fn isZigKeyword(s: []const u8) bool {
    const keywords = [_][]const u8{
        "addrspace", "align",     "allowzero", "and",       "anyframe", "anytype",
        "asm",       "async",     "await",     "break",     "catch",    "comptime",
        "const",     "continue",  "defer",     "else",      "enum",     "errdefer",
        "error",     "export",    "extern",    "fn",        "for",      "if",
        "import",    "in",        "inline",    "linksection", "naked",  "noalias",
        "noinline",  "never",     "none",      "noreturn",  "null",     "or",
        "orelse",    "packed",    "pub",       "resume",    "return",   "struct",
        "suspend",   "switch",    "test",      "threadlocal", "try",    "undefined",
        "union",     "unreachable", "usingnamespace", "var", "void",    "volatile",
        "while",
    };
    for (keywords) |kw| if (std.mem.eql(u8, s, kw)) return true;
    return false;
}
