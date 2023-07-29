const Cpu = @import("uxn-core").Cpu;
const std = @import("std");

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

pub const AutoFlags = packed struct(u8) {
    x: bool,
    y: bool,
    addr: bool,
    _: u1 = 0x0,
    add_length: u4,
};

pub const PixelFlags = packed struct(u8) {
    color: u2,
    _: u2,
    flip_x: bool,
    flip_y: bool,
    layer: u1,
    fill: bool,
};

pub const SpriteFlags = packed struct(u8) {
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
    pub const vector = 0x0;
    pub const width = 0x2;
    pub const height = 0x4;
    pub const auto = 0x6;
    pub const x = 0x8;
    pub const y = 0xa;
    pub const addr = 0xc;
    pub const pixel = 0xe;
    pub const sprite = 0xf;
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
                        x +% dy * @as(u16, @truncate(i)),
                        y +% dx * @as(u16, @truncate(i)),
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
            dev.cleanup_graphics();
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

pub fn initialize_graphics(dev: *@This()) !void {
    dev.foreground = try dev.alloc.alloc(u2, @as(usize, dev.width) * dev.height);
    errdefer dev.alloc.free(dev.foreground);

    dev.background = try dev.alloc.alloc(u2, @as(usize, dev.width) * dev.height);
    errdefer dev.alloc.free(dev.background);

    @memset(dev.foreground, 0x00);
    @memset(dev.background, 0x00);
}

pub fn cleanup_graphics(dev: *@This()) void {
    dev.alloc.free(dev.foreground);
    dev.alloc.free(dev.background);
}

pub fn evaluate_frame(dev: *@This(), cpu: *Cpu) !void {
    const vector = cpu.load_device_mem(u16, @as(u8, dev.addr) << 4 | ports.vector);

    if (vector != 0x0000)
        return cpu.evaluate_vector(vector);
}
