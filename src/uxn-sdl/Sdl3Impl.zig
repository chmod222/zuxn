const std = @import("std");
const uxn = @import("uxn-core");
const varvara = @import("uxn-varvara");

pub const c = @import("sdl-sys");

const logger = std.log.scoped(.uxn_sdl);

pub const Generic = @import("SdlGenericImpl.zig");

const Sdl2Impl = @import("Sdl2Impl.zig");
const Sdl3Impl = @This();

generic: Generic,

window: *c.SDL_Window = undefined,
renderer: *c.SDL_Renderer = undefined,
texture: *c.SDL_Texture = undefined,

audio: ?*c.SDL_AudioStream = undefined,

pub fn init(cpu: *uxn.Cpu, sys: *varvara.Varvara) Sdl3Impl {
    return .{ .generic = .init(cpu, sys) };
}
pub fn initSdl(_: *Sdl3Impl) !void {
    logger.debug("Initializing SDL3 backend ({}.{}.{})", .{
        c.SDL_MAJOR_VERSION,
        c.SDL_MINOR_VERSION,
        c.SDL_MICRO_VERSION,
    });

    if (!c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_EVENTS))
        return error.SdlInitFailed;

    if (!c.SDL_HideCursor()) {
        logger.debug("Could not hide cursor\n", .{});
    }
}

pub fn initScreen(impl: *Sdl3Impl, scale: u8) !void {
    const width = impl.generic.sys.screen_device.width;
    const height = impl.generic.sys.screen_device.height;

    impl.window = c.SDL_CreateWindow(
        "zuxn",
        width * scale,
        height * scale,
        0,
    ) orelse return error.CouldNotCreateWindow;

    errdefer c.SDL_DestroyWindow(impl.window);

    impl.renderer = c.SDL_CreateRenderer(
        impl.window,
        null,
    ) orelse return error.CouldNotCreateRenderer;

    errdefer c.SDL_DestroyRenderer(impl.renderer);

    if (!c.SDL_SetRenderLogicalPresentation(
        impl.renderer,
        width,
        height,
        c.SDL_LOGICAL_PRESENTATION_INTEGER_SCALE,
    )) {
        return error.CouldNotResize;
    }

    impl.texture = c.SDL_CreateTexture(
        impl.renderer,
        c.SDL_PIXELFORMAT_XRGB8888,
        c.SDL_TEXTUREACCESS_STREAMING,
        width,
        height,
    ) orelse return error.CouldNotCreateTexture;

    _ = c.SDL_SetTextureScaleMode(impl.texture, c.SDL_SCALEMODE_NEAREST);
    _ = c.SDL_StartTextInput(impl.window);
}

pub fn resizeScreen(impl: *Sdl3Impl, scale: u8) !void {
    const height = impl.generic.sys.screen_device.height;
    const width = impl.generic.sys.screen_device.width;

    if (!c.SDL_SetWindowSize(impl.window, width * scale, height * scale)) {
        return error.CouldNotResize;
    }

    if (!c.SDL_SetRenderLogicalPresentation(
        impl.renderer,
        width,
        height,
        c.SDL_LOGICAL_PRESENTATION_INTEGER_SCALE,
    )) {
        return error.CouldNotResize;
    }

    c.SDL_DestroyTexture(impl.texture);

    impl.texture = c.SDL_CreateTexture(
        impl.renderer,
        c.SDL_PIXELFORMAT_XRGB8888,
        c.SDL_TEXTUREACCESS_STREAMING,
        width,
        height,
    ) orelse return error.CouldNotCreateTexture;

    // Treat this as nonfatal.
    _ = c.SDL_SetTextureScaleMode(impl.texture, c.SDL_SCALEMODE_NEAREST);
}

fn audioCallback(u: ?*anyopaque, stream: ?*c.SDL_AudioStream, additional: c_int, total: c_int) callconv(.c) void {
    const impl: *Sdl3Impl = @ptrCast(@alignCast(u));

    _ = total; // autofix

    if (additional > 0) {
        // TODO: don’t realloc this all the time.
        const samples = impl.generic.sys.allocator.alloc(i16, @intCast(additional >> 1)) catch return;
        defer impl.generic.sys.allocator.free(samples);

        impl.generic.renderAudio(samples);

        _ = c.SDL_PutAudioStreamData(stream, samples.ptr, additional);
    }
}

// This inline is important because if audio_spec is not inlined into the main, the callback pointer will be overwritten
// and the application crash :)
pub inline fn initAudio(impl: *Sdl3Impl) void {
    if (c.SDL_InitSubSystem(c.SDL_INIT_AUDIO)) {
        impl.audio = c.SDL_OpenAudioDeviceStream(
            c.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK,
            &c.SDL_AudioSpec{
                .freq = varvara.audio.sample_rate,
                .channels = 2,
                .format = c.SDL_AUDIO_S16,
            },
            &Sdl3Impl.audioCallback,
            impl,
        );

        _ = c.SDL_ResumeAudioDevice(c.SDL_GetAudioStreamDevice(impl.audio));
    }
}

pub fn initJoystick(_: *Sdl3Impl) void {
    if (c.SDL_InitSubSystem(c.SDL_INIT_JOYSTICK)) {
        var n: c_int = undefined;

        const joys = c.SDL_GetJoysticks(&n);
        defer c.SDL_free(joys);

        if (joys != null) {
            for (joys[0..@intCast(n)]) |joystick| {
                if (c.SDL_GetJoystickTypeForID(joystick) != c.SDL_JOYSTICK_TYPE_GAMEPAD) {
                    continue;
                }

                const name = if (c.SDL_GetJoystickNameForID(joystick)) |name|
                    std.mem.span(name)
                else
                    "<unknown>";

                logger.debug("Trying joystick {}: {s}\n", .{ joystick, name });

                if (c.SDL_OpenJoystick(joystick) == null) {
                    logger.debug("Couldn't open joystick: {s}", .{c.SDL_GetError()});

                    continue;
                }

                break;
            }
        }
    }
}

pub fn drawScreen(impl: *Sdl3Impl) void {
    impl.generic.drawScreen(impl.texture, impl.renderer);
}

pub fn pollEvents(impl: *Sdl3Impl) !bool {
    var ev: c.SDL_Event = undefined;

    const system = impl.generic.sys;
    const cpu = impl.generic.cpu;

    while (c.SDL_PollEvent(&ev)) {
        _ = c.SDL_ConvertEventToRenderCoordinates(impl.renderer, &ev);

        switch (ev.type) {
            c.SDL_EVENT_QUIT => {
                return true;
            },

            c.SDL_EVENT_MOUSE_MOTION => {
                try system.mouse_device.updatePosition(
                    cpu,
                    @truncate(@as(c_uint, @intFromFloat(@max(0, ev.motion.x)))),
                    @truncate(@as(c_uint, @intFromFloat(@max(0, ev.motion.y)))),
                );
            },

            c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                try system.mouse_device.pressButtons(
                    cpu,
                    @bitCast(@as(u8, 1) << @as(u3, @truncate(ev.button.button - 1))),
                );
            },

            c.SDL_EVENT_MOUSE_BUTTON_UP => {
                try system.mouse_device.releaseButtons(
                    cpu,
                    @bitCast(@as(u8, 1) << @as(u3, @truncate(ev.button.button - 1))),
                );
            },

            c.SDL_EVENT_MOUSE_WHEEL => {
                try system.mouse_device.updateScroll(cpu, @floor(ev.wheel.x), @floor(ev.wheel.y));
            },

            c.SDL_EVENT_TEXT_INPUT => {
                for (std.mem.span(ev.text.text)) |oct| {
                    try system.controller_device.pressKey(cpu, oct);
                }
            },

            c.SDL_EVENT_KEY_DOWN => {
                if (Generic.determineInput(&ev)) |input| switch (input) {
                    .buttons => |b| {
                        try system.controller_device.pressButtons(cpu, b, 0);
                    },

                    .key => |k| {
                        try system.controller_device.pressKey(cpu, k);
                    },
                };
            },

            c.SDL_EVENT_KEY_UP => {
                if (Generic.determineInput(&ev)) |input| switch (input) {
                    .buttons => |b| {
                        try system.controller_device.releaseButtons(cpu, b, 0);
                    },

                    else => {},
                };
            },

            c.SDL_EVENT_JOYSTICK_AXIS_MOTION => {
                const player: u2 = @truncate(@as(c_uint, @bitCast(ev.jbutton.which)));

                _ = player;

                // TODO
            },

            c.SDL_EVENT_JOYSTICK_BUTTON_DOWN, c.SDL_EVENT_JOYSTICK_BUTTON_UP => b: {
                const player: u2 = @truncate(@as(c_uint, @bitCast(ev.jbutton.which)));
                const btn: varvara.controller.ButtonFlags = switch (ev.jbutton.button) {
                    0x0 => .{ .ctrl = true },
                    0x1 => .{ .alt = true },
                    0x06 => .{ .shift = true },
                    0x07 => .{ .start = true },
                    else => break :b,
                };

                if (ev.type == c.SDL_EVENT_JOYSTICK_BUTTON_UP)
                    try system.controller_device.releaseButtons(cpu, btn, player)
                else
                    try system.controller_device.pressButtons(cpu, btn, player);
            },

            c.SDL_EVENT_JOYSTICK_HAT_MOTION => {
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

                try system.controller_device.releaseButtons(cpu, inverse, player);

                if (@as(u8, @bitCast(btn)) != 0) {
                    try system.controller_device.pressButtons(cpu, btn, player);
                }
            },

            else => {},
        }
    }

    return false;
}
