const Cpu = @import("../Cpu.zig");
const std = @import("std");

addr: u4,

pub const ports = struct {
    const vector = 0x0;
    const x = 0x2;
    const y = 0x4;
    const state = 0x6;
    const scroll_x = 0xa;
    const scroll_y = 0xc;
};

pub const ButtonFlags = packed struct(u8) {
    left: bool,
    middle: bool,
    right: bool,
    _unused: u5,
};

pub fn intercept(
    dev: @This(),
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
    const base = @as(u8, dev.addr) << 4;

    const vector = cpu.load_device_mem(u16, base | ports.vector);

    if (vector > 0)
        try cpu.evaluate_vector(vector);
}

pub fn press_buttons(dev: *@This(), cpu: *Cpu, buttons: ButtonFlags) !void {
    const base = @as(u8, dev.addr) << 4;

    const old_state = cpu.load_device_mem(u8, base | ports.state);

    cpu.store_device_mem(u8, base | ports.state, old_state | @as(u8, @bitCast(buttons)));

    try dev.invoke_vector(cpu);
}

pub fn release_buttons(dev: *@This(), cpu: *Cpu, buttons: ButtonFlags) !void {
    const base = @as(u8, dev.addr) << 4;

    const old_state = cpu.load_device_mem(u8, base | ports.state);

    cpu.store_device_mem(u8, base | ports.state, old_state & ~@as(u8, @bitCast(buttons)));

    try dev.invoke_vector(cpu);
}

pub fn update_position(dev: *@This(), cpu: *Cpu, x: u16, y: u16) !void {
    const base = @as(u8, dev.addr) << 4;

    cpu.store_device_mem(u16, base | ports.x, x);
    cpu.store_device_mem(u16, base | ports.y, y);

    try dev.invoke_vector(cpu);
}

pub fn update_scroll(dev: *@This(), cpu: *Cpu, x: i32, y: i32) !void {
    const base = @as(u8, dev.addr) << 4;

    cpu.store_device_mem(u16, base | ports.scroll_x, @as(u16, @bitCast(@as(i16, @truncate(x)))));
    cpu.store_device_mem(u16, base | ports.scroll_y, @as(u16, @bitCast(@as(i16, @truncate(y)))));

    try dev.invoke_vector(cpu);
}
