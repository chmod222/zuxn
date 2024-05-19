const std = @import("std");
const fs = std.fs;

const clap = @import("clap");

const uxn = @import("uxn-core");
const varvara = @import("uxn-varvara");
const shared = @import("uxn-shared");

const Debug = shared.Debug;

const logger = std.log.scoped(.uxn_sdl);

pub const SDL = @cImport({
    @cInclude("SDL2/SDL.h");
});

pub const std_options = .{
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .uxn_cpu, .level = .info },

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

const VarvaraDefault = varvara.VarvaraSystem(std.fs.File.Writer, std.fs.File.Writer);

var AUDIO_FINISHED: u32 = undefined;
var STDIN_RECEIVED: u32 = undefined;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var audio_id: SDL.SDL_AudioDeviceID = undefined;

fn sdl_panic() noreturn {
    const str = @as(?[*:0]const u8, SDL.SDL_GetError()) orelse "unknown error";

    @panic(std.mem.sliceTo(str, 0));
}

fn Callbacks(comptime SystemType: type) type {
    return struct {
        pub fn intercept(
            cpu: *uxn.Cpu,
            addr: u8,
            kind: uxn.Cpu.InterceptKind,
            data: ?*anyopaque,
        ) !void {
            const varvara_sys: ?*SystemType = @alignCast(@ptrCast(data));

            if (varvara_sys) |sys| {
                const lock_audio = kind == .output and addr >= 0x30 and addr < 0x70;

                if (lock_audio) SDL.SDL_LockAudioDevice(audio_id);
                defer if (lock_audio) SDL.SDL_UnlockAudioDevice(audio_id);

                try sys.intercept(cpu, addr, kind);
            }
        }

        pub fn audio_callback(u: ?*anyopaque, stream: [*c]u8, len: c_int) callconv(.C) void {
            const cpu, const sys = @as(
                *struct { *uxn.Cpu, *SystemType },
                @alignCast(@ptrCast(u)),
            ).*;

            var samples_ptr = @as([*c]i16, @alignCast(@ptrCast(stream)));
            var samples = samples_ptr[0 .. @as(usize, @intCast(len)) / 2];

            // TODO: 0x00 should ideally be SDL_AudioSpec.silence here
            @memset(samples, 0x0000);

            for (&sys.audio_devices) |*poly| {
                if (poly.duration <= 0) {
                    poly.evaluate_finish_vector(cpu) catch unreachable;
                }

                poly.update_duration();
                poly.render_audio(samples);
            }

            for (0..samples.len) |i| {
                samples[i] <<= 6;
            }

            //if (still_playing == 0) {
            //    const audio_id: *SDL.SDL_AudioDeviceID = @alignCast(@ptrCast(u.?));
            //
            //    SDL.SDL_PauseAudioDevice(audio_id.*, 1);
            //}
        }

        pub fn receive_stdin(p: ?*anyopaque) callconv(.C) c_int {
            const sys: *SystemType = @alignCast(@ptrCast(p));

            const stdin = std.io.getStdIn().reader();

            var event: SDL.SDL_Event = .{ .type = STDIN_RECEIVED };

            while (sys.system_device.exit_code == null) {
                const b = stdin.readByte() catch
                    break;

                event.cbutton.button = b;

                _ = SDL.SDL_PushEvent(&event);
            }

            return 0;
        }
    };
}

const InputType = union(enum) {
    buttons: varvara.controller.ButtonFlags,
    key: u8,
};

fn determine_input(event: *SDL.SDL_Event) ?InputType {
    const mods = SDL.SDL_GetModState();
    const sym = event.key.keysym.sym;

    if (sym < 0x20 or sym == SDL.SDLK_DELETE) {
        return .{ .key = @intCast(sym) };
    } else if (mods & SDL.KMOD_CTRL > 0) {
        if (sym < SDL.SDLK_a) {
            return .{ .key = @intCast(sym) };
        } else if (sym <= SDL.SDLK_z) {
            return .{ .key = @truncate(@as(u32, @bitCast(sym)) - @as(u32, @bitCast(mods & SDL.KMOD_SHIFT)) * 0x20) };
        }
    }

    switch (event.key.keysym.sym) {
        SDL.SDLK_LCTRL => return .{ .buttons = .{ .ctrl = true } },
        SDL.SDLK_LALT => return .{ .buttons = .{ .alt = true } },
        SDL.SDLK_LSHIFT => return .{ .buttons = .{ .shift = true } },
        SDL.SDLK_HOME => return .{ .buttons = .{ .start = true } },
        SDL.SDLK_UP => return .{ .buttons = .{ .up = true } },
        SDL.SDLK_DOWN => return .{ .buttons = .{ .down = true } },
        SDL.SDLK_LEFT => return .{ .buttons = .{ .left = true } },
        SDL.SDLK_RIGHT => return .{ .buttons = .{ .right = true } },

        else => {},
    }

    return null;
}

fn init_window(
    window: **SDL.SDL_Window,
    renderer: **SDL.SDL_Renderer,
    texture: **SDL.SDL_Texture,
    width: u16,
    height: u16,
    scale: u8,
) !void {
    window.* = SDL.SDL_CreateWindow(
        "zuxn",
        SDL.SDL_WINDOWPOS_CENTERED,
        SDL.SDL_WINDOWPOS_CENTERED,
        width * scale,
        height * scale,
        SDL.SDL_WINDOW_SHOWN,
    ) orelse return error.CouldNotCreateWindow;

    errdefer {
        SDL.SDL_DestroyWindow(window.*);
    }

    renderer.* = SDL.SDL_CreateRenderer(
        window.*,
        -1,
        SDL.SDL_RENDERER_ACCELERATED | SDL.SDL_RENDERER_PRESENTVSYNC,
    ) orelse return error.CouldNotCreateRenderer;

    _ = SDL.SDL_RenderSetLogicalSize(renderer.*, width, height);

    errdefer {
        SDL.SDL_DestroyRenderer(renderer.*);
    }

    texture.* = SDL.SDL_CreateTexture(
        renderer.*,
        SDL.SDL_PIXELFORMAT_RGB888,
        SDL.SDL_TEXTUREACCESS_STREAMING,
        width,
        height,
    ) orelse return error.CouldNotCreateTexture;
}

fn resize_window(
    window: *SDL.SDL_Window,
    renderer: *SDL.SDL_Renderer,
    texture: **SDL.SDL_Texture,
    width: u16,
    height: u16,
    scale: u8,
) !void {
    SDL.SDL_SetWindowSize(
        window,
        width * scale,
        height * scale,
    );

    _ = SDL.SDL_RenderSetLogicalSize(renderer, width, height);

    SDL.SDL_DestroyTexture(texture.*);

    texture.* = SDL.SDL_CreateTexture(
        renderer,
        SDL.SDL_PIXELFORMAT_RGB888,
        SDL.SDL_TEXTUREACCESS_STREAMING,
        width,
        height,
    ) orelse return error.CouldNotCreateTexture;
}

fn draw_screen(
    screen_device: *varvara.screen.Screen,
    system_device: *const varvara.system.System,
    texture: *SDL.SDL_Texture,
    renderer: *SDL.SDL_Renderer,
) void {
    if (screen_device.dirty_region) |region| {
        var pixels: [*c]u8 = undefined;
        var pitch: c_int = undefined;

        if (SDL.SDL_LockTexture(texture, null, @ptrCast(&pixels), &pitch) != 0)
            return;

        defer SDL.SDL_UnlockTexture(texture);

        for (region.y0..region.y1) |y| {
            for (region.x0..region.x1) |x| {
                const idx = y * screen_device.width + x;
                const pal = (@as(u4, screen_device.foreground[idx]) << 2) | screen_device.background[idx];

                const color = &system_device.colors[if ((pal >> 2) > 0) (pal >> 2) else (pal & 0x3)];

                pixels[idx * 4 + 3] = 0x00;
                pixels[idx * 4 + 2] = color.r;
                pixels[idx * 4 + 1] = color.g;
                pixels[idx * 4 + 0] = color.b;
            }
        }

        screen_device.dirty_region = null;
    }

    _ = SDL.SDL_RenderCopy(renderer, texture, null, null);
    SDL.SDL_RenderPresent(renderer);
}

fn main_graphical(
    cpu: *uxn.Cpu,
    system: *VarvaraDefault,
    scale: u8,
    args: [][]const u8,
) !u8 {
    if (SDL.SDL_Init(SDL.SDL_INIT_JOYSTICK | SDL.SDL_INIT_VIDEO | SDL.SDL_INIT_EVENTS | SDL.SDL_INIT_AUDIO) < 0)
        sdl_panic();

    defer SDL.SDL_Quit();

    _ = SDL.SDL_ShowCursor(SDL.SDL_DISABLE);

    var callback_data = .{ cpu, system };

    var audio_spec: SDL.SDL_AudioSpec = .{
        .freq = varvara.audio.sample_rate,
        .format = SDL.AUDIO_S16SYS,
        .channels = 2,
        .callback = &Callbacks(VarvaraDefault).audio_callback,
        .samples = varvara.audio.sample_count,
        .userdata = &callback_data,

        .silence = 0,
        .size = 0,
        .padding = undefined,
    };

    audio_id = SDL.SDL_OpenAudioDevice(null, 0, &audio_spec, null, 0);

    SDL.SDL_PauseAudioDevice(audio_id, 0);

    STDIN_RECEIVED = SDL.SDL_RegisterEvents(1);

    const stdin = SDL.SDL_CreateThread(&Callbacks(VarvaraDefault).receive_stdin, "stdin", system);

    SDL.SDL_DetachThread(stdin);

    _ = SDL.SDL_JoystickOpen(0) orelse {
        logger.debug("Couldn't open joystick {}: {s}", .{ 0, SDL.SDL_GetError() });
    };

    system.console_device.set_argc(cpu, args);

    var window_width = system.screen_device.width;
    var window_height = system.screen_device.height;

    cpu.evaluate_vector(0x0100) catch |fault|
        try system.system_device.handle_fault(cpu, fault);

    system.console_device.push_arguments(cpu, args) catch |fault|
        try system.system_device.handle_fault(cpu, fault);

    if (system.system_device.exit_code) |c|
        return c;

    var window: *SDL.SDL_Window = undefined;
    var renderer: *SDL.SDL_Renderer = undefined;
    var texture: *SDL.SDL_Texture = undefined;

    // Reset vector is done, all arguments are handled and VM did not exit,
    // so we know what our window size should be.
    try init_window(
        &window,
        &renderer,
        &texture,
        system.screen_device.width,
        system.screen_device.height,
        scale,
    );

    main_loop: while (system.system_device.exit_code == null) {
        const t0 = SDL.SDL_GetPerformanceCounter();

        var ev: SDL.SDL_Event = undefined;

        while (SDL.SDL_PollEvent(&ev) != 0) {
            switch (ev.type) {
                SDL.SDL_QUIT => {
                    break :main_loop;
                },

                SDL.SDL_MOUSEMOTION => {
                    system.mouse_device.update_position(
                        cpu,
                        @truncate(@as(c_uint, @bitCast(ev.motion.x))),
                        @truncate(@as(c_uint, @bitCast(ev.motion.y))),
                    ) catch |fault|
                        try system.system_device.handle_fault(cpu, fault);
                },

                SDL.SDL_MOUSEBUTTONDOWN => {
                    system.mouse_device.press_buttons(
                        cpu,
                        @bitCast(@as(u8, 1) << @as(u3, @truncate(ev.button.button - 1))),
                    ) catch |fault|
                        try system.system_device.handle_fault(cpu, fault);
                },

                SDL.SDL_MOUSEBUTTONUP => {
                    system.mouse_device.release_buttons(
                        cpu,
                        @bitCast(@as(u8, 1) << @as(u3, @truncate(ev.button.button - 1))),
                    ) catch |fault|
                        try system.system_device.handle_fault(cpu, fault);
                },

                SDL.SDL_MOUSEWHEEL => {
                    system.mouse_device.update_scroll(cpu, ev.wheel.x, ev.wheel.y) catch |fault|
                        try system.system_device.handle_fault(cpu, fault);
                },

                SDL.SDL_TEXTINPUT => {
                    system.controller_device.press_key(cpu, ev.text.text[0]) catch |fault|
                        try system.system_device.handle_fault(cpu, fault);
                },

                SDL.SDL_KEYDOWN => {
                    if (determine_input(&ev)) |input| switch (input) {
                        .buttons => |b| {
                            system.controller_device.press_buttons(cpu, b, 0) catch |fault|
                                try system.system_device.handle_fault(cpu, fault);
                        },

                        .key => |k| {
                            system.controller_device.press_key(cpu, k) catch |fault|
                                try system.system_device.handle_fault(cpu, fault);
                        },
                    };
                },

                SDL.SDL_KEYUP => {
                    if (determine_input(&ev)) |input| switch (input) {
                        .buttons => |b| {
                            system.controller_device.release_buttons(cpu, b, 0) catch |fault|
                                try system.system_device.handle_fault(cpu, fault);
                        },

                        else => {},
                    };
                },

                SDL.SDL_JOYAXISMOTION => {
                    const player: u2 = @truncate(@as(c_uint, @bitCast(ev.jbutton.which)));

                    _ = player;

                    // TODO
                },

                SDL.SDL_JOYBUTTONDOWN, SDL.SDL_JOYBUTTONUP => b: {
                    const player: u2 = @truncate(@as(c_uint, @bitCast(ev.jbutton.which)));
                    const btn: varvara.controller.ButtonFlags = switch (ev.jbutton.button) {
                        0x0 => .{ .ctrl = true },
                        0x1 => .{ .alt = true },
                        0x06 => .{ .shift = true },
                        0x07 => .{ .start = true },
                        else => break :b,
                    };

                    if (ev.type == SDL.SDL_JOYBUTTONUP)
                        system.controller_device.release_buttons(cpu, btn, player) catch |fault|
                            try system.system_device.handle_fault(cpu, fault)
                    else
                        system.controller_device.press_buttons(cpu, btn, player) catch |fault|
                            try system.system_device.handle_fault(cpu, fault);
                },

                SDL.SDL_JOYHATMOTION => {
                    const player: u2 = @truncate(@as(c_uint, @bitCast(ev.jhat.which)));
                    const btn: varvara.controller.ButtonFlags = switch (ev.jhat.value) {
                        SDL.SDL_HAT_UP => .{ .up = true },
                        SDL.SDL_HAT_DOWN => .{ .down = true },
                        SDL.SDL_HAT_LEFT => .{ .left = true },
                        SDL.SDL_HAT_RIGHT => .{ .right = true },
                        SDL.SDL_HAT_LEFTDOWN => .{ .left = true, .down = true },
                        SDL.SDL_HAT_LEFTUP => .{ .left = true, .up = true },
                        SDL.SDL_HAT_RIGHTDOWN => .{ .right = true, .down = true },
                        SDL.SDL_HAT_RIGHTUP => .{ .right = true, .up = true },
                        else => .{},
                    };

                    // Release all the non-pressed buttons
                    const inverse = .{
                        .up = !btn.up,
                        .down = !btn.down,
                        .left = !btn.left,
                        .right = !btn.right,
                    };

                    system.controller_device.release_buttons(cpu, inverse, player) catch |fault|
                        try system.system_device.handle_fault(cpu, fault);

                    if (@as(u8, @bitCast(btn)) != 0) {
                        system.controller_device.press_buttons(cpu, btn, player) catch |fault|
                            try system.system_device.handle_fault(cpu, fault);
                    }
                },

                else => {
                    if (ev.type == STDIN_RECEIVED) {
                        system.console_device.push_stdin_byte(cpu, ev.cbutton.button) catch |fault|
                            try system.system_device.handle_fault(cpu, fault);
                    }
                },
            }
        }

        const t1 = SDL.SDL_GetPerformanceCounter();
        const frametime = @as(f32, @floatFromInt(t1 - t0)) / @as(f32, @floatFromInt(SDL.SDL_GetPerformanceFrequency())) * 1000.0;

        _ = frametime;

        system.screen_device.evaluate_frame(cpu) catch |fault|
            try system.system_device.handle_fault(cpu, fault);

        if (system.screen_device.width != window_width or system.screen_device.height != window_height) {
            window_height = system.screen_device.height;
            window_width = system.screen_device.width;

            try resize_window(
                window,
                renderer,
                &texture,
                system.screen_device.width,
                system.screen_device.height,
                scale,
            );
        }

        draw_screen(&system.screen_device, &system.system_device, texture, renderer);
    }

    return system.system_device.exit_code orelse 0;
}

pub fn main() !u8 {
    const alloc = gpa.allocator();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help                 Display this help and exit.
        \\-s, --scale <INT>          Display scale factor
        \\-S, --symbols <FILE>       Load debug symbols
        \\<FILE>                     Input ROM
        \\<ARG>...                   Command line arguments for the module
    );

    var diag = clap.Diagnostic{};

    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    var res = clap.parse(clap.Help, &params, shared.parsers, .{
        .diagnostic = &diag,
        .allocator = alloc,
    }) catch |err| {
        // Report useful error and exit
        diag.report(stderr, err) catch {};

        return err;
    };

    defer res.deinit();

    if (shared.handle_common_args(res, params)) |exit| {
        return exit;
    }

    var env = try shared.load_or_assemble_rom(
        alloc,
        res.positionals[0],
        res.args.symbols,
    );

    defer env.deinit();

    // Initialize system devices
    var system = try VarvaraDefault.init(gpa.allocator(), stdout, stderr);
    defer system.deinit();

    if (!system.sandbox_files(fs.cwd())) {
        logger.debug("File implementation does not suport sandboxing", .{});
    }

    // Setup the breakpoint hook if requested
    if (env.debug_symbols) |*d| {
        system.system_device.debug_callback = &Debug.on_debug_hook;
        system.system_device.callback_data = d;
    }

    // Setup CPU and intercepts
    var cpu = uxn.Cpu.init(env.rom);

    cpu.device_intercept = &Callbacks(VarvaraDefault).intercept;
    cpu.callback_data = &system;

    cpu.output_intercepts = varvara.full_intercepts.output;
    cpu.input_intercepts = varvara.full_intercepts.input;

    // Run main
    return main_graphical(&cpu, &system, res.args.scale orelse 1, @constCast(res.positionals[1..]));
}
