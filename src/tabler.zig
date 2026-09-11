//! Tabler icons (https://tabler.io/icons) for dvui, embedded as SVG and
//! converted to TVG at runtime.
//!
//! ```zig
//! const tabler = @import("tabler");
//!
//! // Cached per window (repeat calls are free after the first conversion).
//! // Valid between Window.begin/end; do not free the result.
//! const tvg = try tabler.outline(.home, dvui.Size.all(16));
//! dvui.icon(@src(), "home", tvg, .{}, .{ .min_size_content = .{ .h = 16 } });
//!
//! // Uncached: needs no window, caller owns the result.
//! const tvg2 = try tabler.filledUncached(.home, dvui.Size.all(16), arena);
//! defer arena.free(tvg2);
//! ```
//!
//! `icon` is comptime, so only icons you reference are embedded in your
//! binary. Names are the Tabler kebab-case names in snake_case
//! (`arrow-big-right` -> `.arrow_big_right`).
//!
//! Sizing/anti-aliasing: TVG is resolution-independent. `size` selects the
//! cache entry and is the size you should display at; dvui renders TVG
//! icons anti-aliased (1px feather, round joins/caps for strokes) and
//! caches the rasterized mesh per display size itself.

const outline_mod = @import("outline.zig");
const filled_mod = @import("filled.zig");
const raster_mod = @import("raster.zig");

pub const Outline = outline_mod.Outline;
pub const Filled = filled_mod.Filled;
pub const Raster = raster_mod.Raster;

pub const outline = outline_mod.outline;
pub const outlineUncached = outline_mod.outlineUncached;
pub const outlineRaster = outline_mod.outlineRaster;
pub const outlineRasterUncached = outline_mod.outlineRasterUncached;
pub const filled = filled_mod.filled;
pub const filledUncached = filled_mod.filledUncached;
pub const filledRaster = filled_mod.filledRaster;
pub const filledRasterUncached = filled_mod.filledRasterUncached;

test {
    @import("std").testing.refAllDecls(@This());
}
