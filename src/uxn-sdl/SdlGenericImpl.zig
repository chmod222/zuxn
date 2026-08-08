const std = @import("std");
const uxn = @import("uxn-core");
const varvara = @import("uxn-varvara");

const logger = std.log.scoped(.uxn_sdl);

const posix = std.posix;
const Io = std.Io;

const InputType = union(enum) {
    buttons: varvara.controller.ButtonFlags,
    key: u8,
};

cpu: *uxn.Cpu,
sys: *varvara.VarvaraDefault,

stdin_event_id: u32 = undefined,

const c = @import("sdl-sys");
pub const sdl2 = @import("root").sdl2;

pub fn init(cpu: *uxn.Cpu, sys: *varvara.VarvaraDefault) @This() {
    cpu.device_intercept = &intercept;
    cpu.callback_data = sys;

    cpu.output_intercepts = varvara.full_intercepts.output;
    cpu.input_intercepts = varvara.full_intercepts.input;

    return .{
        .cpu = cpu,
        .sys = sys,
    };
}

pub fn renderSprite(
    sys: *varvara.VarvaraDefault,
    w: usize,
    h: usize,
    data: []const u2,
) *c.SDL_Surface {
    const surface = if (sdl2)
        c.SDL_CreateRGBSurface(
            0,
            24,
            24,
            32,
            0,
            0,
            0,
            0,
        ) orelse unreachable
    else
        c.SDL_CreateSurface(
            24,
            24,
            c.SDL_PIXELFORMAT_XRGB8888,
        ) orelse unreachable;

    const pixels: [*c]u8 = @ptrCast(surface.*.pixels);

    for (0..w) |y| {
        for (0..h) |x| {
            const idx = y * w + x;
            const color = &sys.system_device.colors[data[idx]];

            pixels[idx * 4 + 3] = 0x00;
            pixels[idx * 4 + 2] = color.r;
            pixels[idx * 4 + 1] = color.g;
            pixels[idx * 4 + 0] = color.b;
        }
    }

    return surface;
}

pub fn freeSurface(surf: *c.SDL_Surface) void {
    if (sdl2)
        c.SDL_FreeSurface(surf)
    else
        c.SDL_DestroySurface(surf);
}

pub fn renderAudio(impl: *@This(), samples: []i16) void {
    // TODO: 0x00 should ideally be SDL_AudioSpec.silence here
    @memset(samples, 0x0000);

    for (&impl.sys.audio_devices) |*poly| {
        poly.renderAudio(@ptrCast(samples));

        if (poly.active_sample) |s| {
            if (s.envelope.isFinished()) {
                poly.evaluateFinishVector(impl.cpu) catch |fault|
                    impl.sys.system_device.handleFault(impl.cpu, fault) catch {};
            }
        }
    }

    for (0..samples.len) |i| {
        samples[i] <<= 6;
    }
}

pub fn determineInput(event: *c.SDL_Event) ?InputType {
    const mods = c.SDL_GetModState();

    const sym = if (sdl2) event.key.keysym.sym else event.key.key;
    const a = if (sdl2) c.SDLK_a else c.SDLK_A;
    const z = if (sdl2) c.SDLK_z else c.SDLK_Z;
    const ctrl = if (sdl2) c.KMOD_CTRL else c.SDL_KMOD_CTRL;
    const shift = if (sdl2) c.KMOD_SHIFT else c.SDL_KMOD_SHIFT;

    if (sym < 0x20 or sym == c.SDLK_DELETE) {
        return .{ .key = @intCast(sym) };
    } else if (mods & ctrl > 0) {
        if (sym < a) {
            return .{ .key = @intCast(sym) };
        } else if (sym <= z) {
            return .{ .key = @truncate(@as(u32, @bitCast(sym)) - @as(u32, @bitCast(mods & shift)) * 0x20) };
        }
    }

    switch (sym) {
        c.SDLK_LCTRL => return .{ .buttons = .{ .ctrl = true } },
        c.SDLK_LALT => return .{ .buttons = .{ .alt = true } },
        c.SDLK_LSHIFT => return .{ .buttons = .{ .shift = true } },
        c.SDLK_HOME => return .{ .buttons = .{ .start = true } },
        c.SDLK_UP => return .{ .buttons = .{ .up = true } },
        c.SDLK_DOWN => return .{ .buttons = .{ .down = true } },
        c.SDLK_LEFT => return .{ .buttons = .{ .left = true } },
        c.SDLK_RIGHT => return .{ .buttons = .{ .right = true } },

        else => {},
    }

    return null;
}

pub fn intercept(
    cpu: *uxn.Cpu,
    addr: u8,
    kind: uxn.Cpu.InterceptKind,
    data: ?*anyopaque,
) !void {
    const varvara_sys: ?*varvara.VarvaraDefault = @ptrCast(@alignCast(data));

    if (varvara_sys) |sys| {
        try sys.intercept(cpu, addr, kind);
    }
}

pub fn drawScreen(
    impl: *@This(),
    texture: *c.SDL_Texture,
    renderer: *c.SDL_Renderer,
) void {
    const screen_device = &impl.sys.screen_device;
    const system_device = &impl.sys.system_device;

    if (screen_device.dirty_region) |region| {
        var pixels: [*c]u8 = undefined;
        var pitch: c_int = undefined;

        if (sdl2) {
            if (c.SDL_LockTexture(texture, null, @ptrCast(&pixels), &pitch) != 0)
                return;
        } else {
            if (!c.SDL_LockTexture(texture, null, @ptrCast(&pixels), &pitch))
                return;
        }

        defer c.SDL_UnlockTexture(texture);

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

    if (sdl2) {
        _ = c.SDL_RenderCopy(renderer, texture, null, null);
    } else {
        _ = c.SDL_RenderTexture(renderer, texture, null, null);
    }

    _ = c.SDL_RenderPresent(renderer);
}
