const Cpu = @This();

pub const Stack = @import("cpu/Stack.zig");

const std = @import("std");
const mem = std.mem;

const logger = std.log.scoped(.uxn_cpu);

pub const faults_enabled = @import("lib.zig").faults_enabled;
pub const page_size = 0x10000;
pub const device_page_size = 0x100;

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

pc: u16,

wst: Stack,
rst: Stack,

mem: *[page_size]u8,
device_mem: [device_page_size]u8,

input_intercepts: [0x10]u16 = [1]u16{0x0000} ** 0x10,
output_intercepts: [0x10]u16 = [1]u16{0x0000} ** 0x10,

callback_data: ?*anyopaque = null,

device_intercept: ?*const fn (
    cpu: *Cpu,
    addr: u8,
    kind: InterceptKind,
    data: ?*anyopaque,
) SystemFault!void = null,

pub fn init(memory: *[page_size]u8) Cpu {
    var cpu = .{
        .pc = 0x0100,

        .wst = Stack.init(),
        .rst = Stack.init(),

        .mem = memory,
        .device_mem = [1]u8{0x00} ** 0x100,
    };

    if (faults_enabled) {
        cpu.wst.xflow_behaviour = .fault;
        cpu.rst.xflow_behaviour = .fault;
    }

    return cpu;
}

pub fn evaluate_vector(cpu: *Cpu, vector: u16) SystemFault!void {
    cpu.pc = vector;

    logger.debug("Vector {x:0>4}: Start evaluation", .{vector});

    errdefer |err| {
        logger.debug("Vector {x:0>4}: Faulted with {}", .{ vector, err });
    }

    while (try cpu.step()) |new_pc|
        cpu.pc = new_pc;

    logger.debug("Vector {x:0>4}: Finished evaluation", .{vector});
}

inline fn load(
    cpu: *const Cpu,
    comptime T: type,
    comptime field: []const u8,
    addr: anytype,
) T {
    return if (T == u8)
        @field(cpu, field)[addr]
    else switch (@typeInfo(T)) {
        .Struct => |s| if (s.backing_integer) |U|
            @bitCast(cpu.load(U, field, addr))
        else
            @panic("Cannot read arbitrary struct types"),

        .Int => mem.readInt(T, @as(*const [@sizeOf(T)]u8, @ptrCast(@field(cpu, field)[addr..addr +| @sizeOf(T)])), .big),

        else => @panic("Can only read bitfield structures and integers"),
    };
}

inline fn store(
    cpu: *Cpu,
    comptime T: type,
    comptime field: []const u8,
    addr: anytype,
    val: T,
) void {
    if (T == u8)
        @field(cpu, field)[addr] = val
    else switch (@typeInfo(T)) {
        .Struct => |s| if (s.backing_integer) |U|
            cpu.store(U, field, addr, val)
        else
            @panic("Cannot store arbitrary struct types"),

        .Int => mem.writeInt(T, @as(*[@sizeOf(T)]u8, @ptrCast(@field(cpu, field)[addr..addr +| @sizeOf(T)])), val, .big),

        else => @panic("Can only store bitfield structures and integers"),
    }
}

pub fn load_mem(cpu: *const Cpu, comptime T: type, addr: u16) T {
    return cpu.load(T, "mem", addr);
}

pub fn load_device_mem(cpu: *const Cpu, comptime T: type, addr: u8) T {
    return cpu.load(T, "device_mem", addr);
}

pub fn store_mem(cpu: *Cpu, comptime T: type, addr: u16, v: T) void {
    cpu.store(T, "mem", addr, v);
}

pub fn store_device_mem(cpu: *Cpu, comptime T: type, addr: u8, v: T) void {
    cpu.store(T, "device_mem", addr, v);
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
        mem.swap(*Stack, &wst, &rst);
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

    logger.debug("PC {x:0>4}: Start execute {s}", .{ cpu.pc, Cpu.mnemonics[cpu.mem[cpu.pc]] });

    errdefer |err| {
        logger.debug("PC {x:0>4}: {s}: Faulting with {}", .{ cpu.pc, Cpu.mnemonics[cpu.mem[cpu.pc]], err });
    }

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
                    try ifn(cpu, dev, .input, cpu.callback_data);

            if (instruction.short_mode and (intercept_port >> 1) & 0x1 > 0)
                if (cpu.device_intercept) |ifn|
                    try ifn(cpu, dev + 1, .input, cpu.callback_data);

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
                    try ifn(cpu, dev, .output, cpu.callback_data);

            if (instruction.short_mode and (intercept_port >> 1) & 0x1 > 0)
                if (cpu.device_intercept) |ifn|
                    try ifn(cpu, dev + 1, .output, cpu.callback_data);
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
                else if (!faults_enabled)
                    0
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
