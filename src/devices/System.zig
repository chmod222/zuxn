const Cpu = @import("../Cpu.zig");
const std = @import("std");

const Screen = @import("Screen.zig");

addr: u4,

exit_code: ?u8 = null,
screen: ?*Screen = null,

const ports = struct {
    const catch_vector = 0x00;
    const expansion = 0x02;
    const metadata = 0x06;
    const red = 0x08;
    const green = 0x0a;
    const blue = 0x0c;
    const debug = 0x0e;
    const state = 0x0f;
};

pub fn intercept(
    dev: *@This(),
    cpu: *Cpu,
    port: u4,
    kind: Cpu.InterceptKind,
) !void {
    if (kind != .output)
        return;

    const base = @as(u8, dev.addr) << 4;

    switch (port) {
        ports.state => {
            dev.exit_code = cpu.device_mem[base | ports.state] & 0x7f;
        },

        ports.debug => {
            std.debug.print("Debug!\n", .{});
        },

        ports.expansion + 1 => {
            try dev.handle_expansion(cpu, cpu.load_device_mem(u16, base | ports.expansion));
        },

        ports.red + 1, ports.green + 1, ports.blue + 1 => if (dev.screen) |s| {
            // Layout:
            //   R 0xABCD
            //   G 0xEFGH
            //   B 0xIJKL => 0xAEI 0xBFJ 0xCGK 0xDHL
            const r = cpu.load_device_mem(u16, base | ports.red);
            const g = cpu.load_device_mem(u16, base | ports.green);
            const b = cpu.load_device_mem(u16, base | ports.blue);

            s.update_scheme(r, g, b);
        },

        else => {},
    }
}

pub fn handle_fault(dev: @This(), cpu: *Cpu, fault: Cpu.SystemFault) !void {
    const base = @as(u8, dev.addr) << 4;
    const catch_vector = cpu.load_device_mem(u16, base | ports.catch_vector);

    if (catch_vector > 0x0000 and Cpu.is_catchable(fault)) {
        // Clear stacks, push fault information
        cpu.wst.sp = 0;
        cpu.rst.sp = 0;

        cpu.wst.push(u16, cpu.pc) catch unreachable;
        cpu.wst.push(u8, cpu.mem[cpu.pc]) catch unreachable;
        cpu.wst.push(u8, @as(u8, switch (fault) {
            error.StackUnderflow => 0x01,
            error.StackOverflow => 0x02,
            error.DivisionByZero => 0x03,

            else => unreachable,
        })) catch unreachable;

        cpu.evaluate_vector(catch_vector) catch |new_fault|
            try dev.handle_fault(cpu, new_fault);
    } else {
        std.debug.print("uncaught fault at pc={x:0>4} instr={x:0>2} ({s}): {}\n", .{
            cpu.pc,
            cpu.mem[cpu.pc],
            Cpu.mnemonics[cpu.mem[cpu.pc]],
            fault,
        });

        return fault;
    }
}

pub fn handle_expansion(dev: @This(), cpu: *Cpu, operation: u16) !void {
    _ = dev;

    switch (cpu.mem[operation]) {
        // copy
        0x01 => {
            // [ operation:u8 | len:u16 | srcpg:u16 | src:u16 | dstpg:u16 | dst:u16]
            // copy cpu.mem[srcpg * 0x10000 + src..][0..len]
            //   to cpu.mem[dstpg * 0x10000 + dst..][0..len]
            return error.BadExpansion;
        },

        else => {},
    }
}
