const Cpu = @import("uxn-core").Cpu;

const std = @import("std");
const logger = std.log.scoped(.uxn_varvara_screen);

const default_window_width = 512;
const default_window_height = 320;

pub const Rect = struct {
    x0: usize,
    y0: usize,
    x1: usize,
    y1: usize,
};

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

pub const Screen = struct {
    // Public
    addr: u4,

    width: u16 = default_window_width,
    height: u16 = default_window_height,

    dirty_region: ?Rect = null,

    foreground: []u2 = undefined,
    background: []u2 = undefined,

    // "Private"
    alloc: std.mem.Allocator,

    pub usingnamespace @import("impl.zig").DeviceMixin(@This());

    fn normalizeRegion(
        dev: *@This(),
        region: *Rect,
    ) void {
        var x0: u16 = @truncate(region.x0);
        var y0: u16 = @truncate(region.y0);
        const x1: u16 = @truncate(region.x1);
        const y1: u16 = @truncate(region.y1);

        if (x0 > x1) x0 = 0;
        if (y0 > y1) y0 = 0;

        region.x0 = @min(dev.width, x0);
        region.y0 = @min(dev.height, y0);
        region.x1 = @min(dev.width, x1);
        region.y1 = @min(dev.height, y1);
    }

    fn updateDirtyRegion(
        dev: *@This(),
        x0: usize,
        y0: usize,
        x1: usize,
        y1: usize,
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

        _ = x0;
        _ = y0;
        _ = x1;
        _ = y1;

        dev.forceRedraw();
    }

    pub fn intercept(
        dev: *@This(),
        cpu: *Cpu,
        port: u4,
        kind: Cpu.InterceptKind,
    ) !void {
        if (kind == .input) {
            switch (port) {
                ports.width, ports.width + 1 => {
                    dev.storePort(u16, cpu, ports.width, dev.width);
                },

                ports.height, ports.height + 1 => {
                    dev.storePort(u16, cpu, ports.height, dev.height);
                },

                else => {},
            }
        } else {
            switch (port) {
                ports.width + 1 => dev.width = dev.loadPort(u16, cpu, ports.width),
                ports.height + 1 => dev.height = dev.loadPort(u16, cpu, ports.height),

                ports.pixel => {
                    const flags = dev.loadPort(PixelFlags, cpu, ports.pixel);
                    const auto = dev.loadPort(AutoFlags, cpu, ports.auto);

                    var x0 = dev.loadPort(u16, cpu, ports.x);
                    var y0 = dev.loadPort(u16, cpu, ports.y);

                    var x1: u16 = undefined;
                    var y1: u16 = undefined;

                    const layer = if (flags.layer == 0x00) dev.background else dev.foreground;

                    if (flags.fill) {
                        x1 = if (flags.flip_x) 0 else dev.width;
                        y1 = if (flags.flip_y) 0 else dev.height;

                        if (x0 > x1) std.mem.swap(u16, &x0, &x1);
                        if (y0 > y1) std.mem.swap(u16, &y0, &y1);

                        dev.fillRegion(layer, x0, y0, x1, y1, flags);
                    } else {
                        x1 = x0 +% 1;
                        y1 = y0 +% 1;

                        if (x0 < dev.width and y0 < dev.height)
                            layer[@as(usize, y0) * dev.width + x0] = flags.color;

                        if (auto.x) dev.storePort(u16, cpu, ports.x, x1);
                        if (auto.y) dev.storePort(u16, cpu, ports.y, y1);
                    }

                    dev.updateDirtyRegion(x0, y0, x1, y1);
                },

                ports.sprite => {
                    const flags = dev.loadPort(SpriteFlags, cpu, ports.sprite);
                    const auto = dev.loadPort(AutoFlags, cpu, ports.auto);

                    const x = dev.loadPort(i16, cpu, ports.x);
                    const y = dev.loadPort(i16, cpu, ports.y);

                    const dx: i16 = if (auto.x) 8 else 0;
                    const dy: i16 = if (auto.y) 8 else 0;

                    const fx: i16 = if (flags.flip_x) -1 else 1;
                    const fy: i16 = if (flags.flip_y) -1 else 1;

                    const da: u16 = if (auto.addr) if (flags.two_bpp) 16 else 8 else 0;
                    const l: u8 = @as(u8, auto.add_length) + 1;

                    const layer = if (flags.layer == 0x00) dev.background else dev.foreground;

                    var addr = dev.loadPort(u16, cpu, ports.addr);

                    for (0..l) |i| {
                        const ic: i16 = @intCast(i);

                        // dy and dx flipped in original implementation
                        dev.renderSprite(
                            cpu,
                            layer,
                            flags,
                            @bitCast(x +% (dy * fx * ic)),
                            @bitCast(y +% (dx * fy * ic)),
                            addr,
                        );

                        addr +%= da;
                    }

                    dev.updateDirtyRegion(
                        @as(u16, @bitCast(x)),
                        @as(u16, @bitCast(y)),
                        @as(u16, @truncate(@as(usize, @bitCast(@as(isize, x) +% (dy * fx * l) +% 8)))),
                        @as(u16, @truncate(@as(usize, @bitCast(@as(isize, y) +% (dx * fy * l) +% 8)))),
                    );

                    if (auto.x) dev.storePort(i16, cpu, ports.x, x +% dx * fx);
                    if (auto.y) dev.storePort(i16, cpu, ports.y, y +% dy * fy);
                    if (auto.addr) dev.storePort(u16, cpu, ports.addr, addr);
                },

                else => {
                    return;
                },
            }

            if (port == ports.width + 1 or port == ports.height + 1) {
                dev.cleanupGraphics();
                dev.initializeGraphics() catch unreachable;
            }
        }
    }

    fn renderSprite(
        dev: *@This(),
        cpu: *Cpu,
        layer: []u2,
        flags: SpriteFlags,
        x0: u16,
        y0: u16,
        addr: u16,
    ) void {
        const opaq = flags.blending % 5 != 0;

        var y: u16 = 0;

        while (y < 8) : (y += 1) {
            const c1 = cpu.mem[addr +% y];
            const c2 = if (flags.two_bpp) cpu.mem[addr +% (y +% 8)] else 0;

            var x: u16 = 0;

            while (x < 8) : (x += 1) {
                const ch = ((c1 >> @truncate(x)) & 1) | (((c2 >> @truncate(x)) << 1) & 2);

                const yr = y0 +% (if (flags.flip_y) 7 - y else y);
                const xr = x0 +% (if (flags.flip_x) x else 7 - x);

                if (opaq or ch != 0x0000) {
                    if (xr < dev.width and yr < dev.height)
                        layer[@as(usize, yr) * dev.width + xr] = blending[ch][flags.blending];
                }
            }
        }
    }

    fn fillRegion(
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

    pub fn forceRedraw(dev: *@This()) void {
        dev.dirty_region = .{
            .x0 = 0,
            .y0 = 0,
            .x1 = dev.width,
            .y1 = dev.height,
        };
    }

    pub fn initializeGraphics(dev: *@This()) !void {
        logger.debug("Initialize framebuffers ({}x{})", .{ dev.width, dev.height });

        dev.foreground = try dev.alloc.alloc(u2, @as(usize, dev.width) * dev.height);
        errdefer dev.alloc.free(dev.foreground);

        dev.background = try dev.alloc.alloc(u2, @as(usize, dev.width) * dev.height);
        errdefer dev.alloc.free(dev.background);

        @memset(dev.foreground, 0x00);
        @memset(dev.background, 0x00);

        dev.forceRedraw();
    }

    pub fn cleanupGraphics(dev: *@This()) void {
        logger.debug("Destroying framebuffers", .{});

        dev.alloc.free(dev.foreground);
        dev.alloc.free(dev.background);
    }

    pub fn evaluateFrame(dev: *@This(), cpu: *Cpu) !void {
        const vector = dev.loadPort(u16, cpu, ports.vector);

        if (vector != 0x0000)
            return cpu.evaluateVector(vector);
    }
};
