const std = @import("std");

const SdlVersion = enum {
    sdl2,
    sdl3,
};

pub fn build(b: *std.Build) !void {
    var target_query = std.Target.Query{};

    if (target_query.cpu_arch == .wasm32) {
        target_query.cpu_features_add = std.Target.wasm.featureSet(&.{
            .atomics,
            .bulk_memory,
        });
    }

    const target = b.standardTargetOptions(.{
        .default_target = target_query,
    });

    const optimize = b.standardOptimizeOption(.{});

    // Build Options
    const link_libc = b.option(
        bool,
        "link_libc",
        \\Link against system libc (for Varavara device functionality)
        ,
    ) orelse (target.result.os.tag != .freestanding);

    // Core library modules
    const core = b.addModule("uxn-core", .{
        .root_source_file = b.path("src/lib/uxn/lib.zig"),
        // .target = target,
    });

    const varvara = b.addModule("uxn-varvara", .{
        .root_source_file = b.path("src/lib/varvara/lib.zig"),
        .imports = &.{
            .{ .name = "uxn-core", .module = core },
        },
    });

    const assembler = b.addModule("uxn-asm", .{
        .root_source_file = b.path("src/lib/asm/lib.zig"),
        .imports = &.{
            .{ .name = "uxn-core", .module = core },
        },
    });

    const files = b.addWriteFiles();
    const translate_c = b.dependency("translate_c", .{});

    if (link_libc) {
        const translator = @import("translate_c").Translator.init(translate_c, .{
            .c_source_file = files.add("sys.h",
                \\#include <time.h>
            ),
            .optimize = optimize,
            .target = target,
        });

        varvara.addImport("sys", translator.mod);
    }

    if (link_libc or target.result.cpu.arch == .wasm32) {
        const libuxn_mod = b.addModule("libuxn", .{
            .root_source_file = b.path("src/libuxn-c/core.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = link_libc and target.result.cpu.arch != .wasm32,
            .imports = &.{
                .{ .name = "uxn-core", .module = core },
            },
        });

        const libuxn_asm_mod = b.addModule("libuxn-asm", .{
            .root_source_file = b.path("src/libuxn-c/asm.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = link_libc and target.result.cpu.arch != .wasm32,
            .imports = &.{
                .{ .name = "uxn-asm", .module = assembler },
            },
        });

        const libuxn = b.addLibrary(.{
            .name = "uxn-c",
            .root_module = libuxn_mod,
        });

        const libuxn_asm = b.addLibrary(.{
            .name = "uxn-asm-c",
            .root_module = libuxn_asm_mod,
        });

        b.installArtifact(libuxn);
        b.installArtifact(libuxn_asm);
    }

    // Utility programs based on core libraries
    if (target.result.cpu.arch != .wasm32) x: {
        const build_cli = b.option(bool, "build_cli", "Build the standalone CLI emulator") orelse true;
        const build_sdl = b.option(bool, "build_sdl", "Build the standalone SDL emulator") orelse true;
        const build_asm = b.option(bool, "build_asm", "Build the standalone assembler") orelse true;

        if (!build_cli and !build_sdl and !build_asm) {
            // Skip this entire block if nothing will be built.
            break :x {};
        }

        const enable_jit_assembly = b.option(
            bool,
            "enable_jit_assembly",
            \\Enable just in time assembly of Uxntal (increases program size)
            ,
        ) orelse false;

        const build_options = b.addOptions();
        build_options.addOption(bool, "enable_jit_assembly", enable_jit_assembly);

        // Clap needed by all three binaries
        const clap = try b.dependencyLazy("clap", .{});

        // Shared between CLI and SDL
        const build_options_mod = build_options.createModule();

        const shared_mod = b.createModule(.{
            .root_source_file = b.path("src/shared.zig"),
        });

        shared_mod.addImport("uxn-core", core);
        shared_mod.addImport("uxn-asm", assembler);
        shared_mod.addImport("clap", clap.module("clap"));
        shared_mod.addImport("build_options", build_options_mod);

        if (build_cli) {
            // Text-only CLI environment
            const uxn_cli = b.addExecutable(.{
                .name = "uxn-cli",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/uxn-cli/main.zig"),
                    .target = target,
                    .optimize = optimize,
                    .link_libc = link_libc,
                    .imports = &.{
                        .{ .name = "uxn-shared", .module = shared_mod },
                        .{ .name = "uxn-core", .module = core },
                        .{ .name = "uxn-varvara", .module = varvara },
                        .{ .name = "clap", .module = clap.module("clap") },
                        .{ .name = "build_options", .module = build_options_mod },
                    },
                }),
            });

            if (enable_jit_assembly) {
                uxn_cli.root_module.addImport("uxn-asm", assembler);
            }

            b.installArtifact(uxn_cli);

            const run_cli_cmd = b.addRunArtifact(uxn_cli);
            const run_cli_step = b.step("run-cli", "Run the CLI evaluator");

            run_cli_cmd.step.dependOn(b.getInstallStep());
            run_cli_step.dependOn(&run_cli_cmd.step);
            run_cli_cmd.addPassthruArgs();
        }

        if (build_sdl and link_libc) {
            const sdl_version = b.option(
                SdlVersion,
                "sdl_version",
                "Which SDL version to link against",
            ) orelse .sdl3;

            // Graphical SDL environment
            const translator = @import("translate_c").Translator.init(translate_c, .{
                .c_source_file = files.add("sdl-sys.h", switch (sdl_version) {
                    .sdl2 =>
                    \\#define SDL_DISABLE_ARM_NEON_H 1
                    \\#include <SDL2/SDL.h>
                    ,
                    .sdl3 =>
                    \\#define SDL_DISABLE_OLD_NAMES 1
                    \\#include <SDL3/SDL.h>
                }),
                .optimize = optimize,
                .target = target,
                .link_system_libs = &.{
                    .{
                        .name = switch (sdl_version) {
                            .sdl2 => "SDL2",
                            .sdl3 => "SDL3",
                        },
                    },
                },
            });

            const uxn_sdl = b.addExecutable(.{
                .name = "uxn-sdl",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/uxn-sdl/main.zig"),
                    .target = target,
                    .optimize = optimize,
                    .link_libc = true,
                    .imports = &.{
                        .{ .name = "sdl-sys", .module = translator.mod },
                        .{ .name = "uxn-shared", .module = shared_mod },
                        .{ .name = "uxn-core", .module = core },
                        .{ .name = "uxn-varvara", .module = varvara },
                        .{ .name = "clap", .module = clap.module("clap") },
                        .{ .name = "build_options", .module = build_options_mod },
                    },
                }),
            });

            if (enable_jit_assembly) {
                uxn_sdl.root_module.addImport("uxn-asm", assembler);
            }

            b.installArtifact(uxn_sdl);

            const run_sdl_cmd = b.addRunArtifact(uxn_sdl);
            const run_sdl_step = b.step("run-sdl", "Run the SDL evaluator");

            run_sdl_cmd.step.dependOn(b.getInstallStep());
            run_sdl_step.dependOn(&run_sdl_cmd.step);
            run_sdl_cmd.addPassthruArgs();
        }

        if (build_asm) {
            const uxn_asm = b.addExecutable(.{
                .name = "uxn-asm",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/uxn-asm/main.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "uxn-asm", .module = assembler },
                        .{ .name = "uxn-shared", .module = shared_mod },
                        .{ .name = "clap", .module = clap.module("clap") },
                    },
                }),
            });

            b.installArtifact(uxn_asm);

            const run_asm_cmd = b.addRunArtifact(uxn_asm);
            const run_asm_step = b.step("run-asm", "Run the uxn assembler");

            run_asm_cmd.step.dependOn(b.getInstallStep());
            run_asm_step.dependOn(&run_asm_cmd.step);
            run_asm_cmd.addPassthruArgs();
        }
    } else {
        const uxn_vm = b.addExecutable(.{
            .name = "uxn-core",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/uxn-wasm/root.zig"),
                .target = target,
                .optimize = optimize,

                .imports = &.{
                    .{ .name = "uxn-core", .module = core },
                    .{ .name = "uxn-varvara", .module = varvara },
                },
            }),
        });

        uxn_vm.entry = .disabled;
        uxn_vm.rdynamic = true;
        uxn_vm.import_memory = true;
        uxn_vm.stack_size = std.wasm.page_size;

        b.installArtifact(uxn_vm);
    }

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
