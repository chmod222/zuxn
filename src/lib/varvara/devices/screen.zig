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

fn Vec2(T: type) type {
    return struct {
        x: T, // or: width
        y: T, // or: height

        pub const zero = Vec2(T).init(0, 0);

        pub fn init(x: T, y: T) Vec2(T) {
            return .{
                .x = x,
                .y = y,
            };
        }

        fn clampTo(vec: *const Vec2(T), min: Vec2(T), max: Vec2(T)) Vec2(T) {
            return .init(
                @max(@min(vec.x, max.x), min.x),
                @max(@min(vec.y, max.y), min.y),
            );
        }
    };
}

fn Rect(T: type) type {
    return struct {
        top_left: Vec2(T),
        bottom_right: Vec2(T),

        fn init(a: Vec2(T), b: Vec2(T)) Rect(T) {
            return Rect(T){
                .top_left = .init(
                    @min(a.x, b.x),
                    @min(a.y, b.y),
                ),
                .bottom_right = .init(
                    @max(a.x, b.x),
                    @max(a.y, b.y),
                ),
            };
        }

        fn extend(rect: *const Rect(T), other: Rect(T)) Rect(T) {
            // This assumes that top_left is always actually the top
            // left corner of each rectangle. Violating this
            // assumption will cause fun.
            return .{
                .top_left = .init(
                    @min(rect.top_left.x, other.top_left.x),
                    @min(rect.top_left.y, other.top_left.y),
                ),
                .bottom_right = .init(
                    @max(rect.bottom_right.x, other.bottom_right.x),
                    @max(rect.bottom_right.y, other.bottom_right.y),
                ),
            };
        }
    };
}

pub const Sprite = struct {
    lo: []const u8,
    hi: ?[]const u8,

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
            .lo = buf,
            .hi = null,
        };
    }

    pub fn initChr(buf: []const u8) Sprite {
        std.debug.assert(buf.len == 16);

        return Sprite{
            .lo = buf[0..8],
            .hi = buf[8..],
        };
    }

    pub fn renderTo(
        spr: Sprite,
        layer: []u2,
        layer_size: Vec2(u16),
        pos: Vec2(u16),
        blending_mode: u4,
        flip_x: bool,
        flip_y: bool,
    ) void {
        var y: u16 = 0;

        while (y < 8) : (y += 1) {
            const c1 = spr.lo[y];
            const c2 = if (spr.hi) |d| d[y] else 0;

            var x: u16 = 0;

            while (x < 8) : (x += 1) {
                const ch: u2 = @truncate(((c1 >> @truncate(x)) & 1) | (((c2 >> @truncate(x)) << 1) & 2));

                const yr = pos.y +% (if (flip_y) @as(u16, @intCast(7 - y)) else y);
                const xr = pos.x +% (if (flip_x) x else @as(u16, @intCast(7 - x)));

                if (blending_mode % 5 != 0 or ch != 0x0000) {
                    if (xr < layer_size.x and yr < layer_size.y)
                        layer[@as(usize, yr) * layer_size.x + xr] =
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

    dirty_region: ?Rect(u16) = null,

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
        region: Rect(u16),
    ) void {
        if (scr.dirty_region) |*r|
            r.* = r.extend(region)
        else
            scr.dirty_region = region;
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
                    const flags = scr.device.loadPort(PixelFlags, cpu, ports.pixel);
                    const auto = scr.device.loadPort(AutoFlags, cpu, ports.auto);

                    const layer = if (flags.layer == 0x00) scr.background else scr.foreground;

                    var p0: Vec2(u16) = .init(
                        scr.device.loadPort(u16, cpu, ports.x),
                        scr.device.loadPort(u16, cpu, ports.y),
                    );

                    var p1: Vec2(u16) = undefined;

                    if (flags.fill) {
                        // Fill to the corner specified by flip_x and flip_y.
                        p1 = .init(
                            if (flags.flip_x) 0 else scr.width,
                            if (flags.flip_y) 0 else scr.height,
                        );

                        // Ensure p0 is top-left to p1
                        if (p0.x > p1.x) std.mem.swap(u16, &p0.x, &p1.x);
                        if (p0.y > p1.y) std.mem.swap(u16, &p0.y, &p1.y);

                        scr.fillRegion(layer, .init(p0, p1), flags);
                    } else {
                        p1 = .init(p0.x +% 1, p0.y +% 1);

                        if (p0.x < scr.width and p0.y < scr.height)
                            layer[p0.y * scr.width + p0.x] = flags.color;

                        if (auto.x) scr.device.storePort(u16, cpu, ports.x, p1.x);
                        if (auto.y) scr.device.storePort(u16, cpu, ports.y, p1.y);
                    }

                    scr.updateDirtyRegion(.init(
                        scr.clampToScreen(p0),
                        scr.clampToScreen(p1),
                    ));
                },

                ports.sprite => {
                    const flags = scr.device.loadPort(SpriteFlags, cpu, ports.sprite);
                    const auto = scr.device.loadPort(AutoFlags, cpu, ports.auto);

                    const p: Vec2(i16) = .init(
                        scr.device.loadPort(i16, cpu, ports.x),
                        scr.device.loadPort(i16, cpu, ports.y),
                    );

                    const d: Vec2(i16) = .init(if (auto.x) 8 else 0, if (auto.y) 8 else 0);
                    const f: Vec2(i16) = .init(if (flags.flip_x) -1 else 1, if (flags.flip_y) -1 else 1);

                    const da: u16 = if (auto.addr) if (flags.two_bpp) 16 else 8 else 0;
                    const l: u8 = @as(u8, auto.add_length) + 1;

                    const layer = if (flags.layer == 0x00) scr.background else scr.foreground;

                    var addr = scr.device.loadPort(u16, cpu, ports.addr);

                    for (0..l) |i| {
                        const ic: i16 = @intCast(i);
                        const sprite: Sprite = .init(cpu.mem[addr .. addr + @as(u16, if (flags.two_bpp) 16 else 8)]);

                        sprite.renderTo(
                            layer,
                            scr.screen(),
                            .init(
                                // dy and dx flipped in original implementation
                                @bitCast(p.x +% (d.y * f.x * ic)),
                                @bitCast(p.y +% (d.x * f.y * ic)),
                            ),
                            flags.blending,
                            flags.flip_x,
                            flags.flip_y,
                        );

                        addr +%= da;
                    }

                    scr.updateDirtyRegion(
                        .init(
                            .init(
                                @min(scr.width, @max(0, p.x)),
                                @min(scr.height, @max(0, p.y)),
                            ),
                            .init(
                                @min(scr.width, @max(0, @as(usize, @bitCast(@as(isize, p.x) +% (d.y * f.x * l) +% 8)))),
                                @min(scr.height, @max(0, @as(usize, @bitCast(@as(isize, p.y) +% (d.x * f.y * l) +% 8)))),
                            ),
                        ),
                    );

                    if (auto.x) scr.device.storePort(i16, cpu, ports.x, p.x +% d.x * f.x);
                    if (auto.y) scr.device.storePort(i16, cpu, ports.y, p.y +% d.y * f.y);
                    if (auto.addr) scr.device.storePort(u16, cpu, ports.addr, addr);
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

    fn screen(scr: *const Screen) Vec2(u16) {
        return .init(scr.width, scr.height);
    }

    fn clampToScreen(scr: *const Screen, vec: Vec2(u16)) Vec2(u16) {
        return vec.clampTo(.zero, scr.screen());
    }

    pub fn renderTiledSprite(
        target_size: Vec2(u16),
        target_pos: Vec2(u16),
        tile_size: Vec2(u16),
        target: []u2,
        flags: SpriteFlags,
        data: []const u8,
    ) void {
        const stride: u16 = if (flags.two_bpp) 16 else 8;

        for (0..tile_size.y) |y| {
            for (0..tile_size.x) |x| {
                const sprite: Sprite = .initChr(data[x * stride + y * tile_size.x * stride ..][0..stride]);

                sprite.renderTo(
                    target,
                    target_size,
                    .init(
                        target_pos.x + 8 * @as(u16, @truncate(x)),
                        target_pos.y + 8 * @as(u16, @truncate(y)),
                    ),
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
        region: Rect(u16),
        flags: PixelFlags,
    ) void {
        var y = region.top_left.y;

        while (y < @min(scr.height, region.bottom_right.y)) : (y += 1) {
            var x = region.top_left.x;

            while (x < @min(scr.width, region.bottom_right.x)) : (x += 1) {
                layer[@as(usize, y) * scr.width + x] = flags.color;
            }
        }
    }

    pub fn forceRedraw(scr: *Screen) void {
        scr.dirty_region = .{
            .top_left = .zero,
            .bottom_right = scr.screen(),
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
