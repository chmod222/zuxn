const Cpu = @import("uxn-core").Cpu;

const std = @import("std");
const logger = std.log.scoped(.uxn_varvara_console);

pub const ports = struct {
    pub const vector = 0x0;
    pub const read = 0x2;
    pub const typ = 0x7;
    pub const write = 0x8;
    pub const err = 0x9;
};

pub const Console = struct {
    addr: u4,

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

        const octet = dev.load_port(u8, cpu, port);

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
                dev.store_port(u8, cpu, ports.typ, 0x2);
                dev.store_port(u8, cpu, ports.read, oct);

                try cpu.evaluate_vector(dev.load_port(u16, cpu, ports.vector));
            }

            dev.store_port(u8, cpu, ports.typ, if (i == args.len - 1) 0x4 else 0x3);
            dev.store_port(u8, cpu, ports.read, 0x10);

            try cpu.evaluate_vector(dev.load_port(u16, cpu, ports.vector));
        }
    }

    pub fn set_argc(
        dev: @This(),
        cpu: *Cpu,
        args: [][]const u8,
    ) void {
        dev.store_port(u8, cpu, ports.typ, @intFromBool(args.len > 0));
    }

    pub fn push_stdin_byte(
        dev: @This(),
        cpu: *Cpu,
        byte: u8,
    ) !void {
        const vector = dev.load_port(u16, cpu, ports.vector);

        dev.store_port(u8, cpu, ports.typ, 0x1);
        dev.store_port(u8, cpu, ports.read, byte);

        if (vector > 0x0000)
            try cpu.evaluate_vector(vector);
    }
};
