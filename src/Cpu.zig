const Cpu = @This();

pub usingnamespace @import("cpu/isa.zig");

pub const SystemFault = error{
    StackOverflow,
    StackUnderflow,
    DivisionByZero,

    BadExpansion,
};

pub fn is_catchable(f: SystemFault) bool {
    return f != error.BadExpansion;
}

pub const InterceptKind = enum {
    input,
    output,
};

const Stack = @import("cpu/Stack.zig");

pc: u16,

wst: Stack,
rst: Stack,

mem: *[0x10000]u8,
device_mem: [0x100]u8,

input_intercepts: [0x10]u16 = [1]u16{0x0000} ** 0x10,
output_intercepts: [0x10]u16 = [1]u16{0x0000} ** 0x10,

device_intercept: ?*const fn (
    cpu: *Cpu,
    addr: u8,
    kind: InterceptKind,
) SystemFault!void = null,

pub fn init(mem: *[0x10000]u8) Cpu {
    return .{
        .pc = 0x0100,

        .wst = Stack.init(),
        .rst = Stack.init(),

        .mem = mem,
        .device_mem = [1]u8{0x00} ** 0x100,
    };
}

const std = @import("std");

pub fn evaluate_vector(cpu: *Cpu, vector: u16) SystemFault!void {
    cpu.pc = vector;

    while (try cpu.step()) |new_pc|
        cpu.pc = new_pc;
}

fn cast_array(comptime T: type, slice: []u8) *[@sizeOf(T)]u8 {
    return @ptrCast(slice);
}

pub fn load_mem(cpu: *Cpu, comptime T: type, addr: u16) T {
    return if (T == u8)
        cpu.mem[addr]
    else
        std.mem.readIntBig(T, cast_array(T, cpu.mem[addr..addr +| @sizeOf(T)]));
}

pub fn store_mem(cpu: *Cpu, comptime T: type, addr: u16, v: T) void {
    if (T == u8) {
        cpu.mem[addr] = v;
    } else {
        std.mem.writeIntBig(T, cast_array(T, cpu.mem[addr..addr +| @sizeOf(T)]), v);
    }
}

pub fn load_device_mem(cpu: *Cpu, comptime T: type, addr: u8) T {
    return if (T == u8)
        cpu.device_mem[addr]
    else
        std.mem.readIntBig(T, cast_array(T, cpu.device_mem[addr..addr +| @sizeOf(T)]));
}

pub fn store_device_mem(cpu: *Cpu, comptime T: type, addr: u8, v: T) void {
    if (T == u8) {
        cpu.device_mem[addr] = v;
    } else {
        std.mem.writeIntSliceBig(T, cast_array(T, cpu.device_mem[addr..addr +| @sizeOf(T)]), v);
    }
}

const PushFunc = fn (s: *Stack, v: u16) SystemFault!void;
const PopFunc = fn (s: *Stack) SystemFault!u16;

fn pusher(comptime T: type) PushFunc {
    return struct {
        fn push(s: *Stack, v: u16) SystemFault!void {
            return s.push(T, @as(T, @truncate(v)));
        }
    }.push;
}

fn popper(comptime T: type) PopFunc {
    return struct {
        fn pop(s: *Stack) SystemFault!u16 {
            return @as(T, try s.pop(T));
        }
    }.pop;
}

fn add_relative(addr: u16, offset: u8) u16 {
    return @bitCast(@as(i16, @bitCast(addr)) +% @as(i8, @bitCast(offset)));
}

pub fn step(cpu: *Cpu) SystemFault!?u16 {
    const instruction = Cpu.Instruction.decode(cpu.mem[cpu.pc]);

    var next_pc: u16 = cpu.pc + 1;

    var wst = &cpu.wst;
    var rst = &cpu.rst;

    if (instruction.return_mode) {
        std.mem.swap(*Stack, &wst, &rst);
    }

    var push: *const PushFunc = undefined;
    var pop: *const PopFunc = undefined;

    if (instruction.short_mode) {
        push = &pusher(u16);
        pop = &popper(u16);
    } else {
        push = &pusher(u8);
        pop = &popper(u8);
    }

    if (instruction.keep_mode) {
        wst.freeze_read();
        rst.freeze_read();
    }

    defer if (instruction.keep_mode) {
        wst.thaw_read();
        rst.thaw_read();
    };

    //std.debug.print("PC = {x:0>4} {s}\n", .{
    //    cpu.pc,
    //    Cpu.mnemonics[cpu.mem[cpu.pc]],
    //});

    switch (instruction.opcode) {
        .BRK => return null,

        // Immediate Control Flow
        .JMI => {
            next_pc +%= cpu.load_mem(u16, next_pc) + 2;
        },

        .JCI => {
            next_pc = if (try wst.pop(u8) > 0x00)
                next_pc +% cpu.load_mem(u16, next_pc) + 2
            else
                next_pc + 2;
        },

        .JSI => {
            try cpu.rst.push(u16, next_pc + 2);

            next_pc +%= cpu.load_mem(u16, next_pc) + 2;
        },

        .LIT => if (instruction.short_mode) {
            try wst.push(u16, cpu.load_mem(u16, next_pc));

            next_pc += 2;
        } else {
            try wst.push(u8, cpu.load_mem(u8, next_pc));

            next_pc += 1;
        },

        // Stack Control Flow
        .JMP => if (instruction.short_mode) {
            next_pc = try wst.pop(u16);
        } else {
            next_pc = add_relative(next_pc, try wst.pop(u8));
        },

        .JCN => {
            const addr = try pop(wst);
            const c = try wst.pop(u8);

            if (c > 0x00) {
                next_pc = if (instruction.short_mode)
                    addr
                else
                    add_relative(next_pc, @truncate(addr));
            }
        },

        .JSR => {
            try rst.push(u16, next_pc);

            const addr = try pop(wst);

            next_pc = if (instruction.short_mode)
                addr
            else
                add_relative(next_pc, @truncate(addr));
        },

        // Stack management
        .POP => {
            _ = try pop(wst);
        },

        .NIP => {
            const b = try pop(wst);
            _ = try pop(wst);

            try push(wst, b);
        },

        .SWP => {
            const b = try pop(wst);
            const a = try pop(wst);

            try push(wst, b);
            try push(wst, a);
        },

        .ROT => {
            const c = try pop(wst);
            const b = try pop(wst);
            const a = try pop(wst);

            try push(wst, b);
            try push(wst, c);
            try push(wst, a);
        },

        .DUP => {
            const a = try pop(wst);

            try push(wst, a);
            try push(wst, a);
        },

        .OVR => {
            const b = try pop(wst);
            const a = try pop(wst);

            try push(wst, a);
            try push(wst, b);
            try push(wst, a);
        },

        .STH => {
            try push(rst, try pop(wst));
        },

        // Device Access
        .DEI => {
            const dev = try wst.pop(u8);

            const intercept_mask = cpu.input_intercepts[dev >> 4];
            const intercept_port = intercept_mask >> @truncate(dev & 0xf);

            if (intercept_port & 0x1 > 0)
                if (cpu.device_intercept) |ifn|
                    try ifn(cpu, dev, .input);

            if (instruction.short_mode and (intercept_port >> 1) & 0x1 > 0)
                if (cpu.device_intercept) |ifn|
                    try ifn(cpu, dev + 1, .input);

            if (instruction.short_mode)
                try wst.push(u16, cpu.load_device_mem(u16, dev))
            else
                try wst.push(u8, cpu.load_device_mem(u8, dev));
        },

        .DEO => {
            const dev = try wst.pop(u8);

            const intercept_mask = cpu.output_intercepts[dev >> 4];
            const intercept_port = intercept_mask >> @truncate(dev & 0xf);

            if (instruction.short_mode)
                cpu.store_device_mem(u16, dev, try wst.pop(u16))
            else
                cpu.store_device_mem(u8, dev, try wst.pop(u8));

            if (intercept_port & 0x1 > 0)
                if (cpu.device_intercept) |ifn|
                    try ifn(cpu, dev, .output);

            if (instruction.short_mode and (intercept_port >> 1) & 0x1 > 0)
                if (cpu.device_intercept) |ifn|
                    try ifn(cpu, dev + 1, .output);
        },

        // Comparisons
        .EQU, .NEQ, .GTH, .LTH => |o| {
            const b = try pop(wst);
            const a = try pop(wst);

            try wst.push(u8, @intFromBool(switch (o) {
                .EQU => a == b,
                .NEQ => a != b,
                .GTH => a > b,
                .LTH => a < b,

                else => unreachable,
            }));
        },

        // Bitwise and Numeric Arithmetic
        .ADD, .SUB, .MUL, .DIV, .AND, .ORA, .EOR => |o| {
            const b = try pop(wst);
            const a = try pop(wst);

            try push(wst, switch (o) {
                .ADD => a +% b,
                .SUB => a -% b,
                .MUL => a *% b,
                .DIV => if (b != 0)
                    a / b
                else
                    return error.DivisionByZero,

                .AND => a & b,
                .ORA => a | b,
                .EOR => a ^ b,

                else => unreachable,
            });
        },

        .INC => {
            try push(wst, try pop(wst) +% 1);
        },

        .SFT => {
            const shift = try wst.pop(u8);
            const rshift: u4 = @truncate(shift & 0xf);
            const lshift: u4 = @truncate(shift >> 4);

            try push(wst, try pop(wst) >> rshift << lshift);
        },

        // Memory Access
        .LDZ, .LDR, .LDA, .STZ, .STR, .STA => |o| {
            const addr = switch (o) {
                .LDA, .STA => try wst.pop(u16),
                .LDZ, .STZ => try wst.pop(u8),

                else => add_relative(next_pc, try wst.pop(u8)),
            };

            switch (o) {
                .LDZ, .LDR, .LDA => {
                    if (instruction.short_mode)
                        try wst.push(u16, cpu.load_mem(u16, addr))
                    else
                        try wst.push(u8, cpu.load_mem(u8, addr));
                },

                .STZ, .STR, .STA => {
                    if (instruction.short_mode)
                        cpu.store_mem(u16, addr, try wst.pop(u16))
                    else
                        cpu.store_mem(u8, addr, try wst.pop(u8));
                },

                else => unreachable,
            }
        },
    }

    return next_pc;
}
