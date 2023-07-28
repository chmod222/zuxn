const std = @import("std");

const uxn = @import("uxn-core");
const varvara = @import("uxn-varvara");

const Cpu = uxn.Cpu;

fn dump_opcodes() void {
    var ins: u8 = 0x00;

    while (true) : (ins += 1) {
        const i = uxn.Cpu.Instruction.decode(ins);

        if (ins != 0 and ins & 0xf == 0)
            std.debug.print("\n", .{});

        var color = opcode_color(i);

        std.debug.print("{x:0>2}: \x1b[38;2;{d};{d};{d}m{s: <8}\x1b[0m", .{
            ins,
            color[0],
            color[1],
            color[2],
            i.mnemonic(),
        });

        if (ins == 0xff)
            break;
    }

    std.debug.print("\n", .{});
}

fn opcode_color(i: uxn.Cpu.Instruction) struct { u8, u8, u8 } {
    return switch (i.opcode) {
        .LIT => .{ 66, 135, 245 },
        .BRK => .{ 0xff, 0x00, 0x00 },
        .JCI, .JMI, .JSI => .{ 105, 66, 245 },
        .JMP, .JCN, .JSR => .{ 66, 245, 170 },
        .POP, .NIP, .SWP, .ROT, .DUP, .OVR, .STH => .{ 245, 111, 66 },
        .DEI, .DEO => .{ 245, 209, 66 },
        .LDZ, .LDR, .LDA => .{ 66, 245, 90 },
        .STZ, .STR, .STA => .{ 66, 203, 245 },
        .INC, .ADD, .SUB, .MUL, .DIV => .{ 245, 66, 90 },
        .EQU, .NEQ, .GTH, .LTH, .AND, .ORA, .EOR, .SFT => .{ 242, 17, 47 },
    };
}

pub fn main() void {
    dump_opcodes();
}
