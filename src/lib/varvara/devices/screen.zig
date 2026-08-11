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

fn Vec2(T: type) type {
    return struct {
        x: T, // or: width
        y: T, // or: height

        pub fn init(x: T, y: T) @This() {
            return .{
                .x = x,
                .y = y,
            };
        }
    };
}

fn Rect(T: type) type {
    return struct {
        top_left: Vec2(T),
        bottom_right: Vec2(T),
    };
}

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

    fn normalizeRegion(
        scr: *Screen,
        region: *Rect(u16),
    ) void {
        var x0: u16 = @truncate(region.top_left.x);
        var y0: u16 = @truncate(region.top_left.y);
        const x1: u16 = @truncate(region.bottom_right.x);
        const y1: u16 = @truncate(region.bottom_right.y);

        if (x0 > x1) x0 = 0;
        if (y0 > y1) y0 = 0;

        region.x0 = @min(scr.width, x0);
        region.y0 = @min(scr.height, y0);
        region.x1 = @min(scr.width, x1);
        region.y1 = @min(scr.height, y1);
    }

    fn updateDirtyRegion(
        scr: *Screen,
        region: Rect(u16),
    ) void {
        //if (dev.dirty_region) |*region| {
        //    if (x0 < region.x0) region.x0 = x0;
        //    if (y0 < region.y0) region.y0 = y0;
        //    if (x1 > region.x1) region.x1 = x1;
        //    if (y1 > region.y1) region.y1 = y1;
        //
        //    dev.normalize_region(region);
        //} else {
        //    var region: Rect = .{
        //        .x0 = x0,
        //        .y0 = y0,
        //        .x1 = x1,
        //        .y1 = y1,
        //    };
        //
        //    dev.normalize_region(&region);
        //
        //    dev.dirty_region = region;
        //}

        _ = region;

        scr.forceRedraw();
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

                    var x0 = scr.device.loadPort(u16, cpu, ports.x);
                    var y0 = scr.device.loadPort(u16, cpu, ports.y);

                    var x1: u16 = undefined;
                    var y1: u16 = undefined;

                    const layer = if (flags.layer == 0x00) scr.background else scr.foreground;

                    if (flags.fill) {
                        x1 = if (flags.flip_x) 0 else scr.width;
                        y1 = if (flags.flip_y) 0 else scr.height;

                        if (x0 > x1) std.mem.swap(u16, &x0, &x1);
                        if (y0 > y1) std.mem.swap(u16, &y0, &y1);

                        scr.fillRegion(layer, .{
                            .top_left = .init(x0, y0),
                            .bottom_right = .init(x1, y1),
                        }, flags);
                    } else {
                        x1 = x0 +% 1;
                        y1 = y0 +% 1;

                        if (x0 < scr.width and y0 < scr.height)
                            layer[@as(usize, y0) * scr.width + x0] = flags.color;

                        if (auto.x) scr.device.storePort(u16, cpu, ports.x, x1);
                        if (auto.y) scr.device.storePort(u16, cpu, ports.y, y1);
                    }

                    scr.updateDirtyRegion(.{
                        .top_left = .init(x0, y0),
                        .bottom_right = .init(x1, y1),
                    });
                },

                ports.sprite => {
                    const flags = scr.device.loadPort(SpriteFlags, cpu, ports.sprite);
                    const auto = scr.device.loadPort(AutoFlags, cpu, ports.auto);

                    const x = scr.device.loadPort(i16, cpu, ports.x);
                    const y = scr.device.loadPort(i16, cpu, ports.y);

                    const dx: i16 = if (auto.x) 8 else 0;
                    const dy: i16 = if (auto.y) 8 else 0;

                    const fx: i16 = if (flags.flip_x) -1 else 1;
                    const fy: i16 = if (flags.flip_y) -1 else 1;

                    const da: u16 = if (auto.addr) if (flags.two_bpp) 16 else 8 else 0;
                    const l: u8 = @as(u8, auto.add_length) + 1;

                    const layer = if (flags.layer == 0x00) scr.background else scr.foreground;

                    var addr = scr.device.loadPort(u16, cpu, ports.addr);

                    for (0..l) |i| {
                        const ic: i16 = @intCast(i);

                        // dy and dx flipped in original implementation
                        scr.renderSpriteToScreen(
                            cpu,
                            layer,
                            flags,
                            .init(
                                @bitCast(x +% (dy * fx * ic)),
                                @bitCast(y +% (dx * fy * ic)),
                            ),
                            addr,
                        );

                        addr +%= da;
                    }

                    scr.updateDirtyRegion(
                        .{
                            .top_left = .init(@bitCast(x), @bitCast(y)),
                            .bottom_right = .init(
                                @truncate(@as(usize, @bitCast(@as(isize, x) +% (dy * fx * l) +% 8))),
                                @truncate(@as(usize, @bitCast(@as(isize, y) +% (dx * fy * l) +% 8))),
                            ),
                        },
                    );

                    if (auto.x) scr.device.storePort(i16, cpu, ports.x, x +% dx * fx);
                    if (auto.y) scr.device.storePort(i16, cpu, ports.y, y +% dy * fy);
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

    fn renderSpriteToScreen(
        scr: *Screen,
        cpu: *Cpu,
        layer: []u2,
        flags: SpriteFlags,
        pos: Vec2(u16),
        addr: u16,
    ) void {
        return renderSprite(
            .init(scr.width, scr.height),
            pos,
            layer,
            flags,
            cpu.mem[addr .. addr + @as(usize, if (flags.two_bpp) 16 else 8)],
        );
    }

    fn defaultBlend(color: u2, mode: u4) u2 {
        return blending[color][mode];
    }

    pub fn renderTiledSprite(
        target_size: Vec2(u16),
        target_pos: Vec2(u16),
        tile_size: Vec2(u16),
        target: []u2,
        flags: SpriteFlags,
        data: []const u8,
    ) void {
        for (0..tile_size.y) |y| {
            for (0..tile_size.x) |x| {
                renderSprite(
                    target_size,
                    .init(
                        target_pos.x + 8 * @as(u16, @truncate(x)),
                        target_pos.y + 8 * @as(u16, @truncate(y)),
                    ),
                    target,
                    flags,
                    data[x * 16 + y * 48 ..],
                );
            }
        }
    }

    pub fn renderSprite(
        target_size: Vec2(u16),
        target_pos: Vec2(u16),
        target: []u2,
        flags: SpriteFlags,
        data: []const u8,
    ) void {
        const size = Vec2(u16).init(8, 8);
        const opaq = flags.blending % 5 != 0;

        var y: u16 = 0;

        while (y < size.y) : (y += 1) {
            const c1 = data[y];
            const c2 = if (flags.two_bpp) data[y +% size.x] else 0;

            var x: u16 = 0;

            while (x < size.x) : (x += 1) {
                const ch: u2 = @truncate(((c1 >> @truncate(x)) & 1) | (((c2 >> @truncate(x)) << 1) & 2));

                const yr = target_pos.y +% (if (flags.flip_y) @as(u16, @intCast(size.y - 1 - y)) else y);
                const xr = target_pos.x +% (if (flags.flip_x) x else @as(u16, @intCast(size.x - 1 - x)));

                if (opaq or ch != 0x0000) {
                    if (xr < target_size.x and yr < target_size.y)
                        target[@as(usize, yr) * target_size.x + xr] =
                            defaultBlend(ch, flags.blending);
                }
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

        while (y < region.bottom_right.y) : (y += 1) {
            var x = region.bottom_right.x;

            while (x < region.bottom_right.x) : (x += 1) {
                layer[@as(usize, y) * scr.width + x] = flags.color;
            }
        }
    }

    pub fn forceRedraw(scr: *Screen) void {
        scr.dirty_region = .{
            .top_left = .init(0, 0),
            .bottom_right = .init(scr.width, scr.height),
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
