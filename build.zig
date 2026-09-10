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

    // The codegen tool links libc (via dvui). On glibc Linux, build it for
    // a glibc version Zig bundles (2.38) instead of the host default: the
    // CRT files newer system toolchains ship (.sframe relocations) break
    // Zig's self-hosted linker. Everywhere else, build for the host.
    const tool_target = if (@import("builtin").os.tag == .linux and @import("builtin").abi == .gnu)
        b.resolveTargetQuery(.{
            .cpu_arch = @import("builtin").cpu.arch,
            .os_tag = .linux,
            .abi = .gnu,
            .glibc_version = .{ .major = 2, .minor = 38, .patch = 0 },
        })
    else
        b.graph.host;

    // Backend-less core module only (no windowing/backend deps needed for
    // SVG -> TVG conversion); dvui wires its own svg2tvg dependency itself.
    const dvui_dep = b.dependency("dvui", .{
        .target = tool_target,
        .optimize = optimize,
        .backend = .custom,
        .libc = true,
    });

    // Regenerate the committed TVG assets + Zig bindings from the
    // tabler-icons submodule, using dvui's own SVG -> TVG converter.
    const generate_exe = b.addExecutable(.{
        .name = "generate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/generate.zig"),
            .target = tool_target,
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
