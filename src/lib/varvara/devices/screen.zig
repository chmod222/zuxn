const Cpu = @import("uxn-core").Cpu;

const std = @import("std");
const impl = @import("impl.zig");
const logger = std.log.scoped(.uxn_varvara_screen);

const Allocator = std.mem.Allocator;

const default_window_width = 512;
const default_window_height = 320;

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
    blending: u4 = 0,
    flip_x: bool = false,
    flip_y: bool = false,
    layer: u1 = 0,
    two_bpp: bool = false,
};

const blending: [4][16]u2 = .{
    .{ 0, 0, 0, 0, 1, 0, 1, 1, 2, 2, 0, 2, 3, 3, 3, 3 },
    .{ 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3 },
    .{ 1, 2, 3, 1, 1, 2, 3, 1, 1, 2, 3, 1, 1, 2, 3, 1 },
    .{ 2, 3, 1, 2, 2, 3, 1, 2, 2, 3, 1, 2, 2, 3, 1, 2 },
};

fn defaultBlend(color: u2, mode: u4) u2 {
    return blending[color][mode];
}

const bool1x2 = @Vector(2, bool);
const u16x2 = @Vector(2, u16);
const u16x4 = @Vector(4, u16);

inline fn indexOf(dims: u16x2, pos: u16x2) usize {
    return (@as(usize, pos[1]) * dims[0]) + pos[0];
}

pub const Sprite = struct {
    lo: *const [8]u8,
    hi: ?*const [8]u8,

    const size: u16x2 = @splat(8);

    pub fn init(buf: []const u8) Sprite {
        return if (buf.len == 8)
            .initIcn(buf)
        else if (buf.len == 16)
            .initChr(buf)
        else
            // Bug in caller.
            unreachable;
    }

    pub fn initIcn(buf: []const u8) Sprite {
        std.debug.assert(buf.len == 8);

        return Sprite{
            .lo = @ptrCast(buf),
            .hi = null,
        };
    }

    pub fn initChr(buf: []const u8) Sprite {
        std.debug.assert(buf.len == 16);

        return Sprite{
            .lo = buf[0..8],
            .hi = buf[8..16],
        };
    }

    const bit_magic = true;

    inline fn spreadOut(vec: @Vector(8, u8)) @Vector(8, u16) {
        var tmp: @Vector(8, u16) = vec;

        tmp = (tmp | (tmp << @splat(4))) & @as(@Vector(8, u16), @splat(0x0f0f));
        tmp = (tmp | (tmp << @splat(2))) & @as(@Vector(8, u16), @splat(0x3333));
        tmp = (tmp | (tmp << @splat(1))) & @as(@Vector(8, u16), @splat(0x5555));

        return tmp;
    }

    pub fn renderTo(
        spr: Sprite,
        layer: []u2,
        layer_size: u16x2,
        pos: u16x2,
        blending_mode: u4,
        flip_x: bool,
        flip_y: bool,
    ) void {
        const lo_rows = spreadOut(spr.lo.*);
        const hi_rows = spreadOut(if (spr.hi) |hi| @bitCast(hi.*) else @splat(0));
        const rows = lo_rows | (hi_rows << @splat(1));

        inline for (0..8) |y| {
            const row: @Vector(8, u2) = @bitCast(if (flip_y) rows[7 - y] else rows[y]);

            inline for (0..8) |x| {
                const xr: u16 = @truncate(pos[0] +% x);
                const yr: u16 = @truncate(pos[1] +% y);
                const ch = if (flip_x) row[x] else row[7 - x];

                // TODO: don’t bounds check for every pixel.
                if (blending_mode % 5 != 0 or ch != 0x0000) {
                    if (xr < layer_size[0] and yr < layer_size[1])
                        layer[indexOf(layer_size, u16x2{ xr, yr })] =
                            defaultBlend(ch, blending_mode);
                }
            }
        }
    }
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

pub const Screen = struct {
    // Public
    device: impl.DeviceMixin,

    width: u16 = default_window_width,
    height: u16 = default_window_height,

    dirty_region: ?struct { u16x2, u16x2 } = null,

    foreground: []u2 = undefined,
    background: []u2 = undefined,

    // "Private"
    alloc: Allocator,

    pub fn init(addr: u4, allocator: Allocator) Screen {
        return Screen{
            .device = .init(addr),
            .alloc = allocator,
        };
    }

    fn updateDirtyRegion(
        scr: *Screen,
        from: u16x2,
        to: u16x2,
    ) void {
        if (scr.dirty_region) |*r| {
            r.* = .{
                @min(r.@"0", @min(from, to)),
                @max(r.@"1", @max(from, to)),
            };
        } else {
            scr.dirty_region = .{
                @min(from, to),
                @max(from, to),
            };
        }
    }

    pub fn intercept(
        scr: *Screen,
        cpu: *Cpu,
        port: u4,
        kind: Cpu.InterceptKind,
    ) void {
        if (kind == .input) {
            switch (port) {
                ports.width, ports.width + 1 => {
                    scr.device.storePort(u16, cpu, ports.width, scr.width);
                },

                ports.height, ports.height + 1 => {
                    scr.device.storePort(u16, cpu, ports.height, scr.height);
                },

                else => {},
            }
        } else {
            switch (port) {
                ports.width + 1 => scr.width = scr.device.loadPort(u16, cpu, ports.width),
                ports.height + 1 => scr.height = scr.device.loadPort(u16, cpu, ports.height),

                ports.pixel => {
                    const flags = scr.pixelFlags(cpu);
                    const auto = scr.autoFlags(cpu);
                    const screen = u16x2{ scr.width, scr.height };

                    const layer = if (flags.layer == 0x00) scr.background else scr.foreground;

                    // Make sure to constrain p0 to the actual screen area.
                    const p0 = @min(screen, scr.device.loadSimdVector2(u16, cpu, ports.x, ports.y));

                    var p1: u16x2 = undefined;

                    if (flags.fill) {
                        // Fill to the corner specified by flip_x and flip_y.
                        p1 = .{
                            if (flags.flip_x) 0 else screen[0],
                            if (flags.flip_y) 0 else screen[1],
                        };

                        scr.fillRegion(layer, @min(p0, p1), @max(p0, p1), flags);
                    } else {
                        // Unless the screen itself is 64k x 64k, this cannot overflow.
                        p1 = @min(screen, p0 + u16x2{ 1, 1 });

                        if (@reduce(.And, p0 < screen))
                            layer[scr.index(p0)] = flags.color;

                        if (auto.x) scr.device.storePort(u16, cpu, ports.x, p1[0]);
                        if (auto.y) scr.device.storePort(u16, cpu, ports.y, p1[1]);
                    }

                    scr.updateDirtyRegion(p0, p1);
                },

                ports.sprite => {
                    // This is a surprise tool that will help us later.
                    const zero = u16x2{ 0, 0 };

                    const flags = scr.spriteFlags(cpu);
                    const auto = scr.autoFlags(cpu);

                    var p = scr.device.loadSimdVector2(u16, cpu, ports.x, ports.y);
                    const p0 = p;

                    const flip = bool1x2{ flags.flip_x, flags.flip_y };

                    const dt1 = @intFromBool(bool1x2{ auto.x, auto.y }) * Sprite.size;
                    const dt2 = @intFromBool(bool1x2{ auto.y, auto.x }) * Sprite.size;

                    const layer = if (flags.layer == 0x00) scr.background else scr.foreground;
                    const screen = u16x2{ scr.width, scr.height };

                    var addr = scr.device.loadPort(u16, cpu, ports.addr);

                    for (0..@as(u8, auto.add_length) + 1) |_| {
                        const sprite: Sprite = .init(cpu.mem[addr .. addr + @as(u16, if (flags.two_bpp) 16 else 8)]);

                        sprite.renderTo(
                            layer,
                            screen,
                            p,
                            flags.blending,
                            flags.flip_x,
                            flags.flip_y,
                        );

                        if (auto.addr)
                            addr +%= if (flags.two_bpp) 16 else 8;

                        scr.updateDirtyRegion(
                            @min(screen, @select(u16, p > @as(u16x2, @splat(0x8000)), zero, p)),
                            @min(screen, @select(u16, p > @as(u16x2, @splat(0x8000)), zero, p +% Sprite.size)),
                        );

                        // Update the position by adding or subtracting (depending on flip) the draw-delta
                        // (depending on auto).
                        p +%= @select(u16, flip, zero, dt2);
                        p -%= @select(u16, flip, dt2, zero);
                    }

                    if (auto.x or auto.y) {
                        var next = p0;

                        // See above.
                        next +%= @select(u16, flip, zero, dt1);
                        next -%= @select(u16, flip, dt1, zero);

                        if (auto.x) scr.device.storePort(u16, cpu, ports.x, next[0]);
                        if (auto.y) scr.device.storePort(u16, cpu, ports.y, next[1]);
                    }

                    if (auto.addr)
                        scr.device.storePort(u16, cpu, ports.addr, addr);
                },

                else => {
                    return;
                },
            }

            if (port == ports.width + 1 or port == ports.height + 1) {
                scr.cleanupGraphics();
                scr.initializeGraphics() catch unreachable;
            }
        }
    }

    pub inline fn autoFlags(scr: *const Screen, cpu: *Cpu) AutoFlags {
        return scr.device.loadPort(AutoFlags, cpu, ports.auto);
    }

    pub inline fn spriteFlags(scr: *const Screen, cpu: *Cpu) SpriteFlags {
        return scr.device.loadPort(SpriteFlags, cpu, ports.sprite);
    }

    pub inline fn pixelFlags(scr: *const Screen, cpu: *Cpu) PixelFlags {
        return scr.device.loadPort(PixelFlags, cpu, ports.pixel);
    }

    pub inline fn index(scr: *const Screen, pos: u16x2) usize {
        return indexOf(u16x2{ scr.width, 0 }, pos);
    }

    pub fn renderTiledSprite(
        target_size: u16x2,
        target_pos: u16x2,
        tile_size: u16x2,
        target: []u2,
        flags: SpriteFlags,
        data: []const u8,
    ) void {
        const stride: u16 = if (flags.two_bpp) 16 else 8;

        for (0..tile_size[1]) |y| {
            for (0..tile_size[0]) |x| {
                const sprite: Sprite = .initChr(data[x * stride + y * tile_size[0] * stride ..][0..stride]);

                sprite.renderTo(
                    target,
                    target_size,
                    target_pos + (Sprite.size * u16x2{ @truncate(x), @truncate(y) }),
                    flags.blending,
                    flags.flip_x,
                    flags.flip_y,
                );
            }
        }
    }

    fn fillRegion(
        scr: *Screen,
        layer: []u2,
        top_left: u16x2,
        bottom_right: u16x2,
        flags: PixelFlags,
    ) void {
        const stride = bottom_right[0] - top_left[0];
        var y = top_left[1];

        while (y < bottom_right[1]) : (y += 1) {
            @memset(layer[scr.index(.{ top_left[0], y })..][0..stride], flags.color);
        }
    }

    pub fn forceRedraw(scr: *Screen) void {
        scr.dirty_region = .{
            u16x2{ 0, 0 },
            u16x2{ scr.width, scr.height },
        };
    }

    pub fn initializeGraphics(scr: *Screen) !void {
        logger.debug("Initialize framebuffers ({}x{})", .{ scr.width, scr.height });

        scr.foreground = try scr.alloc.alloc(u2, @as(usize, scr.width) * scr.height);
        errdefer scr.alloc.free(scr.foreground);

        scr.background = try scr.alloc.alloc(u2, @as(usize, scr.width) * scr.height);
        errdefer scr.alloc.free(scr.background);

        @memset(scr.foreground, 0x00);
        @memset(scr.background, 0x00);

        scr.forceRedraw();
    }

    pub fn cleanupGraphics(scr: *Screen) void {
        logger.debug("Destroying framebuffers", .{});

        scr.alloc.free(scr.foreground);
        scr.alloc.free(scr.background);
    }

    pub fn evaluateFrame(scr: *Screen, cpu: *Cpu) !void {
        if (scr.device.loadVector(cpu, ports.vector)) |vector|
            return cpu.evaluateVector(vector);
    }
};
