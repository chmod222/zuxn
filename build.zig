const std = @import("std");

const SdlVersion = enum {
    sdl2,
    sdl3,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build Options
    const enable_jit_assembly = b.option(
        bool,
        "enable_jit_assembly",
        \\Enable just in time assembly of Uxntal (increases program size)
        ,
    ) orelse false;

    const sdl_version = b.option(
        SdlVersion,
        "sdl_version",
        \\Which SDL version to link against
        ,
    ) orelse .sdl3;

    const link_libc = b.option(
        bool,
        "link_libc",
        \\Link against system libc (for Varavara device functionality)
        ,
    ) orelse true;

    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_jit_assembly", enable_jit_assembly);

    const dep_clap = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    });

    const files = b.addWriteFiles();

    const uxn_cli = b.addExecutable(.{
        .name = "uxn-cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/uxn-cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = link_libc,
        }),
    });

    // Core library modules
    const core_mod = b.addModule("uxn-core", .{
        .root_source_file = b.path("src/lib/uxn/lib.zig"),
    });

    const varvara_mod = b.addModule("uxn-varvara", .{
        .root_source_file = b.path("src/lib/varvara/lib.zig"),
    });

    varvara_mod.addImport("uxn-core", core_mod);

    if (link_libc) {
        varvara_mod.addImport("sys", b.addTranslateC(.{
            .optimize = optimize,
            .target = target,
            .root_source_file = files.add("sys.h",
                \\#include <time.h>
            ),
        }).createModule());
    }

    const asm_mod = b.addModule("uxn-asm", .{
        .root_source_file = b.path("src/lib/asm/lib.zig"),
        .imports = &.{.{
            .name = "uxn-core",
            .module = core_mod,
        }},
    });

    // Utility programs based on core libraries
    const build_options_mod = build_options.createModule();

    const shared_mod = b.addModule("uxn-shared", .{
        .root_source_file = b.path("src/shared.zig"),
    });

    shared_mod.addImport("uxn-core", core_mod);
    shared_mod.addImport("uxn-asm", asm_mod);
    shared_mod.addImport("clap", dep_clap.module("clap"));
    shared_mod.addImport("build_options", build_options_mod);

    uxn_cli.root_module.addImport("uxn-shared", shared_mod);
    uxn_cli.root_module.addImport("uxn-core", core_mod);
    uxn_cli.root_module.addImport("uxn-varvara", varvara_mod);
    uxn_cli.root_module.addImport("clap", dep_clap.module("clap"));
    uxn_cli.root_module.addImport("build_options", build_options_mod);

    if (enable_jit_assembly)
        uxn_cli.root_module.addImport("uxn-asm", asm_mod);

    if (target.result.cpu.arch != .wasm32 and link_libc) {
        const uxn_sdl = b.addExecutable(.{
            .name = "uxn-sdl",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/uxn-sdl/main.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });

        const c_module = b.addTranslateC(.{
            .optimize = optimize,
            .target = target,
            .root_source_file = files.add("sdl-sys.h", switch (sdl_version) {
                .sdl2 =>
                \\#include <SDL2/SDL.h>
                ,
                .sdl3 =>
                \\#define SDL_DISABLE_OLD_NAMES 1
                \\#include <SDL3/SDL.h>
            }),
        });

        c_module.linkSystemLibrary(switch (sdl_version) {
            .sdl2 => "SDL2",
            .sdl3 => "SDL3",
        }, .{});

        uxn_sdl.root_module.addImport("sdl-sys", c_module.createModule());
        uxn_sdl.root_module.addImport("uxn-shared", shared_mod);
        uxn_sdl.root_module.addImport("uxn-core", core_mod);
        uxn_sdl.root_module.addImport("uxn-varvara", varvara_mod);
        uxn_sdl.root_module.addImport("clap", dep_clap.module("clap"));
        uxn_sdl.root_module.addImport("build_options", build_options_mod);

        if (enable_jit_assembly)
            uxn_sdl.root_module.addImport("uxn-asm", asm_mod);

        b.installArtifact(uxn_sdl);

        const run_sdl_cmd = b.addRunArtifact(uxn_sdl);

        run_sdl_cmd.step.dependOn(b.getInstallStep());

        if (b.args) |args|
            run_sdl_cmd.addArgs(args);

        const run_sdl_step = b.step("run-sdl", "Run the SDL evaluator");
        run_sdl_step.dependOn(&run_sdl_cmd.step);
    }

    const uxn_asm = b.addExecutable(.{
        .name = "uxn-asm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/uxn-asm/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    uxn_asm.root_module.addImport("uxn-asm", asm_mod);
    uxn_asm.root_module.addImport("uxn-shared", shared_mod);
    uxn_asm.root_module.addImport("clap", dep_clap.module("clap"));

    b.installArtifact(uxn_cli);
    b.installArtifact(uxn_asm);

    const run_cli_cmd = b.addRunArtifact(uxn_cli);
    const run_asm_cmd = b.addRunArtifact(uxn_asm);

    run_cli_cmd.step.dependOn(b.getInstallStep());
    run_asm_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cli_cmd.addArgs(args);
        run_asm_cmd.addArgs(args);
    }

    const run_cli_step = b.step("run-cli", "Run the CLI evaluator");
    run_cli_step.dependOn(&run_cli_cmd.step);

    const run_asm_step = b.step("run-asm", "Run the uxn assembler");
    run_asm_step.dependOn(&run_asm_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
