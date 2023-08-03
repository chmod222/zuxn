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

    fn invoke_vector(dev: *@This(), cpu: *Cpu) !void {
        const vector = cpu.load_device_mem(u16, dev.port_address(ports.vector));

        if (vector > 0)
            try cpu.evaluate_vector(vector);
    }

    fn get_player_port(player: u2) u4 {
        return switch (player) {
            0x0 => ports.buttons,
            0x1 => ports.p2,
            0x2 => ports.p3,
            0x3 => ports.p4,
        };
    }

    pub fn press_key(dev: *@This(), cpu: *Cpu, key: u8) !void {
        logger.debug("Sending key press: {x:0>2}", .{key});

        cpu.store_device_mem(u8, dev.port_address(ports.key), key);

        try dev.invoke_vector(cpu);
    }

    pub fn press_buttons(dev: *@This(), cpu: *Cpu, buttons: ButtonFlags, player: u2) !void {
        const player_port = get_player_port(player);

        const old_state = cpu.load_device_mem(u8, dev.port_address(player_port));
        const new_state = old_state | @as(u8, @bitCast(buttons));

        logger.debug("Button State: {}", .{@as(ButtonFlags, @bitCast(new_state))});

        cpu.store_device_mem(u8, dev.port_address(player_port), new_state);

        try dev.invoke_vector(cpu);
    }

    pub fn release_buttons(dev: *@This(), cpu: *Cpu, buttons: ButtonFlags, player: u2) !void {
        const player_port = get_player_port(player);

        const old_state = cpu.load_device_mem(u8, dev.port_address(player_port));
        const new_state = old_state & ~@as(u8, @bitCast(buttons));

        logger.debug("Button State: {}", .{@as(ButtonFlags, @bitCast(new_state))});

        cpu.store_device_mem(u8, dev.port_address(player_port), new_state);

        try dev.invoke_vector(cpu);
    }
};
