const build_options = @import("build_options");

const std = @import("std");
const posix = std.posix;
const Io = std.Io;

const clap = @import("clap");

const uxn = @import("uxn-core");
const varvara = @import("uxn-varvara");
const shared = @import("uxn-shared");

const c = @import("sdl-sys");
pub const sdl2 = c.SDL_MAJOR_VERSION == 2;

const Debug = shared.Debug;

pub const std_options = std.Options{
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .uxn_cpu, .level = .info },
        .{ .scope = .uxn_sdl, .level = .info },

        .{ .scope = .uxn_varvara, .level = .info },
        .{ .scope = .uxn_varvara_system, .level = .info },
        .{ .scope = .uxn_varvara_console, .level = .info },
        .{ .scope = .uxn_varvara_screen, .level = .info },
        .{ .scope = .uxn_varvara_audio, .level = .info },
        .{ .scope = .uxn_varvara_controller, .level = .info },
        .{ .scope = .uxn_varvara_mouse, .level = .info },
        .{ .scope = .uxn_varvara_file, .level = .info },
        .{ .scope = .uxn_varvara_datetime, .level = .info },
    },
};

const logger = std.log.scoped(.uxn_sdl);

const Event = union(enum) {
    stdin_avail: (Io.File.Reader.Error || Io.Reader.Error)!void,
    frame_timer: Io.Cancelable!void,
    child_out: (Io.File.Reader.Error || Io.Reader.Error)!void,
    child_err: (Io.File.Reader.Error || Io.Reader.Error)!void,
};

fn mainGraphical(
    Impl: type,
    io: Io,
    cpu: *uxn.Cpu,
    system: *varvara.VarvaraDefault,
    scale: u8,
    fps_limit: ?usize,
    args: [][]const u8,
) !u8 {
    var impl = Impl.init(cpu, system);

    try impl.initSdl();
    defer c.SDL_Quit();

    impl.initAudio();
    impl.initJoystick();

    system.console_device.setArgc(cpu, args);

    try cpu.evaluateVector(0x0100);
    try system.console_device.pushArguments(cpu, args);

    if (system.system_device.exit_code) |code|
        return code;

    // Reset vector is done, all arguments are handled and VM did not exit,
    // so we know what our window size should be.
    try impl.initScreen(scale);

    if (system.system_device.fetchMetadata(cpu)) |meta| {
        logger.debug("Loaded ROM version {}: {s}", .{ meta.@"0".version, meta.@"0".text });

        const first_line = if (std.mem.findScalar(u8, meta.@"0".text, '\n')) |idx|
            meta.@"0".text[0..idx]
        else
            meta.@"0".text;

        const title = try system.allocator.dupeSentinel(u8, first_line, 0x00);
        defer system.allocator.free(title);

        _ = c.SDL_SetWindowTitle(impl.window, title);

        var iter = meta.@"1";

        while (iter.next()) |e| {
            if (e.wellKnown(cpu)) |wk| switch (wk) {
                .app_icon => |data| {
                    var icon: [24 * 24]u2 = @splat(0);

                    varvara.screen.Screen.renderTiledSprite(
                        .init(24, 24),
                        .init(0, 0),
                        .init(3, 3),
                        &icon,
                        .{
                            .blending = 1,
                            .two_bpp = true,
                        },
                        data,
                    );

                    const surf = Impl.Generic.renderSprite(system, 24, 24, &icon);
                    defer Impl.Generic.freeSurface(surf);

                    _ = c.SDL_SetWindowIcon(impl.window, surf);
                },

                else => {},
            } else {
                logger.debug(" - Unknown({x}): {x}", .{ e.identifier, e.value });
            }
        }
    }

    const target_frametime = 1.0 / @as(f32, @floatFromInt(fps_limit orelse 60));

    var window_width = system.screen_device.width;
    var window_height = system.screen_device.height;

    var stdin_buffer: [1024]u8 = undefined;
    var uxn_stdin_buffer: [128]u8 = undefined;

    var stdin = Io.File.stdin().reader(io, &stdin_buffer);
    var uxn_stdin = system.console_device.stdin(cpu, &uxn_stdin_buffer);

    var child_stdout_buffer: [1024]u8 = undefined;
    var child_stderr_buffer: [1024]u8 = undefined;

    var last_child_id: ?std.process.Child.Id = null;
    var child_stdout: ?Io.File.Reader = null;
    var child_stderr: ?Io.File.Reader = null;

    main_loop: while (system.system_device.exit_code == null) {
        const t0 = c.SDL_GetPerformanceCounter();

        if (try impl.pollEvents())
            break :main_loop;

        try system.screen_device.evaluateFrame(cpu);

        if (system.screen_device.width != window_width or system.screen_device.height != window_height) {
            window_height = system.screen_device.height;
            window_width = system.screen_device.width;

            try impl.resizeScreen(scale);
        }

        impl.drawScreen();

        // Shouldn’t do this in high performance graphics code, but I hazard that it’s fine for
        // what can be expected of Uxn.
        var events: [4]Event = undefined;
        var select = Io.Select(Event).init(io, &events);

        defer _ = select.cancel();

        select.async(.stdin_avail, fillBuffer, .{ &stdin });

        // Get the active child ID, if any
        const child_id = if (system.console_device.forked_child) |chld|
            chld.id
        else
            null;

        // If the process scope of the open channels has changed, re-open them, otherwise
        // keep them as is so they don’t get reopened after they’re closed and to give the
        // loop a chance to finish reading.
        if (last_child_id != child_id) {
            if (child_stdout == null) {
                child_stdout = system.console_device.childStdout(&child_stdout_buffer);
            }

            if (child_stderr == null) {
                child_stderr = system.console_device.childStderr(&child_stderr_buffer);
            }
        }

        // If channels are open, add them to the set.
        if (child_stdout) |*f|
            select.async(.child_out, fillBuffer, .{ f });

        if (child_stderr) |*f|
            select.async(.child_err, fillBuffer, .{ f });

        const t1 = c.SDL_GetPerformanceCounter();
        const frametime = @as(f32, @floatFromInt(t1 - t0)) / @as(f32, @floatFromInt(c.SDL_GetPerformanceFrequency()));

        // Frame rendered too quickly, sleep until target framerate is achieved.
        const timeout: Io.Timeout = .{
            .duration = .{
                .clock = .real,
                .raw = Io.Duration.fromMilliseconds(@intFromFloat(@max(0, (target_frametime - frametime) * 1000))),
            },
        };

        // Start the frame timer
        select.async(.frame_timer, Io.Timeout.sleep, .{ timeout, io });

        while (true) {
            switch (try select.await()) {
                .frame_timer => {
                    // Frame timer fired, got to go
                    break;
                },

                .stdin_avail => {
                    copyAvailable(&stdin.interface, &uxn_stdin.interface) catch |e| {
                        logger.warn("Failed to stdin to Uxn stdin: {t}", .{e});
                    };

                    // Re-register request
                    select.async(.stdin_avail, fillBuffer, .{ &stdin });
                },

                inline .child_out, .child_err => |result, t| {
                    const stream = if (t == .child_out)
                        &child_stdout.?
                    else
                        &child_stderr.?;

                    if (result) {
                        copyAvailable(&stream.interface, &uxn_stdin.interface) catch |e| {
                            logger.warn("Failed to stream child output to Uxn stdin: {t}", .{e});
                        };

                        // Re-register request
                        select.async(t, fillBuffer, .{ stream });
                    } else |e| {
                        if (e != error.EndOfStream) {
                            logger.warn("{t}: {t}", .{ t, stream.err orelse e });
                        } else {
                            logger.debug("{t}: end of stream", .{t});
                        }

                        last_child_id = child_id;

                        if (t == .child_out) {
                            child_stdout = null;
                        } else {
                            child_stderr = null;
                        }
                    }
                },
            }
        }
    }

    if (system.system_device.exit_code == null) {
        system.system_device.exit_code = 0;
    }

    return system.system_device.exit_code.?;
}

fn fillBuffer(reader: *Io.File.Reader) (Io.File.Reader.Error || Io.Reader.Error)!void {
    reader.interface.fill(1) catch |e| {
        return reader.err orelse e;
    };
}

fn copyAvailable(reader: *Io.Reader, writer: *Io.Writer) (Io.Reader.StreamError || Io.Reader.Error)!void {
    try reader.streamExact(writer, reader.bufferedLen());
    try writer.flush();
}

pub fn main(init: std.process.Init) !u8 {
    const alloc = init.gpa;

    const params = comptime clap.parseParamsComptime(
        \\-h, --help                 Display this help and exit.
        \\-s, --scale <INT>          Display scale factor
        \\-r <INT>                   Limit target frames per second to INT (default: 60)
        \\
    ++ (if (build_options.enable_jit_assembly)
        (shared.jit_assembly_args ++
            \\
            \\-S, --symbols <FILE>       Load debug symbols (argument ignored if self-assembling)
            \\<FILE>                     Input ROM or Tal
            \\
        )
    else
        \\-S, --symbols <FILE>       Load debug symbols
        \\<FILE>                     Input ROM
        \\
    ) ++
        \\<ARG>...                   Command line arguments for the module
    );

    var diag = clap.Diagnostic{};

    var stdout = Io.File.stdout().writer(init.io, &.{});
    var stderr = Io.File.stderr().writer(init.io, &.{});

    var res = clap.parse(clap.Help, &params, shared.parsers, init.minimal.args, .{
        .diagnostic = &diag,
        .allocator = alloc,
    }) catch |err| {
        // Report useful error and exit
        diag.report(&stderr.interface, err) catch {};

        return err;
    };

    defer res.deinit();

    if (shared.handleCommonArgs(init.io, res, params)) |exit| {
        return exit;
    }

    var env = try shared.loadOrAssembleRom(
        alloc,
        init.io,
        res,
        res.positionals[0].?,
        res.args.symbols,
    );

    defer env.deinit();

    // Initialize system devices
    var system = try varvara.VarvaraDefault.init(
        init.gpa,
        init.io,
        init.environ_map,
        &stdout.interface,
        &stderr.interface,
    );
    defer system.deinit();

    if (!system.sandboxFiles(Io.Dir.cwd())) {
        logger.debug("File implementation does not suport sandboxing", .{});
    }

    // Setup the breakpoint hook if requested
    if (env.debug_symbols) |*d| {
        system.system_device.debug_callback = &Debug.onDebugHook;
        system.system_device.callback_data = d;
    }

    // Setup CPU and intercepts
    var cpu = uxn.Cpu.init(env.rom);

    // Run main
    return mainGraphical(
        if (sdl2)
            @import("Sdl2Impl.zig")
        else
            @import("Sdl3Impl.zig"),
        init.io,
        &cpu,
        &system,
        @truncate(res.args.scale orelse 1),
        res.args.r,
        @constCast(res.positionals[1]),
    );
}
