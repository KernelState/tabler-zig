const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module: pure compile-time `@embedFile` TVG bytes, zero dependencies.
    // Unreferenced icons are dropped from the final binary, just like dvui.entypo.
    _ = b.addModule("tabler", .{
        .root_source_file = b.path("src/tabler.zig"),
        .target = target,
        .optimize = optimize,
    });

    const dvui_dep = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
    });

    // Regenerate the committed TVG assets + Zig bindings from the
    // tabler-icons submodule, using dvui's own SVG -> TVG converter.
    const generate_exe = b.addExecutable(.{
        .name = "generate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/generate.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "dvui", .module = dvui_dep.module("dvui") },
            },
        }),
    });
    const run_generate = b.addRunArtifact(generate_exe);
    run_generate.addArg(b.path("tabler-icons/icons/outline").getPath(b));
    run_generate.addArg(b.path("tabler-icons/icons/filled").getPath(b));
    run_generate.addArg(b.path("src").getPath(b));
    run_generate.has_side_effects = true;
    const generate_step = b.step("generate", "Regenerate TVG assets and Zig bindings from the tabler-icons submodule");
    generate_step.dependOn(&run_generate.step);

    const lib_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tabler.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
