const Cpu = @import("uxn-core").Cpu;
const std = @import("std");

addr: u4,

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

pub fn intercept(
    dev: *@This(),
    cpu: *Cpu,
    port: u4,
    kind: Cpu.InterceptKind,
) !void {
    const base = @as(u8, dev.addr) << 4;

    _ = cpu;
    _ = port;
    _ = kind;
    _ = base;
}

fn invoke_vector(dev: *@This(), cpu: *Cpu) !void {
    const base = @as(u8, dev.addr) << 4;

    const vector = cpu.load_device_mem(u16, base | ports.vector);

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
    const base = @as(u8, dev.addr) << 4;

    cpu.store_device_mem(u8, base | ports.key, key);

    try dev.invoke_vector(cpu);
}

pub fn press_buttons(dev: *@This(), cpu: *Cpu, buttons: ButtonFlags, player: u2) !void {
    const base = @as(u8, dev.addr) << 4;
    const player_port = get_player_port(player);

    const old_state = cpu.load_device_mem(u8, base | player_port);

    cpu.store_device_mem(u8, base | player_port, old_state | @as(u8, @bitCast(buttons)));

    try dev.invoke_vector(cpu);
}

pub fn release_buttons(dev: *@This(), cpu: *Cpu, buttons: ButtonFlags, player: u2) !void {
    const base = @as(u8, dev.addr) << 4;
    const player_port = get_player_port(player);

    const old_state = cpu.load_device_mem(u8, base | player_port);

    cpu.store_device_mem(u8, base | player_port, old_state & ~@as(u8, @bitCast(buttons)));

    try dev.invoke_vector(cpu);
}
