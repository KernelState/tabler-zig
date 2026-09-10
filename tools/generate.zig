//! Regenerate the committed TVG assets and Zig bindings from the
//! tabler-icons submodule.
//!
//! Usage (paths are passed by build.zig, all absolute):
//!     generate <outline-svg-dir> <filled-svg-dir> <src-out-dir>
//!
//! For each `<name>.svg` it writes `<src-out-dir>/<variant>/<name>.tvg`
//! via dvui's own SVG -> TVG converter, plus `<src-out-dir>/<variant>.zig`
//! with one `pub const <snake_case> = @embedFile(...)` per icon
//! (mirroring how dvui.entypo exposes its icons).
//!
//! Only dvui is imported here; its build wires its internal svg2tvg
//! dependency itself, so this package needs no other dependency.

const std = @import("std");
const dvui = @import("dvui");

const Icon = struct {
    /// Zig identifier, e.g. `arrow_big_right` (or `@"switch"` for keywords).
    zig_name: []const u8,
    /// Original file stem, e.g. `arrow-big-right`.
    file_stem: []const u8,
};

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    if (args.len != 4) {
        std.debug.print("Usage: generate <outline-svg-dir> <filled-svg-dir> <src-out-dir>\n", .{});
        std.process.exit(2);
    }
    const outline_svg_dir = args[1];
    const filled_svg_dir = args[2];
    const src_out_dir = args[3];

    var failed: usize = 0;
    var outline_count: usize = 0;
    var filled_count: usize = 0;

    outline_count = try generateVariant(gpa, outline_svg_dir, src_out_dir, "outline", &failed);
    filled_count = try generateVariant(gpa, filled_svg_dir, src_out_dir, "filled", &failed);

    std.debug.print("outline: {d} icons, filled: {d} icons, failed: {d}\n", .{ outline_count, filled_count, failed });
    if (failed > 0) std.process.exit(1);
}

fn generateVariant(
    gpa: std.mem.Allocator,
    svg_dir_path: []const u8,
    src_out_dir: []const u8,
    variant: []const u8,
    failed: *usize,
) !usize {
    var svg_dir = try std.fs.openDirAbsolute(svg_dir_path, .{ .iterate = true });
    defer svg_dir.close();

    var icons: std.ArrayList(Icon) = .empty;
    defer {
        for (icons.items) |icon| {
            gpa.free(icon.zig_name);
            gpa.free(icon.file_stem);
        }
        icons.deinit(gpa);
    }

    // TVG output dir, e.g. <src>/outline.
    const tvg_dir_path = try std.fs.path.join(gpa, &.{ src_out_dir, variant });
    defer gpa.free(tvg_dir_path);
    try std.fs.cwd().makePath(tvg_dir_path);
    var tvg_dir = try std.fs.openDirAbsolute(tvg_dir_path, .{});
    defer tvg_dir.close();

    var it = svg_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".svg")) continue;
        const stem = entry.name[0 .. entry.name.len - ".svg".len];

        const svg_bytes = try svg_dir.readFileAlloc(gpa, entry.name, 4 * 1024 * 1024);
        defer gpa.free(svg_bytes);

        const tvg_bytes = dvui.svgToTvg(gpa, svg_bytes) catch |err| {
            std.debug.print("FAILED {s}/{s}: {s}\n", .{ variant, entry.name, @errorName(err) });
            failed.* += 1;
            continue;
        };
        defer gpa.free(tvg_bytes);

        const tvg_name = try std.mem.concat(gpa, u8, &.{ stem, ".tvg" });
        defer gpa.free(tvg_name);
        try tvg_dir.writeFile(.{ .sub_path = tvg_name, .data = tvg_bytes });

        try icons.append(gpa, .{
            .zig_name = try zigName(gpa, stem),
            .file_stem = try gpa.dupe(u8, stem),
        });
    }

    std.mem.sort(Icon, icons.items, {}, iconLessThan);

    var zig = std.ArrayList(u8).empty;
    defer zig.deinit(gpa);
    const w = zig.writer(gpa);
    try w.print(
        \\/// Tabler {s} icons (https://tabler.io/icons) as compile-time TVG bytes.
        \\///
        \\/// Generated from the tabler-icons submodule via `zig build generate`.
        \\/// Do not edit by hand. Only icons you reference end up in your binary.
        \\
        \\
    , .{variant});
    for (icons.items) |icon| {
        try w.print("pub const {s} = @embedFile(\"{s}/{s}.tvg\");\n", .{ icon.zig_name, variant, icon.file_stem });
    }
    try w.writeAll(
        \\
        \\test {
        \\    @import("std").testing.refAllDecls(@This());
        \\}
        \\
    );

    const zig_file_name = try std.mem.concat(gpa, u8, &.{ variant, ".zig" });
    defer gpa.free(zig_file_name);
    const zig_path = try std.fs.path.join(gpa, &.{ src_out_dir, zig_file_name });
    defer gpa.free(zig_path);
    try std.fs.cwd().writeFile(.{ .sub_path = zig_path, .data = zig.items });

    return icons.items.len;
}

fn iconLessThan(_: void, a: Icon, b: Icon) bool {
    return std.mem.order(u8, a.zig_name, b.zig_name) == .lt;
}

/// `arrow-big-right` -> `arrow_big_right`; Zig keywords become `@"..."`.
fn zigName(gpa: std.mem.Allocator, stem: []const u8) ![]const u8 {
    const snake = try gpa.dupe(u8, stem);
    for (snake) |*c| if (c.* == '-') c.* = '_';
    if (isZigKeyword(snake)) {
        const quoted = try std.mem.concat(gpa, u8, &.{ "@\"", snake, "\"" });
        gpa.free(snake);
        return quoted;
    }
    return snake;
}

fn isZigKeyword(s: []const u8) bool {
    const keywords = [_][]const u8{
        "addrspace",   "align",     "allowzero", "and",      "anyframe", "anytype",
        "asm",         "async",     "await",     "break",    "catch",    "comptime",
        "const",       "continue",  "defer",     "else",     "enum",     "errdefer",
        "error",       "export",    "extern",    "fn",       "for",      "if",
        "import",      "in",        "inline",    "linksection", "naked", "noalias",
        "noinline",    "never",     "none",      "noreturn", "null",     "or",
        "orelse",      "packed",    "pub",       "resume",   "return",   "struct",
        "suspend",     "switch",    "test",      "threadlocal", "try",   "undefined",
        "union",       "unreachable", "usingnamespace", "var", "void",   "volatile",
        "while",
    };
    for (keywords) |kw| if (std.mem.eql(u8, s, kw)) return true;
    return false;
}
