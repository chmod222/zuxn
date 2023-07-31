const Cpu = @import("uxn-core").Cpu;

const std = @import("std");
const logger = std.log.scoped(.uxn_varvara_console);

addr: u4,

pub const ports = struct {
    pub const vector = 0x0;
    pub const read = 0x2;
    pub const typ = 0x7;
    pub const write = 0x8;
    pub const err = 0x9;
};

pub usingnamespace @import("impl.zig").DeviceMixin(@This());

pub fn intercept(
    dev: @This(),
    cpu: *Cpu,
    port: u4,
    kind: Cpu.InterceptKind,
    stdout_writer: anytype,
    stderr_writer: anytype,
) !void {
    if (kind != .output)
        return;

    if (port != ports.write and port != ports.err)
        return;

    const octet = cpu.device_mem[dev.port_address(port)];

    if (port == ports.write) {
        _ = stdout_writer.write(&[_]u8{octet}) catch return;
    } else if (port == ports.err) {
        _ = stderr_writer.write(&[_]u8{octet}) catch return;
    }
}

pub fn push_arguments(
    dev: @This(),
    cpu: *Cpu,
    args: [][]const u8,
) !void {
    for (0.., args) |i, arg| {
        for (arg) |oct| {
            cpu.device_mem[dev.port_address(ports.typ)] = 0x2;
            cpu.device_mem[dev.port_address(ports.read)] = oct;

            try cpu.evaluate_vector(cpu.load_device_mem(u16, dev.port_address(ports.vector)));
        }

        cpu.device_mem[dev.port_address(ports.typ)] = if (i == args.len - 1) 0x4 else 0x3;
        cpu.device_mem[dev.port_address(ports.read)] = 0x10;

        try cpu.evaluate_vector(cpu.load_device_mem(u16, dev.port_address(ports.vector)));
    }
}

pub fn set_argc(
    dev: @This(),
    cpu: *Cpu,
    args: [][]const u8,
) void {
    cpu.device_mem[dev.port_address(ports.typ)] = @intFromBool(args.len > 0);
}

pub fn push_stdin_byte(
    dev: @This(),
    cpu: *Cpu,
    byte: u8,
) !void {
    const vector = cpu.load_device_mem(u16, dev.port_address(ports.vector));

    cpu.device_mem[dev.port_address(ports.typ)] = 0x1;
    cpu.device_mem[dev.port_address(ports.read)] = byte;

    if (vector > 0x0000)
        try cpu.evaluate_vector(vector);
}
