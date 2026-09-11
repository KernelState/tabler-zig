# tabler-zig

[Tabler icons](https://tabler.io/icons) for [dvui](https://github.com/david-vanderson/dvui):
SVGs embedded at compile time, converted to TVG at runtime.

```zig
const tabler = @import("tabler");

// Cached per window; valid between Window.begin/end; do not free.
const tvg = try tabler.outline(.home, dvui.Size.all(16));
dvui.icon(@src(), "home", tvg, .{}, .{ .min_size_content = .{ .h = 16 } });

// Uncached: needs no window, caller owns the result.
const tvg2 = try tabler.filledUncached(.home, dvui.Size.all(16), arena);
defer arena.free(tvg2);
```

- `tabler.outline(.name, size)` / `tabler.filled(.name, size)` — cached TVG.
- `tabler.outlineUncached(.name, size, allocator)` /
  `tabler.filledUncached(.name, size, allocator)` — uncached TVG.
- `tabler.Outline` / `tabler.Filled` — the icon enums. Names are Tabler's
  kebab-case names in snake_case (`arrow-big-right` -> `.arrow_big_right`).
- `icon` is comptime, so only icons you reference are embedded.
- Sizing/anti-aliasing: TVG is resolution-independent; `size` selects the
  cache entry and is the size you should display at. dvui renders TVG
  icons anti-aliased (1px feather, round joins/caps for strokes) and
  caches the rasterized mesh per display size itself.
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
