//! Layout-driven Tabler icon widget.
//!
//! Unlike `outline()` / `filled()` (which need a developer-chosen `size`
//! up front), this widget takes part in dvui layout like `dvui.icon`: it
//! derives its size from `opts.min_size_content` (falling back to the text
//! height), converts the embedded SVG to TVG on first use for whatever
//! size layout assigns, and caches the TVG per window with dvui's data
//! cache (`dvui.dataGetSlice` / `dvui.dataSetSlice`). A new layout size
//! just selects another cache entry; repeat frames are free.
//!
//! The TVG itself is resolution-independent, so the bytes are identical
//! for every size — `size` only selects the cache entry (and is the size
//! the icon is displayed at). Cache entries are shared with the
//! functional `outline()` / `filled()` API, which uses the same keys.
//!
//! ```zig
//! const tabler = @import("tabler");
//!
//! tabler.outlineIcon(@src(), .home, .{}, .{});
//! tabler.outlineIcon(@src(), .home, .{}, .{ .min_size_content = .{ .h = 16 } });
//! tabler.filledIcon(@src(), .heart, .{}, .{ .min_size_content = dvui.Size.all(24) });
//!
//! if (tabler.outlineIconButton(@src(), .settings, .{}, .{}, .{})) {
//!     // clicked
//! }
//! ```

const std = @import("std");
const dvui = @import("dvui");

/// Which icon set the widget renders. Used for cache keys/ids only.
pub const Variant = enum {
    outline,
    filled,

    pub fn name(self: Variant) []const u8 {
        return @tagName(self);
    }

    /// Same id the functional API uses, so widget and functional
    /// calls share cache entries.
    pub fn cacheId(self: Variant) dvui.Id {
        return switch (self) {
            .outline => dvui.Id.zero.update("tabler-outline"),
            .filled => dvui.Id.zero.update("tabler-filled"),
        };
    }
};

/// Quarter-pixel quantization for cache keys: layout sizes are `f32`,
/// so rounding keeps float noise from exploding the cache while staying
/// far below visible resolution (TVG is resolution-independent anyway).
fn quantize(v: f32) f32 {
    if (v <= 0) return 0;
    return @round(v * 4) / 4;
}

/// Convert `svg` to TVG bytes sized for `size`, cached per window under
/// `tabler-{variant}-{tag}-WxH`. Caller must be between `Window.begin`
/// and `Window.end`; the result is owned by dvui's data store.
fn tvgCached(
    comptime variant: Variant,
    tag: []const u8,
    svg: []const u8,
    size: dvui.Size,
) ![]const u8 {
    const w = quantize(size.w);
    const h = quantize(size.h);
    var key_buf: [256]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "tabler-{s}-{s}-{d}x{d}", .{ variant.name(), tag, w, h }) catch unreachable;
    const id = variant.cacheId();
    if (dvui.dataGetSlice(null, id, key, []u8)) |tvg| return tvg;
    const arena = dvui.currentWindow().arena();
    const tvg = try dvui.svgToTvg(arena, svg);
    defer arena.free(tvg);
    dvui.dataSetSlice(null, id, key, tvg);
    return dvui.dataGetSlice(null, id, key, []u8).?;
}

/// Show a Tabler icon as a dvui widget. Sizing follows `dvui.icon`:
/// `opts.min_size_content` wins (a zero width infers width from height —
/// Tabler icons are square 24x24); otherwise the icon matches the text
/// height. Whatever rect layout assigns is what selects the TVG cache
/// entry and is rendered via `dvui.renderIcon`.
///
/// Never fails: conversion errors are logged and the widget keeps its
/// layout slot (rendering nothing) so a bad icon can't break layout.
pub fn iconWidget(
    src: std.builtin.SourceLocation,
    comptime variant: Variant,
    tag: []const u8,
    svg: []const u8,
    icon_opts: dvui.IconRenderOptions,
    opts: dvui.Options,
) void {
    var size = dvui.Size{};
    if (opts.min_size_content) |msc| {
        // User gave us a min size, use it.
        size = msc;
        if (size.w == 0) {
            // Only a height: Tabler icons are square, so match it.
            size.w = size.h;
        }
    } else {
        // No min size: match the height of text, like dvui.icon.
        const h = opts.fontGet().textHeight();
        size = .{ .w = h, .h = h };
    }

    const defaults = dvui.Options{ .label = .{ .text = tag }, .role = .image };
    var wd = dvui.WidgetData.init(src, .{}, defaults.override(opts).override(.{ .min_size_content = size }));
    wd.register();
    wd.borderAndBackground(.{});

    // Whatever layout actually assigned decides the cache entry.
    const cr = wd.contentRect();
    const actual: dvui.Size = .{
        .w = if (cr.w > 0) cr.w else size.w,
        .h = if (cr.h > 0) cr.h else size.h,
    };
    if (tvgCached(variant, tag, svg, actual)) |tvg| {
        const rs = wd.parent.screenRectScale(wd.contentRect());
        var tex_opts: dvui.RenderTextureOptions = .{ .rotation = wd.options.rotationGet() };

        const white: ?dvui.ColorOrGradient = .white;
        if (std.meta.eql(icon_opts.fill_color, white) and std.meta.eql(icon_opts.stroke_color, white)) {
            // Rasterizing with defaults (white), so colormod to text color.
            tex_opts.colormod = wd.options.color(.text).toColor();
        } else if (wd.options.color_text) |ct| {
            tex_opts.colormod = ct.toColor();
        }

        dvui.renderIcon(tag, tvg, rs, tex_opts, icon_opts) catch |err| {
            dvui.logError(@src(), err, "Could not render icon", .{});
        };
    } else |err| {
        dvui.logError(@src(), err, "Could not convert icon {s}", .{tag});
    }

    wd.minSizeSetAndRefresh();
    wd.minSizeReportToParent();
}

/// Show a Tabler icon as a dvui button. Mirrors `dvui.buttonIcon`, but
/// takes the icon directly: no developer-chosen size, the SVG -> TVG
/// conversion is cached per window (see `iconWidget`). Returns true on
/// click. When `opts.min_size_content` is given it sizes the icon.
pub fn iconButtonWidget(
    src: std.builtin.SourceLocation,
    comptime variant: Variant,
    tag: []const u8,
    svg: []const u8,
    init_opts: dvui.ButtonWidget.InitOptions,
    icon_opts: dvui.IconRenderOptions,
    opts: dvui.Options,
) bool {
    // Set label on the button and clear role on the icon so they don't duplicate.
    const defaults = dvui.Options{ .padding = dvui.Rect.all(4), .label = .{ .text = tag } };
    var bw: dvui.ButtonWidget = undefined;
    bw.init(src, init_opts, defaults.override(opts));
    bw.processEvents();
    bw.drawBackground();

    // When someone passes min_size_content to the button, they want the
    // icon to be that size, so pass it through.
    iconWidget(
        @src(),
        variant,
        tag,
        svg,
        icon_opts,
        opts.strip().override(bw.style()).override(.{
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .min_size_content = opts.min_size_content,
            .expand = .ratio,
            .color_text = opts.color_text,
            .role = .none,
        }),
    );

    const click = bw.clicked();
    bw.drawFocus();
    bw.deinit();
    return click;
}

test {
    @import("std").testing.refAllDecls(@This());
}
