const std = @import("std");

pub const Opcode = enum(u5) {
    BRK,
    INC,
    POP,
    NIP,
    SWP,
    ROT,
    DUP,
    OVR,
    EQU,
    NEQ,
    GTH,
    LTH,
    JMP,
    JCN,
    JSR,
    STH,
    LDZ,
    STZ,
    LDR,
    STR,
    LDA,
    STA,
    DEI,
    DEO,
    ADD,
    SUB,
    MUL,
    DIV,
    AND,
    ORA,
    EOR,
    SFT,
};

pub const Instruction = packed struct(u8) {
    opcode: Opcode,

    short_mode: bool = false,
    return_mode: bool = false,
    keep_mode: bool = false,

    pub inline fn decode(raw: u8) Instruction {
        return @bitCast(raw);
    }

    pub inline fn encode(i: Instruction) u8 {
        return @bitCast(i);
    }

    pub fn mnemonic(i: Instruction) []const u8 {
        return mnemonics[i.encode()];
    }
};

fn mnemonic_suffix(i: Instruction) []const u8 {
    return switch (i.encode() & 0b11100000) {
        0x20 => "2",
        0x40 => "r",
        0x60 => "2r",
        0x80 => "k",
        0xa0 => "2k",
        0xc0 => "kr",
        0xe0 => "2kr",
        else => "",
    };
}

fn generate_mnemonics() [0x100][]const u8 {
    var mnemonics_r = [1][]const u8{""} ** 0x100;
    var raw_instruction: u8 = 0x00;

    while (true) : (raw_instruction += 1) {
        const instruction = Instruction.decode(raw_instruction);

        mnemonics_r[raw_instruction] = if (instruction.opcode != .BRK)
            std.fmt.comptimePrint("{s}{s}", .{
                @tagName(instruction.opcode),
                mnemonic_suffix(instruction),
            })
        else switch (raw_instruction) {
            0x00 => "BRK",
            0x20 => "JCI",
            0x40 => "JMI",
            0x60 => "JSI",
            0x80 => "LIT",
            0xc0 => "LITr",
            0xa0 => "LIT2",
            0xe0 => "LIT2r",
            else => unreachable,
        };

        if (raw_instruction == 0xff)
            break;
    }

    return mnemonics_r;
}

pub const mnemonics = generate_mnemonics();
