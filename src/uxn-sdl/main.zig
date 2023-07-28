const std = @import("std");

const clap = @import("clap");

const uxn = @import("uxn-core");
const varvara = @import("uxn-varvara");

const File = std.fs.File;
const Allocator = std.mem.Allocator;

pub const SDL = @cImport({
    @cInclude("SDL2/SDL.h");
});

var AUDIO_FINISHED: u32 = undefined;
var STDIN_RECEIVED: u32 = undefined;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var system: varvara.VarvaraSystem = undefined;
var audio_id: SDL.SDL_AudioDeviceID = undefined;

fn intercept(cpu: *uxn.Cpu, addr: u8, kind: uxn.Cpu.InterceptKind) !void {
    const port: u4 = @truncate(addr & 0xf);
    const lock_audio = kind == .output and addr >= 0x30 and addr < 0x70;

    if (lock_audio) SDL.SDL_LockAudioDevice(audio_id);
    defer if (lock_audio) SDL.SDL_UnlockAudioDevice(audio_id);

    switch (addr >> 4) {
        0x0 => try system.system_device.intercept(cpu, port, kind),
        0x1 => try system.console_device.intercept(cpu, port, kind),
        0x2 => try system.screen_device.intercept(cpu, port, kind),
        0x3 => try system.audio_devices[0].intercept(cpu, port, kind),
        0x4 => try system.audio_devices[1].intercept(cpu, port, kind),
        0x5 => try system.audio_devices[2].intercept(cpu, port, kind),
        0x6 => try system.audio_devices[3].intercept(cpu, port, kind),
        0x8 => try system.controller_device.intercept(cpu, port, kind),
        0x9 => try system.mouse_device.intercept(cpu, port, kind),
        0xa => try system.file_devices[0].intercept(cpu, port, kind),
        0xb => try system.file_devices[1].intercept(cpu, port, kind),
        0xc => try system.datetime_device.intercept(cpu, port, kind),

        else => {},
    }
}

fn sdl_panic() noreturn {
    const str = @as(?[*:0]const u8, SDL.SDL_GetError()) orelse "unknown error";

    @panic(std.mem.sliceTo(str, 0));
}

fn audio_callback(u: ?*anyopaque, stream: [*c]u8, len: c_int) callconv(.C) void {
    var samples_ptr = @as([*c]i16, @alignCast(@ptrCast(stream)));
    var samples = samples_ptr[0 .. @as(usize, @intCast(len)) / 2];

    // TODO: 0x00 should ideally be SDL_AudioSpec.silence here
    @memset(stream[0..@as(usize, @intCast(len))], 0x00);

    //var still_playing: usize = 0;
    var event: SDL.SDL_Event = undefined;

    for (0.., &system.audio_devices) |i, *poly| {
        if (poly.render_audio(samples)) |r| {
            if (r) {
                //still_playing += 1;
            } else {
                event.type = AUDIO_FINISHED + @as(u32, @truncate(i));

                _ = SDL.SDL_PushEvent(&event);
            }
        }
    }

    _ = u;

    //if (still_playing == 0) {
    //    const audio_id: *SDL.SDL_AudioDeviceID = @alignCast(@ptrCast(u.?));
    //
    //    SDL.SDL_PauseAudioDevice(audio_id.*, 1);
    //}
}

fn receive_stdin(p: ?*anyopaque) callconv(.C) c_int {
    _ = p;

    const stdin = std.io.getStdIn().reader();

    var event: SDL.SDL_Event = .{ .type = STDIN_RECEIVED };

    while (system.system_device.exit_code == null) {
        const b = stdin.readByte() catch
            break;

        event.cbutton.button = b;

        _ = SDL.SDL_PushEvent(&event);
    }

    return 0;
}

const InputType = union(enum) {
    buttons: varvara.Controller.ButtonFlags,
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
    screen_device: *const varvara.Screen,
    texture: *SDL.SDL_Texture,
    renderer: *SDL.SDL_Renderer,
) void {
    var frame_memory: ?*SDL.SDL_Surface = undefined;

    if (SDL.SDL_LockTextureToSurface(texture, null, &frame_memory) != 0)
        return;

    var pixels: [*c]u8 = @ptrCast(frame_memory.?.pixels);

    for (0..screen_device.height) |y| {
        for (0..screen_device.width) |x| {
            const idx = y * screen_device.width + x;
            const pal = (@as(u4, screen_device.foreground[idx]) << 2) | screen_device.background[idx];

            const color = &system.system_device.colors[if ((pal >> 2) > 0) (pal >> 2) else (pal & 0x3)];

            pixels[idx * 4 + 3] = 0x00;
            pixels[idx * 4 + 2] = color.r;
            pixels[idx * 4 + 1] = color.g;
            pixels[idx * 4 + 0] = color.b;
        }
    }

    SDL.SDL_UnlockTexture(texture);

    _ = SDL.SDL_RenderCopy(renderer, texture, null, null);
    SDL.SDL_RenderPresent(renderer);
}

fn main_graphical(cpu: *uxn.Cpu, scale: u8, args: [][]const u8) !u8 {
    if (SDL.SDL_Init(SDL.SDL_INIT_JOYSTICK | SDL.SDL_INIT_VIDEO | SDL.SDL_INIT_EVENTS | SDL.SDL_INIT_AUDIO) < 0)
        sdl_panic();

    defer SDL.SDL_Quit();

    _ = SDL.SDL_ShowCursor(SDL.SDL_DISABLE);

    var audio_spec: SDL.SDL_AudioSpec = .{
        .freq = varvara.Audio.sample_rate,
        .format = SDL.AUDIO_S16SYS,
        .channels = 2,
        .callback = &audio_callback,
        .samples = 512,
        .userdata = &audio_id,

        .silence = 0,
        .size = 0,
        .padding = undefined,
    };

    audio_id = SDL.SDL_OpenAudioDevice(null, 0, &audio_spec, null, 0);

    SDL.SDL_PauseAudioDevice(audio_id, 0);

    AUDIO_FINISHED = SDL.SDL_RegisterEvents(4);
    STDIN_RECEIVED = SDL.SDL_RegisterEvents(1);

    var stdin = SDL.SDL_CreateThread(receive_stdin, "stdin", null);

    SDL.SDL_DetachThread(stdin);

    cpu.output_intercepts = varvara.full_intercepts.output;
    cpu.input_intercepts = varvara.full_intercepts.input;

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

                else => {
                    if (ev.type >= AUDIO_FINISHED and ev.type < AUDIO_FINISHED + 4) {
                        const dev = ev.type - AUDIO_FINISHED;

                        system.audio_devices[dev].evaluate_finish_vector(cpu) catch |fault|
                            try system.system_device.handle_fault(cpu, fault);
                    } else if (ev.type == STDIN_RECEIVED) {
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

        draw_screen(&system.screen_device, texture, renderer);
    }

    return system.system_device.exit_code orelse 0;
}

pub fn main() !u8 {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help          Display this help and exit.
        \\-s, --scale <INT>   Display scale factor
        \\<FILE>              Input ROM
        \\<ARG>...            Command line arguments for the module
    );

    var diag = clap.Diagnostic{};
    var stderr = std.io.getStdErr().writer();

    const parsers = comptime .{
        .FILE = clap.parsers.string,
        .ARG = clap.parsers.string,
        .INT = clap.parsers.int(u8, 10),
    };

    var res = clap.parse(clap.Help, &params, parsers, .{
        .diagnostic = &diag,
    }) catch |err| {
        // Report useful error and exit
        diag.report(stderr, err) catch {};

        return err;
    };

    defer res.deinit();

    if (res.args.help != 0) {
        try clap.help(stderr, clap.Help, &params, .{});

        return 0;
    }

    var alloc = gpa.allocator();

    system = try varvara.VarvaraSystem.init(gpa.allocator());
    defer system.deinit();

    const input_file_name = res.positionals[0];

    const rom_file = try std.fs.cwd().openFile(input_file_name, .{});
    defer rom_file.close();

    var rom = try uxn.load_rom(alloc, rom_file);
    var cpu = uxn.Cpu.init(rom);

    cpu.device_intercept = &intercept;

    return main_graphical(&cpu, res.args.scale orelse 1, @constCast(res.positionals[1..]));
}
