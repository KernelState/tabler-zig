# tabler-zig

[Tabler icons](https://tabler.io/icons) for [dvui](https://github.com/david-vanderson/dvui):
SVGs embedded at compile time, converted to TVG at runtime.

```zig
const tabler = @import("tabler");

// Layout-driven widget (preferred): size comes from dvui layout, the
// SVG -> TVG conversion is cached per window. Never fails.
tabler.outlineIcon(@src(), .home, .{}, .{});
tabler.outlineIcon(@src(), .home, .{}, .{ .min_size_content = .{ .h = 16 } });

// Icon button, same caching. Returns true on click.
if (tabler.outlineIconButton(@src(), .settings, .{}, .{}, .{})) {
    // clicked
}

// Cached per window; valid between Window.begin/end; do not free.
const tvg = try tabler.outline(.home, dvui.Size.all(16));
dvui.icon(@src(), "home", tvg, .{}, .{ .min_size_content = .{ .h = 16 } });

// Uncached: needs no window, caller owns the result.
const tvg2 = try tabler.filledUncached(.home, dvui.Size.all(16), arena);
defer arena.free(tvg2);
```

- `tabler.outlineIcon(@src(), .name, .{}, opts)` /
  `tabler.filledIcon(@src(), .name, .{}, opts)` — layout-driven widgets.
- `tabler.outlineIconButton(@src(), .name, .{}, .{}, opts)` /
  `tabler.filledIconButton(@src(), .name, .{}, .{}, opts)` — icon buttons,
  same caching, return true on click.
- `tabler.outline(.name, size)` / `tabler.filled(.name, size)` — cached TVG.
- `tabler.outlineUncached(.name, size, allocator)` /
  `tabler.filledUncached(.name, size, allocator)` — uncached TVG.
- `tabler.Outline` / `tabler.Filled` — the icon enums. Names are Tabler's
  kebab-case names in snake_case (`arrow-big-right` -> `.arrow_big_right`).
- `icon` is comptime, so only icons you reference are embedded.
- Sizing/anti-aliasing: TVG is resolution-independent; `size` selects the
  cache entry and is the size you should display at.

## Crisp icons (supersampled raster)

dvui renders TVG strokes with a fixed 1px feather, which undersamples
thin outlines at small sizes. For pixel-clean small icons, rasterize
with true 4x SSAA instead — the dvui mesh is built at 4x size,
rasterized on the CPU and box-downsampled:

```zig
const tabler = @import("tabler");

// Cached per window (repeat calls are free); do not free the result.
const r = try tabler.outlineRaster(.home, dvui.Size.all(16), dvui.Color.white);
dvui.image(@src(), .{ .source = .{ .pixels = .{
    .rgba = r.rgba, .width = r.w, .height = r.h,
} } }, .{ .min_size_content = .{ .h = 16 } });

// Uncached: needs a window for mesh building, caller frees r.rgba.
const r2 = try tabler.filledRasterUncached(.home, size, tint, arena);
defer arena.free(r2.rgba);
```

- `tint` is baked in at raster time (and part of the cache key), because
  `dvui.image` has no tint stage — pass your text color for themed icons.
- `r.w` / `r.h` are `ceil(size)`; `r.rgba` is non-premultiplied RGBA.
- Rule of thumb: TVG functions for large/vector use, raster functions
  for small UI icons where edge quality matters.
- The only dependency is `dvui` itself.

## Adding it to your project

In your `build.zig.zon`:

```zig
.dependencies = .{
    .tabler_zig = .{
        .url = "git+https://github.com/KernelState/tabler-zig",
        .hash = "...",
    },
    // ... your dvui dependency (same version as tabler-zig uses)
},
```

In your `build.zig`:

```zig
const tabler_dep = b.dependency("tabler_zig", .{
    .target = target,
    .optimize = optimize,
    .wire_dvui = false, // inject your own dvui instance below
});
const tabler_mod = tabler_dep.module("tabler");
tabler_mod.addImport("dvui", your_dvui_mod); // single dvui instance
exe.root_module.addImport("tabler", tabler_mod);
```

Injecting your own dvui module guarantees shared types (`dvui.Size`)
and window state (the per-window TVG cache). If you skip this, the
tabler module uses its own backend-less dvui instance.

## Regenerating

The `src/outline/*.svg`, `src/filled/*.svg` assets and the
`src/outline.zig` / `src/filled.zig` bindings are copied/generated from
the `tabler-icons` submodule and committed, so downstream users don't
need the submodule:

```sh
git submodule update --init
zig build generate
zig build test
```

To pick up new upstream icons, bump the submodule and re-run
`zig build generate`.

## License

- Icons: MIT, see [tabler-icons](https://github.com/tabler/tabler-icons/blob/main/LICENSE).
- All other files in this repo: MIT.
