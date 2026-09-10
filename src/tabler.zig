//! Tabler icons (https://tabler.io/icons) for dvui as compile-time TVG bytes.
//!
//! Use `tabler.outline.<name>` or `tabler.filled.<name>` anywhere dvui
//! takes TVG bytes, e.g. `dvui.icon` or `dvui.buttonIcon`:
//!
//! ```zig
//! const tabler = @import("tabler");
//!
//! dvui.buttonIcon(@src(), "home", tabler.outline.home, .{}, .{}, .{});
//! dvui.icon(@src(), "home filled", tabler.filled.home, .{}, .{});
//! ```
//!
//! Names are the Tabler kebab-case names in snake_case
//! (`arrow-big-right` -> `arrow_big_right`). Only icons you actually
//! reference are embedded in your binary, just like `dvui.entypo`.

pub const outline = @import("outline.zig");
pub const filled = @import("filled.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
