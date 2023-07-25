const Cpu = @import("../Cpu.zig");
const std = @import("std");

addr: u4,

pub const ports = struct {
    const vector = 0x0;
    const read = 0x2;
    const typ = 0x7;
    const write = 0x8;
    const err = 0x9;
};

pub fn intercept(
    dev: @This(),
    cpu: *Cpu,
    port: u4,
    kind: Cpu.InterceptKind,
) !void {
    if (kind != .output)
        return;

    if (port != ports.write)
        return;

    const base = @as(u8, dev.addr) << 4;

    std.debug.print("{c}", .{cpu.device_mem[base | port]});
}

pub fn push_arguments(
    dev: @This(),
    cpu: *Cpu,
    args: [][:0]const u8,
) !void {
    const base = @as(u8, dev.addr) << 4;

    for (0.., args) |i, arg| {
        for (arg) |oct| {
            cpu.device_mem[base | ports.typ] = 0x2;
            cpu.device_mem[base | ports.read] = oct;

            try cpu.evaluate_vector(cpu.load_device_mem(u16, base | ports.vector));
        }

        cpu.device_mem[base | ports.typ] = if (i == args.len - 1) 0x4 else 0x3;
        cpu.device_mem[base | ports.read] = 0x10;

        try cpu.evaluate_vector(cpu.load_device_mem(u16, base | ports.vector));
    }
}

pub fn set_argc(
    dev: @This(),
    cpu: *Cpu,
    args: [][:0]const u8,
) void {
    const base = @as(u8, dev.addr) << 4;

    cpu.device_mem[base | ports.typ] = @intFromBool(args.len > 0);
}

pub fn push_stdin_byte(
    dev: @This(),
    cpu: *Cpu,
    byte: u8,
) !void {
    const base = @as(u8, dev.addr) << 4;
    const vector = cpu.load_device_mem(u16, base | ports.vector);

    cpu.device_mem[base | ports.typ] = 0x1;
    cpu.device_mem[base | ports.read] = byte;

    if (vector > 0x0000)
        try cpu.evaluate_vector(vector);
}
