const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const dep_clap = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    });

    // Core library modules
    const core_mod = b.addModule(
        "uxn-core",
        .{
            .source_file = .{
                .path = "src/lib/uxn/lib.zig",
            },
        },
    );

    const varvara_mod = b.addModule(
        "uxn-varvara",
        .{
            .source_file = .{ .path = "src/lib/varvara/lib.zig" },
            .dependencies = &.{.{
                .name = "uxn-core",
                .module = core_mod,
            }},
        },
    );

    const asm_mod = b.addModule(
        "uxn-asm",
        .{
            .source_file = .{ .path = "src/lib/asm/lib.zig" },
            .dependencies = &.{.{
                .name = "uxn-core",
                .module = core_mod,
            }},
        },
    );

    // Utility programs based on core libraries
    const uxn_cli = b.addExecutable(.{
        .name = "uxn-cli",
        .root_source_file = .{ .path = "src/uxn-cli/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    uxn_cli.addModule("uxn-core", core_mod);
    uxn_cli.addModule("uxn-varvara", varvara_mod);
    uxn_cli.linkLibC();

    const uxn_sdl = b.addExecutable(.{
        .name = "uxn-sdl",
        .root_source_file = .{ .path = "src/uxn-sdl/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    uxn_sdl.addModule("uxn-core", core_mod);
    uxn_sdl.addModule("uxn-varvara", varvara_mod);
    uxn_sdl.linkLibC();
    uxn_sdl.linkSystemLibrary("SDL2_image");
    uxn_sdl.linkSystemLibrary("SDL2");

    const uxn_asm = b.addExecutable(.{
        .name = "uxn-asm",
        .root_source_file = .{ .path = "src/uxn-asm/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    uxn_asm.addModule("uxn-asm", asm_mod);
    uxn_asm.addModule("clap", dep_clap.module("clap"));

    b.installArtifact(uxn_sdl);
    b.installArtifact(uxn_cli);
    b.installArtifact(uxn_asm);

    const run_cli_cmd = b.addRunArtifact(uxn_cli);
    const run_sdl_cmd = b.addRunArtifact(uxn_sdl);
    const run_asm_cmd = b.addRunArtifact(uxn_asm);

    run_cli_cmd.step.dependOn(b.getInstallStep());
    run_sdl_cmd.step.dependOn(b.getInstallStep());
    run_asm_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cli_cmd.addArgs(args);
        run_sdl_cmd.addArgs(args);
        run_asm_cmd.addArgs(args);
    }

    const run_cli_step = b.step("run-cli", "Run the CLI evaluator");
    run_cli_step.dependOn(&run_cli_cmd.step);

    const run_sdl_step = b.step("run-sdl", "Run the SDL evaluator");
    run_sdl_step.dependOn(&run_sdl_cmd.step);

    const run_asm_step = b.step("run-asm", "Run the uxn assembler");
    run_asm_step.dependOn(&run_asm_cmd.step);

    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
