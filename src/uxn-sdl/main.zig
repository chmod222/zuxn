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

fn mainGraphical(
    Impl: type,
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

    _ = impl.generic.startStdinReceiver();

    system.console_device.setArgc(cpu, args);

    cpu.evaluateVector(0x0100) catch |fault|
        try system.system_device.handleFault(cpu, fault);

    system.console_device.pushArguments(cpu, args) catch |fault|
        try system.system_device.handleFault(cpu, fault);

    if (system.system_device.exit_code) |code|
        return code;

    // Reset vector is done, all arguments are handled and VM did not exit,
    // so we know what our window size should be.
    try impl.initScreen(scale);

    const target_frametime = 1.0 / @as(f32, @floatFromInt(fps_limit orelse std.math.maxInt(u32)));

    var window_width = system.screen_device.width;
    var window_height = system.screen_device.height; 

    main_loop: while (system.system_device.exit_code == null) {
        const t0 = c.SDL_GetPerformanceCounter();

        if (try impl.pollEvents())
            break :main_loop;

        system.screen_device.evaluateFrame(cpu) catch |fault|
            try system.system_device.handleFault(cpu, fault);

        if (system.screen_device.width != window_width or system.screen_device.height != window_height) {
            window_height = system.screen_device.height;
            window_width = system.screen_device.width;

            logger.info("Resizing\n", .{});
            
            try impl.resizeScreen(scale);
        }

        impl.drawScreen();

        const t1 = c.SDL_GetPerformanceCounter();
        const frametime = @as(f32, @floatFromInt(t1 - t0)) / @as(f32, @floatFromInt(c.SDL_GetPerformanceFrequency()));

        // Frame rendered too quickly, sleep until target framerate is achieved.
        if (frametime < target_frametime) {
            const delay = (target_frametime - frametime) * 1000;

            c.SDL_Delay(@intFromFloat(delay));
        }
    }

    if (system.system_device.exit_code == null) {
        system.system_device.exit_code = 0;
    }

    return system.system_device.exit_code.?;
}

pub fn main(init: std.process.Init) !u8 {
    const alloc = init.gpa;

    const params = comptime clap.parseParamsComptime(
        \\-h, --help                 Display this help and exit.
        \\-s, --scale <INT>          Display scale factor
        \\-r <INT>                   Limit target frames per second to INT (default: unlimited)
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
        &cpu,
        &system,
        @truncate(res.args.scale orelse 1),
        res.args.r,
        @constCast(res.positionals[1]),
    );
}
