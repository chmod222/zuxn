const Cpu = @import("uxn-core").Cpu;

const std = @import("std");
const impl = @import("impl.zig");
const logger = std.log.scoped(.uxn_varvara_mouse);

pub const ButtonFlags = packed struct(u8) {
    left: bool,
    middle: bool,
    right: bool,
    _unused: u5,
};

pub const ports = struct {
    pub const vector = 0x0;
    pub const x = 0x2;
    pub const y = 0x4;
    pub const state = 0x6;
    pub const scroll_x = 0xa;
    pub const scroll_y = 0xc;
};

pub const Mouse = struct {
    device: impl.DeviceMixin,

    pub fn intercept(
        mouse: @This(),
        cpu: *Cpu,
        port: u4,
        kind: Cpu.InterceptKind,
    ) !void {
        _ = mouse;
        _ = cpu;
        _ = port;
        _ = kind;
    }

    fn invokeVector(mouse: *@This(), cpu: *Cpu) !void {
        const vector = mouse.device.loadPort(u16, cpu, ports.vector);

        if (vector > 0)
            try cpu.evaluateVector(vector);
    }

    pub fn pressButtons(mouse: *@This(), cpu: *Cpu, buttons: ButtonFlags) !void {
        const old_state = mouse.device.loadPort(u8, cpu, ports.state);
        const new_state = old_state | @as(u8, @bitCast(buttons));

        logger.debug("Button State: {}", .{@as(ButtonFlags, @bitCast(new_state))});

        mouse.device.storePort(u8, cpu, ports.state, new_state);

        try mouse.invokeVector(cpu);
    }

    pub fn releaseButtons(mouse: *@This(), cpu: *Cpu, buttons: ButtonFlags) !void {
        const old_state = mouse.device.loadPort(u8, cpu, ports.state);
        const new_state = old_state & ~@as(u8, @bitCast(buttons));

        logger.debug("Button State: {}", .{@as(ButtonFlags, @bitCast(new_state))});

        mouse.device.storePort(u8, cpu, ports.state, new_state);

        try mouse.invokeVector(cpu);
    }

    pub fn updatePosition(mouse: *@This(), cpu: *Cpu, x: u16, y: u16) !void {
        logger.debug("Set position: X: {}; Y: {}", .{ x, y });

        mouse.device.storePort(u16, cpu, ports.x, x);
        mouse.device.storePort(u16, cpu, ports.y, y);

        try mouse.invokeVector(cpu);
    }

    pub fn updateScroll(mouse: *@This(), cpu: *Cpu, x: i32, y: i32) !void {
        logger.debug("Scrolling: X: {}; Y: {}", .{ x, -y });

        mouse.device.storePort(i16, cpu, ports.scroll_x, @as(i16, @truncate(x)));
        mouse.device.storePort(i16, cpu, ports.scroll_y, @as(i16, @truncate(-y)));

        defer {
            mouse.device.storePort(u16, cpu, ports.scroll_x, 0);
            mouse.device.storePort(u16, cpu, ports.scroll_y, 0);
        }

        try mouse.invokeVector(cpu);
    }
};
