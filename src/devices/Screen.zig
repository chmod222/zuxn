const Cpu = @import("../Cpu.zig");
const std = @import("std");

const SDL = @import("root").SDL;

const default_window_width = 512;
const default_window_height = 320;

// Public
addr: u4,

width: u16 = default_window_width,
height: u16 = default_window_height,

foreground: []u2 = undefined,
background: []u2 = undefined,

// "Private"
alloc: std.mem.Allocator,

scale: u16 = 1,

window: ?*SDL.SDL_Window = null,
renderer: ?*SDL.SDL_Renderer = null,
texture: ?*SDL.SDL_Texture = null,

palette: [16]SDL.SDL_Color = undefined,

const AutoFlags = packed struct(u8) {
    x: bool,
    y: bool,
    addr: bool,
    _: u1 = 0x0,
    add_length: u4,
};

const PixelFlags = packed struct(u8) {
    color: u2,
    _: u2,
    flip_x: bool,
    flip_y: bool,
    layer: u1,
    fill: bool,
};

const SpriteFlags = packed struct(u8) {
    blending: u4,
    flip_x: bool,
    flip_y: bool,
    layer: u1,
    two_bpp: bool,
};

const blending: [4][16]u2 = .{
    .{ 0, 0, 0, 0, 1, 0, 1, 1, 2, 2, 0, 2, 3, 3, 3, 0 },
    .{ 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3 },
    .{ 1, 2, 3, 1, 1, 2, 3, 1, 1, 2, 3, 1, 1, 2, 3, 1 },
    .{ 2, 3, 1, 2, 2, 3, 1, 2, 2, 3, 1, 2, 2, 3, 1, 2 },
};

pub const ports = struct {
    const vector = 0x0;
    const width = 0x2;
    const height = 0x4;
    const auto = 0x6;
    const x = 0x8;
    const y = 0xa;
    const addr = 0xc;
    const pixel = 0xe;
    const sprite = 0xf;
};

pub fn intercept(
    dev: *@This(),
    cpu: *Cpu,
    port: u4,
    kind: Cpu.InterceptKind,
) !void {
    const base = @as(u8, dev.addr) << 4;

    if (kind == .input) {
        switch (port) {
            ports.width, ports.width + 1 => {
                cpu.store_device_mem(u16, base | ports.width, dev.width);
            },

            ports.height, ports.height + 1 => {
                cpu.store_device_mem(u16, base | ports.height, dev.height);
            },

            else => {},
        }
    } else {
        switch (port) {
            ports.width + 1 => dev.width = cpu.load_device_mem(u16, base | ports.width),
            ports.height + 1 => dev.height = cpu.load_device_mem(u16, base | ports.height),

            ports.pixel => {
                const flags: PixelFlags = @bitCast(cpu.load_device_mem(u8, base | ports.pixel));
                const auto: AutoFlags = @bitCast(cpu.load_device_mem(u8, base | ports.auto));

                var x0 = cpu.load_device_mem(u16, base | ports.x);
                var y0 = cpu.load_device_mem(u16, base | ports.y);

                var x1: u16 = undefined;
                var y1: u16 = undefined;

                const layer = if (flags.layer == 0x00) dev.background else dev.foreground;

                if (flags.fill) {
                    x1 = if (flags.flip_x) 0 else dev.width;
                    y1 = if (flags.flip_y) 0 else dev.height;

                    if (x0 > x1) std.mem.swap(u16, &x0, &x1);
                    if (y0 > y1) std.mem.swap(u16, &y0, &y1);

                    dev.fill_region(layer, x0, y0, x1, y1, flags);
                } else {
                    x1 = x0 +% 1;
                    y1 = y0 +% 1;

                    if (x0 < dev.width and y0 < dev.height)
                        layer[@as(usize, y0) * dev.width + x0] = flags.color;

                    if (auto.x) cpu.store_device_mem(u16, base | ports.x, x1);
                    if (auto.y) cpu.store_device_mem(u16, base | ports.y, y1);
                }

                // TODO: trigger update from (x0, y0) to (x1, y1)
            },

            ports.sprite => {
                const flags: SpriteFlags = @bitCast(cpu.load_device_mem(u8, base | ports.sprite));
                const auto: AutoFlags = @bitCast(cpu.load_device_mem(u8, base | ports.auto));

                const x = cpu.load_device_mem(u16, base | ports.x);
                const y = cpu.load_device_mem(u16, base | ports.y);

                const dx: u16 = if (auto.x) 8 else 0;
                const dy: u16 = if (auto.y) 8 else 0;
                const da: u16 = if (auto.addr) if (flags.two_bpp) 16 else 8 else 0;

                const layer = if (flags.layer == 0x00) dev.background else dev.foreground;

                var addr = cpu.load_device_mem(u16, base | ports.addr);

                for (0..@as(u8, auto.add_length) + 1) |i| {
                    // dy and dx flipped in original implementation
                    dev.render_sprite(
                        cpu,
                        layer,
                        flags,
                        x + dy * @as(u16, @truncate(i)),
                        y + dx * @as(u16, @truncate(i)),
                        addr,
                    );

                    addr +%= da;
                }

                // TODO: trigger update from (x, y) to (x+dy*l, y+dx*l)

                if (auto.x) cpu.store_device_mem(u16, base | ports.x, x +% dx);
                if (auto.y) cpu.store_device_mem(u16, base | ports.y, y +% dy);
                if (auto.addr) cpu.store_device_mem(u16, base | ports.addr, addr);
            },

            else => {
                return;
            },
        }

        if (port == ports.width + 1 or port == ports.height + 1) {
            dev.initialize_graphics() catch unreachable;
        }
    }
}

fn render_sprite(
    dev: *@This(),
    cpu: *Cpu,
    layer: []u2,
    flags: SpriteFlags,
    x0: u16,
    y0: u16,
    addr: u16,
) void {
    const opaq = flags.blending % 5 != 0 or flags.blending == 0x0;

    var y: u16 = 0;

    while (y < 8) : (y += 1) {
        var c: u16 = cpu.mem[addr +% y] | if (flags.two_bpp)
            @as(u16, cpu.mem[addr +% (y + 8)]) << 8
        else
            0;

        var x: u16 = 0;

        while (x < 8) : (x += 1) {
            defer c >>= 1;

            const ch = (c & 1) | ((c >> 7) & 2);

            const yr = y0 +% (if (flags.flip_y) 7 - y else y);
            const xr = x0 +% (if (flags.flip_x) x else 7 - x);

            if (opaq or ch != 0x0000) {
                if (xr < dev.width and yr < dev.height)
                    layer[@as(usize, yr) * dev.width + xr] = blending[ch][flags.blending];
            }
        }
    }
}

fn fill_region(
    dev: *@This(),
    layer: []u2,
    x0: u16,
    y0: u16,
    x1: u16,
    y1: u16,
    flags: PixelFlags,
) void {
    var y = y0;

    while (y < y1) : (y += 1) {
        var x = x0;

        while (x < x1) : (x += 1) {
            layer[@as(usize, y) * dev.width + x] = flags.color;
        }
    }
}

fn split_rgb(r: u16, g: u16, b: u16, c: u2) SDL.SDL_Color {
    const sw = @as(u4, 3 - c) * 4;

    return SDL.SDL_Color{
        .r = @truncate((r >> sw) & 0xf | ((r >> sw) & 0xf) << 4),
        .g = @truncate((g >> sw) & 0xf | ((g >> sw) & 0xf) << 4),
        .b = @truncate((b >> sw) & 0xf | ((b >> sw) & 0xf) << 4),
        .a = 0xff,
    };
}

pub fn update_scheme(
    dev: *@This(),
    r: u16,
    g: u16,
    b: u16,
) void {
    const palette: [4]SDL.SDL_Color = .{
        split_rgb(r, g, b, 0),
        split_rgb(r, g, b, 1),
        split_rgb(r, g, b, 2),
        split_rgb(r, g, b, 3),
    };

    for (0..16) |i|
        dev.palette[i] = palette[if ((i >> 2) > 0) (i >> 2) else (i & 0x3)];
}

pub fn initialize_graphics(dev: *@This()) !void {
    if (dev.window) |win| {
        SDL.SDL_SetWindowSize(
            win,
            dev.width * dev.scale,
            dev.height * dev.scale,
        );

        dev.alloc.free(dev.foreground);
        dev.alloc.free(dev.background);
    } else {
        dev.window = SDL.SDL_CreateWindow(
            "zuxn",
            SDL.SDL_WINDOWPOS_CENTERED,
            SDL.SDL_WINDOWPOS_CENTERED,
            dev.width * dev.scale,
            dev.height * dev.scale,
            SDL.SDL_WINDOW_SHOWN,
        ) orelse return error.CouldNotCreateWindow;
    }

    errdefer {
        SDL.SDL_DestroyWindow(dev.window);
    }

    dev.foreground = try dev.alloc.alloc(u2, @as(usize, dev.width) * dev.height);
    errdefer dev.alloc.free(dev.foreground);

    dev.background = try dev.alloc.alloc(u2, @as(usize, dev.width) * dev.height);
    errdefer dev.alloc.free(dev.background);

    @memset(dev.foreground, 0x00);
    @memset(dev.background, 0x00);

    if (dev.renderer == null) {
        dev.renderer = SDL.SDL_CreateRenderer(
            dev.window,
            -1,
            SDL.SDL_RENDERER_ACCELERATED | SDL.SDL_RENDERER_PRESENTVSYNC,
        ) orelse return error.CouldNotCreateRenderer;
    }

    _ = SDL.SDL_RenderSetLogicalSize(dev.renderer, dev.width, dev.height);

    errdefer {
        SDL.SDL_DestroyRenderer(dev.renderer);
    }

    if (dev.texture) |old_texture| {
        SDL.SDL_DestroyTexture(old_texture);
    }

    dev.texture = SDL.SDL_CreateTexture(
        dev.renderer,
        SDL.SDL_PIXELFORMAT_RGB888,
        SDL.SDL_TEXTUREACCESS_STREAMING,
        dev.width,
        dev.height,
    ) orelse return error.CouldNotCreateTexture;

    _ = SDL.SDL_RenderSetLogicalSize(dev.renderer, dev.width, dev.height);
}

pub fn cleanup_graphics(dev: *@This()) void {
    SDL.SDL_DestroyWindow(dev.window);
    SDL.SDL_DestroyRenderer(dev.renderer);
    SDL.SDL_DestroyTexture(dev.texture);

    dev.alloc.free(dev.foreground);
    dev.alloc.free(dev.background);
}

pub fn evaluate_frame(dev: *@This(), cpu: *Cpu) !void {
    const vector = cpu.load_device_mem(u16, @as(u8, dev.addr) << 4 | ports.vector);

    if (vector != 0x0000)
        return cpu.evaluate_vector(vector);
}

pub fn update(dev: *@This()) void {
    var frame_memory: ?*SDL.SDL_Surface = undefined;

    if (SDL.SDL_LockTextureToSurface(dev.texture, null, &frame_memory) != 0)
        return;

    var pixels: [*c]u8 = @ptrCast(frame_memory.?.pixels);

    for (0..dev.height) |y| {
        for (0..dev.width) |x| {
            const idx = y * dev.width + x;
            const color = &dev.palette[(@as(u4, dev.foreground[idx]) << 2) | dev.background[idx]];

            pixels[idx * 4 + 3] = 0x00;
            pixels[idx * 4 + 2] = color.r;
            pixels[idx * 4 + 1] = color.g;
            pixels[idx * 4 + 0] = color.b;
        }
    }

    SDL.SDL_UnlockTexture(dev.texture);

    _ = SDL.SDL_RenderCopy(dev.renderer, dev.texture, null, null);
    SDL.SDL_RenderPresent(dev.renderer);
}
