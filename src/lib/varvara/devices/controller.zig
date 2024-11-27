const Cpu = @import("uxn-core").Cpu;

const std = @import("std");
const logger = std.log.scoped(.uxn_varvara_controller);

pub const ButtonFlags = packed struct(u8) {
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    start: bool = false,
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,
};

pub const ports = struct {
    pub const vector = 0x0;
    pub const buttons = 0x2;
    pub const key = 0x3;
    pub const p2 = 0x5;
    pub const p3 = 0x6;
    pub const p4 = 0x7;
};

pub const Controller = struct {
    addr: u4,

    pub usingnamespace @import("impl.zig").DeviceMixin(@This());

    pub fn intercept(
        dev: *@This(),
        cpu: *Cpu,
        port: u4,
        kind: Cpu.InterceptKind,
    ) !void {
        _ = dev;
        _ = cpu;
        _ = port;
        _ = kind;
    }

    fn invokeVector(dev: *@This(), cpu: *Cpu) !void {
        const vector = dev.loadPort(u16, cpu, ports.vector);

        if (vector > 0)
            try cpu.evaluateVector(vector);
    }

    fn getPlayerPort(player: u2) u4 {
        return switch (player) {
            0x0 => ports.buttons,
            0x1 => ports.p2,
            0x2 => ports.p3,
            0x3 => ports.p4,
        };
    }

    pub fn pressKey(dev: *@This(), cpu: *Cpu, key: u8) !void {
        logger.debug("Sending key press: {x:0>2}", .{key});

        dev.storePort(u8, cpu, ports.key, key);

        try dev.invokeVector(cpu);
    }

    pub fn pressButtons(dev: *@This(), cpu: *Cpu, buttons: ButtonFlags, player: u2) !void {
        const playerPort = getPlayerPort(player);

        const old_state = dev.loadPort(u8, cpu, playerPort);
        const new_state = old_state | @as(u8, @bitCast(buttons));

        logger.debug("Button State: {} (Player: {})", .{ @as(ButtonFlags, @bitCast(new_state)), player });

        dev.storePort(u8, cpu, playerPort, new_state);

        try dev.invokeVector(cpu);
    }

    pub fn releaseButtons(dev: *@This(), cpu: *Cpu, buttons: ButtonFlags, player: u2) !void {
        const playerPort = getPlayerPort(player);

        const old_state = dev.loadPort(u8, cpu, playerPort);
        const new_state = old_state & ~@as(u8, @bitCast(buttons));

        logger.debug("Button State: {} (Player: {})", .{ @as(ButtonFlags, @bitCast(new_state)), player });

        dev.storePort(u8, cpu, playerPort, new_state);

        try dev.invokeVector(cpu);
    }
};
