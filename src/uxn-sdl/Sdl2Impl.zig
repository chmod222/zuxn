const std = @import("std");
const uxn = @import("uxn-core");
const varvara = @import("uxn-varvara");

pub const c = @import("sdl-sys");

const logger = std.log.scoped(.uxn_sdl);

pub const Generic = @import("SdlGenericImpl.zig");

const Sdl2Impl = @This();

generic: Generic,

window: *c.SDL_Window = undefined,
renderer: *c.SDL_Renderer = undefined,
texture: *c.SDL_Texture = undefined,

audio: c.SDL_AudioDeviceID = undefined,

pub fn init(cpu: *uxn.Cpu, sys: *varvara.VarvaraDefault) Sdl2Impl {
    return .{ .generic = .init(cpu, sys) };
}

pub fn initSdl(_: *Sdl2Impl) !void {
    logger.debug("Initializing SDL2 backend ({}.{}.{})", .{
        c.SDL_MAJOR_VERSION,
        c.SDL_MINOR_VERSION,
        c.SDL_PATCHLEVEL,
    });

    if (c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_EVENTS) < 0)
        return error.SdlInitFailed;

    if (c.SDL_ShowCursor(c.SDL_DISABLE) < 0) {
        logger.debug("Could not hide cursor\n", .{});
    }
}

pub fn initScreen(impl: *Sdl2Impl, scale: u8) !void {
    const width = impl.generic.sys.screen_device.width;
    const height = impl.generic.sys.screen_device.height;

    impl.window = c.SDL_CreateWindow(
        "zuxn",
        c.SDL_WINDOWPOS_CENTERED,
        c.SDL_WINDOWPOS_CENTERED,
        width * scale,
        height * scale,
        c.SDL_WINDOW_SHOWN,
    ) orelse return error.CouldNotCreateWindow;

    errdefer c.SDL_DestroyWindow(impl.window);

    impl.renderer = c.SDL_CreateRenderer(
        impl.window,
        -1,
        c.SDL_RENDERER_ACCELERATED | c.SDL_RENDERER_PRESENTVSYNC,
    ) orelse return error.CouldNotCreateRenderer;

    errdefer c.SDL_DestroyRenderer(impl.renderer);

    if (c.SDL_RenderSetLogicalSize(impl.renderer, width, height) < 0) {
        return error.CouldNotResize;
    }

    impl.texture = c.SDL_CreateTexture(
        impl.renderer,
        c.SDL_PIXELFORMAT_RGB888,
        c.SDL_TEXTUREACCESS_STREAMING,
        width,
        height,
    ) orelse return error.CouldNotCreateTexture;

    _ = c.SDL_StartTextInput();
}

pub fn resizeScreen(impl: *Sdl2Impl, scale: u8) !void {
    const height = impl.generic.sys.screen_device.height;
    const width = impl.generic.sys.screen_device.width;

    c.SDL_SetWindowSize(impl.window, width * scale, height * scale);

    if (c.SDL_RenderSetLogicalSize(impl.renderer, width, height) < 0) {
        return error.CouldNotResize;
    }

    c.SDL_DestroyTexture(impl.texture);

    impl.texture = c.SDL_CreateTexture(
        impl.renderer,
        c.SDL_PIXELFORMAT_RGB888,
        c.SDL_TEXTUREACCESS_STREAMING,
        width,
        height,
    ) orelse return error.CouldNotCreateTexture;
}

pub fn audioCallback(u: ?*anyopaque, stream: [*c]u8, len: c_int) callconv(.c) void {
    const impl: *Sdl2Impl = @ptrCast(@alignCast(u));

    var samples_ptr = @as([*c]i16, @ptrCast(@alignCast(stream)));

    impl.generic.renderAudio(samples_ptr[0 .. @as(usize, @intCast(len)) / 2]);
}

// This inline is important because if audio_spec is not inlined into the main, the callback pointer will be overwritten
// and the application crash :)
pub inline fn initAudio(impl: *Sdl2Impl) void {
    if (c.SDL_InitSubSystem(c.SDL_INIT_AUDIO) == 0) {
        var audio_spec = c.SDL_AudioSpec{
            .freq = varvara.audio.sample_rate,
            .format = c.AUDIO_S16SYS,
            .channels = 2,
            .callback = &Sdl2Impl.audioCallback,
            .samples = varvara.audio.sample_count,
            .userdata = impl,

            .silence = 0,
            .size = 0,
            .padding = undefined,
        };

        impl.audio = c.SDL_OpenAudioDevice(null, 0, &audio_spec, null, 0);

        c.SDL_PauseAudioDevice(impl.audio, 0);
    }
}

pub inline fn initJoystick(_: *Sdl2Impl) void {
    if (c.SDL_InitSubSystem(c.SDL_INIT_JOYSTICK) == 0) {
        _ = c.SDL_JoystickOpen(0) orelse {
            logger.debug("Couldn't open joystick {}: {s}", .{ 0, c.SDL_GetError() });
        };
    }
}

pub fn drawScreen(impl: *Sdl2Impl) void {
    impl.generic.drawScreen(
        impl.texture,
        impl.renderer,
    );
}

pub fn pollEvents(impl: *Sdl2Impl) !bool {
    var ev: c.SDL_Event = undefined;

    const system = impl.generic.sys;
    const cpu = impl.generic.cpu;

    while (c.SDL_PollEvent(&ev) != 0) {
        switch (ev.type) {
            c.SDL_QUIT => {
                return true;
            },

            c.SDL_MOUSEMOTION => {
                system.mouse_device.updatePosition(
                    cpu,
                    @truncate(@as(c_uint, @bitCast(ev.motion.x))),
                    @truncate(@as(c_uint, @bitCast(ev.motion.y))),
                ) catch |fault|
                    try system.system_device.handleFault(cpu, fault);
            },

            c.SDL_MOUSEBUTTONDOWN => {
                system.mouse_device.pressButtons(
                    cpu,
                    @bitCast(@as(u8, 1) << @as(u3, @truncate(ev.button.button - 1))),
                ) catch |fault|
                    try system.system_device.handleFault(cpu, fault);
            },

            c.SDL_MOUSEBUTTONUP => {
                system.mouse_device.releaseButtons(
                    cpu,
                    @bitCast(@as(u8, 1) << @as(u3, @truncate(ev.button.button - 1))),
                ) catch |fault|
                    try system.system_device.handleFault(cpu, fault);
            },

            c.SDL_MOUSEWHEEL => {
                system.mouse_device.updateScroll(cpu, ev.wheel.x, ev.wheel.y) catch |fault|
                    try system.system_device.handleFault(cpu, fault);
            },

            c.SDL_TEXTINPUT => {
                system.controller_device.pressKey(cpu, ev.text.text[0]) catch |fault|
                    try system.system_device.handleFault(cpu, fault);
            },

            c.SDL_KEYDOWN => {
                if (Generic.determineInput(&ev)) |input| switch (input) {
                    .buttons => |b| {
                        system.controller_device.pressButtons(cpu, b, 0) catch |fault|
                            try system.system_device.handleFault(cpu, fault);
                    },

                    .key => |k| {
                        system.controller_device.pressKey(cpu, k) catch |fault|
                            try system.system_device.handleFault(cpu, fault);
                    },
                };
            },

            c.SDL_KEYUP => {
                if (Generic.determineInput(&ev)) |input| switch (input) {
                    .buttons => |b| {
                        system.controller_device.releaseButtons(cpu, b, 0) catch |fault|
                            try system.system_device.handleFault(cpu, fault);
                    },

                    else => {},
                };
            },

            c.SDL_JOYAXISMOTION => {
                const player: u2 = @truncate(@as(c_uint, @bitCast(ev.jbutton.which)));

                _ = player;

                // TODO
            },

            c.SDL_JOYBUTTONDOWN, c.SDL_JOYBUTTONUP => b: {
                const player: u2 = @truncate(@as(c_uint, @bitCast(ev.jbutton.which)));
                const btn: varvara.controller.ButtonFlags = switch (ev.jbutton.button) {
                    0x0 => .{ .ctrl = true },
                    0x1 => .{ .alt = true },
                    0x06 => .{ .shift = true },
                    0x07 => .{ .start = true },
                    else => break :b,
                };

                if (ev.type == c.SDL_JOYBUTTONUP)
                    system.controller_device.releaseButtons(cpu, btn, player) catch |fault|
                        try system.system_device.handleFault(cpu, fault)
                else
                    system.controller_device.pressButtons(cpu, btn, player) catch |fault|
                        try system.system_device.handleFault(cpu, fault);
            },

            c.SDL_JOYHATMOTION => {
                const player: u2 = @truncate(@as(c_uint, @bitCast(ev.jhat.which)));
                const btn: varvara.controller.ButtonFlags = switch (ev.jhat.value) {
                    c.SDL_HAT_UP => .{ .up = true },
                    c.SDL_HAT_DOWN => .{ .down = true },
                    c.SDL_HAT_LEFT => .{ .left = true },
                    c.SDL_HAT_RIGHT => .{ .right = true },
                    c.SDL_HAT_LEFTDOWN => .{ .left = true, .down = true },
                    c.SDL_HAT_LEFTUP => .{ .left = true, .up = true },
                    c.SDL_HAT_RIGHTDOWN => .{ .right = true, .down = true },
                    c.SDL_HAT_RIGHTUP => .{ .right = true, .up = true },
                    else => .{},
                };

                // Release all the non-pressed buttons
                const inverse = varvara.controller.ButtonFlags{
                    .up = !btn.up,
                    .down = !btn.down,
                    .left = !btn.left,
                    .right = !btn.right,
                };

                system.controller_device.releaseButtons(cpu, inverse, player) catch |fault|
                    try system.system_device.handleFault(cpu, fault);

                if (@as(u8, @bitCast(btn)) != 0) {
                    system.controller_device.pressButtons(cpu, btn, player) catch |fault|
                        try system.system_device.handleFault(cpu, fault);
                }
            },

            else => {
                if (ev.type == impl.generic.stdin_event_id) {
                    system.console_device.pushStdinByte(cpu, ev.cbutton.button) catch |fault|
                        try system.system_device.handleFault(cpu, fault);
                }
            },
        }
    }

    return false;
}
