# tabler-zig

[Tabler icons](https://tabler.io/icons) for [dvui](https://github.com/david-vanderson/dvui),
as compile-time embedded TVG bytes — the same pattern as `dvui.entypo`.

```zig
const tabler = @import("tabler");

dvui.buttonIcon(@src(), "home", tabler.outline.home, .{}, .{}, .{});
dvui.icon(@src(), "home filled", tabler.filled.home, .{}, .{});
```

- `tabler.outline.<name>` — all outline (stroke) icons.
- `tabler.filled.<name>` — all filled (solid) icons.
- Names are Tabler's kebab-case names in snake_case
  (`arrow-big-right` -> `arrow_big_right`).
- Only icons you actually reference end up in your binary.
- Standalone: this package does not wrap or depend on `dvui.entypo`;
  every Tabler icon is included.
- The only dependency is `dvui` itself (for the SVG -> TVG converter
  used at generation time).

## Adding it to your project

In your `build.zig.zon`:

```zig
.dependencies = .{
    .tabler_zig = .{
        .url = "git+https://github.com/<you>/tabler-zig#<commit>",
        .hash = "...",
    },
    // ... your dvui dependency
},
```

In your `build.zig`:

```zig
const tabler_dep = b.dependency("tabler_zig", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("tabler", tabler_dep.module("tabler"));
```

## Regenerating

The `src/outline/*.tvg`, `src/filled/*.tvg` assets and the
`src/outline.zig` / `src/filled.zig` bindings are generated from the
`tabler-icons` submodule with dvui's own converter and committed,
so downstream users don't need the submodule:

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
