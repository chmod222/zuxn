const Cpu = @This();

pub const Stack = @import("cpu/Stack.zig");

const std = @import("std");
const logger = std.log.scoped(.uxn_cpu);

pub const faults_enabled = @import("lib.zig").faults_enabled;
pub const page_size = 0x10000;
pub const device_page_size = 0x100;

const isa = @import("cpu/isa.zig");

pub const Opcode = isa.Opcode;

pub const SystemFault = error{
    StackOverflow,
    StackUnderflow,

    DivisionByZero,

    BadExpansion,
};

pub fn isCatchable(f: SystemFault) bool {
    return f != error.BadExpansion;
}

pub const InterceptKind = enum {
    input,
    output,
};

const StackSet = struct {
    primary: *Stack,
    secondary: *Stack,
};

pc: u16,

wst: Stack,
rst: Stack,

// Saved stack pointers
wst_sp: ?u8 = null,
rst_sp: ?u8 = null,

// Pointers to active stacks
primary_stack: *Stack = undefined,
secondary_stack: *Stack = undefined,

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
    var cpu = Cpu{
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

pub fn evaluateVector(cpu: *Cpu, vector: u16) SystemFault!void {
    cpu.pc = vector;

    logger.debug("Vector {x:0>4}: Start evaluation", .{vector});

    errdefer |err| {
        logger.debug("Vector {x:0>4}: Faulted with {}", .{ vector, err });
    }

    if (try cpu.run(null)) |_| {
        logger.debug("Ran to completion!", .{});
    }

    logger.debug("Vector {x:0>4}: Finished evaluation", .{vector});
}

inline fn load(
    cpu: *const Cpu,
    comptime T: type,
    comptime field: []const u8,
    addr: anytype,
    comptime boundary: usize,
) T {
    return if (T == u8)
        @field(cpu, field)[addr]
    else switch (@typeInfo(T)) {
        .@"struct" => |s| if (s.backing_integer) |U|
            @bitCast(cpu.load(U, field, addr, boundary))
        else
            @panic("Cannot read arbitrary struct types"),

        .int => if (@as(usize, addr) + @sizeOf(T) <= boundary)
            std.mem.readInt(T, @as(*const [@sizeOf(T)]u8, @ptrCast(@field(cpu, field)[addr..addr +| @sizeOf(T)])), .big)
        else r: {
            var b: T = undefined;

            for (0..@sizeOf(T)) |i| {
                b <<= 8;
                b |= cpu.load(u8, field, (addr +% i) % boundary, boundary);
            }

            break :r b;
        },

        else => @panic("Can only read bitfield structures and integers"),
    };
}

inline fn store(
    cpu: *Cpu,
    comptime T: type,
    comptime field: []const u8,
    addr: anytype,
    val: T,
    comptime boundary: usize,
) void {
    if (T == u8)
        @field(cpu, field)[addr] = val
    else switch (@typeInfo(T)) {
        .@"struct" => |s| if (s.backing_integer) |U|
            cpu.store(U, field, addr, val, boundary)
        else
            @panic("Cannot store arbitrary struct types"),

        .int => if (@as(usize, addr) + @sizeOf(T) <= boundary) {
            std.mem.writeInt(
                T,
                @as(*[@sizeOf(T)]u8, @ptrCast(@field(cpu, field)[addr..addr +| @sizeOf(T)])),
                val,
                .big,
            );
        } else {
            for (0.., std.mem.asBytes(&std.mem.nativeToBig(T, val))) |i, oct| {
                cpu.store(u8, field, (addr + i) % boundary, oct, boundary);
            }
        },

        else => @panic("Can only store bitfield structures and integers"),
    }
}

pub fn loadZero(cpu: *const Cpu, comptime T: type, addr: u8) T {
    return cpu.load(T, "mem", addr, 0x100);
}

pub fn loadMem(cpu: *const Cpu, comptime T: type, addr: u16) T {
    return cpu.load(T, "mem", addr, 0x10000);
}

pub fn loadDeviceMem(cpu: *const Cpu, comptime T: type, addr: u8) T {
    return cpu.load(T, "device_mem", addr, 0x100);
}

pub fn storeZero(cpu: *Cpu, comptime T: type, addr: u8, v: T) void {
    cpu.store(T, "mem", addr, v, 0x100);
}

pub fn storeMem(cpu: *Cpu, comptime T: type, addr: u16, v: T) void {
    cpu.store(T, "mem", addr, v, 0x10000);
}

pub fn storeDeviceMem(cpu: *Cpu, comptime T: type, addr: u8, v: T) void {
    cpu.store(T, "device_mem", addr, v, 0x100);
}

fn addRelative(addr: u16, offset: u8) u16 {
    return @bitCast(@as(i16, @bitCast(addr)) +% @as(i8, @bitCast(offset)));
}

/// Prepare the CPU for executing the given opcode. This includes saving the
/// stack pointers in case of `k`-opcodes, and swapping the stack pointers
/// for `r`-opcodes.
fn prepareExecute(cpu: *Cpu, comptime opcode: Opcode) void {
    if (opcode.returnMode()) {
        cpu.primary_stack = &cpu.rst;
        cpu.secondary_stack = &cpu.wst;
    } else {
        cpu.primary_stack = &cpu.wst;
        cpu.secondary_stack = &cpu.rst;
    }

    if (opcode.keepMode() and opcode.baseOpcode() != .BRK) {
        cpu.wst_sp = cpu.wst.sp;
        cpu.rst_sp = cpu.rst.sp;
    }
}

/// Finish the pre-execution path of the currently executing opcode. If the stacks
/// were frozen for `k`-opcodes, this resets them back to their saved locations.
fn finishPreExecute(cpu: *Cpu) void {
    if (cpu.wst_sp) |sp| {
        cpu.wst.sp = sp;
        cpu.wst_sp = null;
    }

    if (cpu.rst_sp) |sp| {
        cpu.rst.sp = sp;
        cpu.rst_sp = null;
    }
}

inline fn fetchJump(cpu: *Cpu, pc: u16) Opcode {
    defer cpu.pc = pc;

    return .fromByte(cpu.mem[cpu.pc]);
}

inline fn fetchNext(cpu: *Cpu) Opcode {
    switch (Opcode.fromByte(cpu.mem[cpu.pc])) {
        inline else => |opcode| cpu.prepareExecute(opcode),
    }

    return cpu.fetchJump(cpu.pc +% 1);
}

inline fn fetchImmedate(cpu: *Cpu, comptime T: type) T {
    defer cpu.pc +%= @sizeOf(T);

    return cpu.loadMem(T, cpu.pc);
}

/// Execute a memory -> stack push.
inline fn executeLiteralPush(cpu: *Cpu, comptime T: type) !void {
    try cpu.primary_stack.push(T, cpu.fetchImmedate(T));
}

/// Execute a jump based on a 16 bit relative immediate offset. Depending on
/// `push_ret` and `conditional`, this is either a straight jump, a subroutine
/// call or stack-conditional jump.
inline fn executeImmediateJump(
    cpu: *Cpu,
    comptime push_ret: bool,
    comptime conditional: bool,
) !void {
    const offset = cpu.fetchImmedate(u16);

    if (push_ret) {
        try cpu.rst.push(u16, cpu.pc);
    }

    _ = cpu.fetchJump(if (!conditional or try cpu.wst.pop(u8) > 0x00)
        cpu.pc +% offset
    else
        cpu.pc);
}

/// Execute a jump based on an 8 or 16 bit relative_raw offset on the stack. Depending on
/// `push_ret` and `conditional`, this is either a straight jump, a subroutine
/// call or stack-conditional jump.
inline fn executeStackJump(
    cpu: *Cpu,
    comptime T: type,
    comptime push_ret: bool,
    comptime conditional: bool,
) !void {
    const operand = try cpu.primary_stack.pop(T);

    const do_jump = if (conditional)
        try cpu.primary_stack.pop(u8) > 0x00
    else
        true;

    cpu.finishPreExecute();

    if (push_ret) {
        try cpu.secondary_stack.push(u16, cpu.pc);
    }

    _ = cpu.fetchJump(if (do_jump and T == u16)
        operand
    else if (do_jump and T == u8)
        addRelative(cpu.pc, operand)
    else
        cpu.pc);
}

/// Execute a "stack shuffle" operation that consists of popping `N` elements
/// and re-pushing them or some in the specified order.
inline fn executeStackShuffle(
    cpu: *Cpu,
    comptime T: type,
    comptime N: usize,
    out_order: anytype,
) !void {
    var popped: [N]T = undefined;

    inline for (&popped) |*p|
        p.* = try cpu.primary_stack.pop(T);

    cpu.finishPreExecute();

    inline for (out_order) |i|
        try cpu.primary_stack.push(T, popped[i]);
}

pub fn run(cpu: *Cpu, step_limit: ?usize) SystemFault!?u16 {
    @setEvalBranchQuota(2048);

    var step: usize = 0;

    return while (Opcode.fromByte(cpu.mem[cpu.pc]) != .BRK) {
        if (step_limit) |limit| {
            if (step >= limit) {
                return null;
            }

            step += 1;
        }

        const fetched = cpu.fetchNext();

        logger.debug("PC {x:0>4}: Start execute {s}", .{
            cpu.pc,
            @tagName(fetched),
        });

        errdefer |err| {
            logger.debug("PC {x:0>4}: {s}: Faulting with {}", .{
                cpu.pc,
                @tagName(fetched),
                err,
            });
        }

        switch (fetched) {
            .BRK => unreachable,

            inline .LIT, .LITr, .LIT2, .LIT2r => |opcode| {
                try cpu.executeLiteralPush(
                    opcode.nativeOperandType(),
                );
            },

            inline .JCI, .JMI, .JSI => |opcode| {
                try cpu.executeImmediateJump(
                    opcode == .JSI,
                    opcode == .JCI,
                );
            },

            // Stack Control Flow
            // zig fmt: off
            inline .JMP, .JMP2, .JMPr, .JMP2r, .JMPk, .JMP2k, .JMPkr, .JMP2kr,
                   .JCN, .JCN2, .JCNr, .JCN2r, .JCNk, .JCN2k, .JCNkr, .JCN2kr,
                   .JSR, .JSR2, .JSRr, .JSR2r, .JSRk, .JSR2k, .JSRkr, .JSR2kr => |opcode| {
                // zig fmt: on
                try cpu.executeStackJump(
                    opcode.nativeOperandType(),
                    opcode.baseOpcode() == .JSR,
                    opcode.baseOpcode() == .JCN,
                );
            },

            // zig fmt: off
            inline .POP, .POP2, .POPr, .POP2r, .POPk, .POP2k, .POPkr, .POP2kr,
                   .NIP, .NIP2, .NIPr, .NIP2r, .NIPk, .NIP2k, .NIPkr, .NIP2kr,
                   .SWP, .SWP2, .SWPr, .SWP2r, .SWPk, .SWP2k, .SWPkr, .SWP2kr,
                   .ROT, .ROT2, .ROTr, .ROT2r, .ROTk, .ROT2k, .ROTkr, .ROT2kr,
                   .DUP, .DUP2, .DUPr, .DUP2r, .DUPk, .DUP2k, .DUPkr, .DUP2kr,
                   .OVR, .OVR2, .OVRr, .OVR2r, .OVRk, .OVR2k, .OVRkr, .OVR2kr => |opcode| {
                // zig fmt: on
                const n = switch (opcode.baseOpcode()) {
                    .POP, .DUP => 1,
                    .NIP, .SWP, .OVR => 2,
                    .ROT => 3,
                    else => unreachable,
                };

                const order = switch (opcode.baseOpcode()) {
                    .POP => .{},
                    .NIP => .{0},
                    .SWP => .{ 0, 1 },
                    .ROT => .{ 1, 0, 2 },
                    .DUP => .{ 0, 0 },
                    .OVR => .{ 1, 0, 1 },
                    else => unreachable,
                };

                try cpu.executeStackShuffle(opcode.nativeOperandType(), n, order);
            },

            inline .STH, .STH2, .STHr, .STH2r, .STHk, .STH2k, .STHkr, .STH2kr => |opcode| {
                const val = try cpu.primary_stack.pop(opcode.nativeOperandType());

                cpu.finishPreExecute();

                try cpu.secondary_stack.push(opcode.nativeOperandType(), val);
            },

            // Comparisons
            // zig fmt: off
            inline .EQU, .EQU2, .EQUr, .EQU2r, .EQUk, .EQU2k, .EQUkr, .EQU2kr,
                   .NEQ, .NEQ2, .NEQr, .NEQ2r, .NEQk, .NEQ2k, .NEQkr, .NEQ2kr,
                   .GTH, .GTH2, .GTHr, .GTH2r, .GTHk, .GTH2k, .GTHkr, .GTH2kr,
                   .LTH, .LTH2, .LTHr, .LTH2r, .LTHk, .LTH2k, .LTHkr, .LTH2kr => |opcode| {
                // zig fmt: on
                const T = opcode.nativeOperandType();

                const b = try cpu.primary_stack.pop(T);
                const a = try cpu.primary_stack.pop(T);

                cpu.finishPreExecute();

                try cpu.primary_stack.push(u8, @intFromBool(switch (opcode.baseOpcode()) {
                    .EQU => a == b,
                    .NEQ => a != b,
                    .GTH => a > b,
                    .LTH => a < b,

                    else => unreachable,
                }));
            },

            // Bitwise and Numeric Arithmetic
            // zig fmt: off
            inline .ADD, .ADD2, .ADDr, .ADD2r, .ADDk, .ADD2k, .ADDkr, .ADD2kr,
                   .SUB, .SUB2, .SUBr, .SUB2r, .SUBk, .SUB2k, .SUBkr, .SUB2kr,
                   .MUL, .MUL2, .MULr, .MUL2r, .MULk, .MUL2k, .MULkr, .MUL2kr,
                   .DIV, .DIV2, .DIVr, .DIV2r, .DIVk, .DIV2k, .DIVkr, .DIV2kr,
                   .AND, .AND2, .ANDr, .AND2r, .ANDk, .AND2k, .ANDkr, .AND2kr,
                   .ORA, .ORA2, .ORAr, .ORA2r, .ORAk, .ORA2k, .ORAkr, .ORA2kr,
                   .EOR, .EOR2, .EORr, .EOR2r, .EORk, .EOR2k, .EORkr, .EOR2kr => |opcode| {
                // zig fmt: on
                const T = opcode.nativeOperandType();

                const b = try cpu.primary_stack.pop(T);
                const a = try cpu.primary_stack.pop(T);

                cpu.finishPreExecute();

                try cpu.primary_stack.push(T, switch (opcode.baseOpcode()) {
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

            inline .INC, .INC2, .INCr, .INC2r, .INCk, .INC2k, .INCkr, .INC2kr => |opcode| {
                const T = opcode.nativeOperandType();

                const val = try cpu.primary_stack.pop(T);

                cpu.finishPreExecute();

                try cpu.primary_stack.push(T, val +% 1);
            },

            inline .SFT, .SFT2, .SFTr, .SFT2r, .SFTk, .SFT2k, .SFTkr, .SFT2kr => |opcode| {
                const T = opcode.nativeOperandType();

                const shift = try cpu.primary_stack.pop(u8);
                const operand = try cpu.primary_stack.pop(T);

                cpu.finishPreExecute();

                const rshift: u4 = @truncate(shift & 0xf);
                const lshift: u4 = @truncate(shift >> 4);

                // If the operand would be shifted beyond its bit size, break :r 0
                try cpu.primary_stack.push(
                    T,
                    if (rshift < @bitSizeOf(T) and lshift < @bitSizeOf(T))
                        operand >> @truncate(rshift) << @truncate(lshift)
                    else
                        0,
                );
            },

            // Device and Memory Access
            // zig fmt: off
        inline .DEI, .DEI2, .DEIr, .DEI2r, .DEIk, .DEI2k, .DEIkr, .DEI2kr,
               .LDZ, .LDZ2, .LDZr, .LDZ2r, .LDZk, .LDZ2k, .LDZkr, .LDZ2kr,
               .LDR, .LDR2, .LDRr, .LDR2r, .LDRk, .LDR2k, .LDRkr, .LDR2kr,
               .LDA, .LDA2, .LDAr, .LDA2r, .LDAk, .LDA2k, .LDAkr, .LDA2kr,
               .DEO, .DEO2, .DEOr, .DEO2r, .DEOk, .DEO2k, .DEOkr, .DEO2kr,
               .STZ, .STZ2, .STZr, .STZ2r, .STZk, .STZ2k, .STZkr, .STZ2kr,
               .STR, .STR2, .STRr, .STR2r, .STRk, .STR2k, .STRkr, .STR2kr,
               .STA, .STA2, .STAr, .STA2r, .STAk, .STA2k, .STAkr, .STA2kr => |opcode| {
                // zig fmt: on
                const st = cpu.primary_stack;
                const T = opcode.nativeOperandType();

                const addr = switch (opcode.baseOpcode()) {
                    inline .LDA, .STA => try st.pop(u16),
                    inline .DEI, .DEO, .LDZ, .STZ => try st.pop(u8),
                    else => addRelative(cpu.pc, try st.pop(u8)),
                };

                switch (opcode.baseOpcode()) {
                    inline .DEI, .LDZ, .LDR, .LDA => |op| {
                        cpu.finishPreExecute();

                        if (op == .DEI) {
                            const dev: u8 = @truncate(addr);

                            const intercept_mask = cpu.input_intercepts[dev >> 4];
                            const intercept_port = intercept_mask >> @truncate(dev & 0xf);

                            if (intercept_port & 0x1 > 0)
                                if (cpu.device_intercept) |ifn|
                                    try ifn(cpu, dev, .input, cpu.callback_data);

                            if (opcode.shortMode() and (intercept_port >> 1) & 0x1 > 0)
                                if (cpu.device_intercept) |ifn|
                                    try ifn(cpu, dev + 1, .input, cpu.callback_data);
                        }

                        try st.push(T, switch (op) {
                            inline .DEI => cpu.loadDeviceMem(T, @truncate(addr)),
                            inline .LDZ => cpu.loadZero(T, @truncate(addr)),
                            inline .LDR, .LDA => cpu.loadMem(T, @truncate(addr)),

                            else => unreachable,
                        });
                    },

                    inline .DEO, .STZ, .STR, .STA => |op| {
                        const value = try st.pop(T);

                        cpu.finishPreExecute();

                        switch (op) {
                            inline .DEO => cpu.storeDeviceMem(T, addr, value),
                            inline .STZ => cpu.storeZero(T, addr, value),
                            inline .STR, .STA => cpu.storeMem(T, addr, value),

                            else => unreachable,
                        }

                        if (op == .DEO) {
                            const dev: u8 = @truncate(addr);

                            const intercept_mask = cpu.output_intercepts[dev >> 4];
                            const intercept_port = intercept_mask >> @truncate(dev & 0xf);

                            if (intercept_port & 0x1 > 0)
                                if (cpu.device_intercept) |ifn|
                                    try ifn(cpu, dev, .output, cpu.callback_data);

                            if (opcode.shortMode() and (intercept_port >> 1) & 0x1 > 0)
                                if (cpu.device_intercept) |ifn|
                                    try ifn(cpu, dev + 1, .output, cpu.callback_data);
                        }
                    },

                    else => unreachable,
                }
            },
        }
    } else cpu.pc;
}
