const std = @import("std");

pub const Opcode = enum {
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
    JCI,
    JMI,
    JSI,
    LIT,
};

const BRK = Instruction{ .opcode = .BRK };
const JCI = Instruction{ .opcode = .JCI };
const JMI = Instruction{ .opcode = .JMI };
const JSI = Instruction{ .opcode = .JSI };

const LIT = Instruction{ .opcode = .LIT };
const LIT2 = Instruction{ .opcode = .LIT, .short_mode = true };
const LITr = Instruction{ .opcode = .LIT, .return_mode = true };
const LIT2r = Instruction{ .opcode = .LIT, .short_mode = true, .return_mode = true };

pub const Instruction = struct {
    opcode: Opcode,

    short_mode: bool = false,
    return_mode: bool = false,
    keep_mode: bool = false,

    pub fn decode(raw: u8) Instruction {
        return switch (raw) {
            0x20 => JCI,
            0x40 => JMI,
            0x60 => JSI,
            0x80 => LIT,
            0xa0 => LIT2,
            0xc0 => LITr,
            0xe0 => LIT2r,

            else => Instruction{
                .opcode = @enumFromInt(raw & 0x1f),
                .short_mode = raw & 0x20 > 0,
                .return_mode = raw & 0x40 > 0,
                .keep_mode = raw & 0x80 > 0,
            },
        };
    }

    pub fn encode(i: Instruction) u8 {
        const flags =
            @as(u8, @intFromBool(i.short_mode)) << 5 |
            @as(u8, @intFromBool(i.return_mode)) << 6 |
            @as(u8, @intFromBool(i.keep_mode)) << 7;

        return switch (i.opcode) {
            .JCI => 0x20,
            .JMI => 0x40,
            .JSI => 0x60,
            .LIT => 0x80 | flags,
            else => @intFromEnum(i.opcode) | flags,
        };
    }

    pub fn mnemonic(i: Instruction) []const u8 {
        return mnemonics[i.encode()];
    }
};

fn mnemonic_suffix(i: Instruction) []const u8 {
    const flags =
        @as(u8, @intFromBool(i.short_mode)) << 5 |
        @as(u8, @intFromBool(i.return_mode)) << 6 |
        @as(u8, @intFromBool(i.keep_mode)) << 7;

    return switch (flags) {
        0b001_00000 => "2",
        0b010_00000 => "r",
        0b011_00000 => "2r",
        0b100_00000 => "k",
        0b101_00000 => "2k",
        0b110_00000 => "kr",
        0b111_00000 => "2kr",
        else => "",
    };
}

fn generate_mnemonics() [0x100][]const u8 {
    var mnemonics_r = [1][]const u8{""} ** 0x100;
    var raw_instruction: u8 = 0x00;

    while (true) : (raw_instruction += 1) {
        var instruction = Instruction.decode(raw_instruction);

        mnemonics_r[raw_instruction] = std.fmt.comptimePrint("{s}{s}", .{
            @tagName(instruction.opcode),
            mnemonic_suffix(instruction),
        });

        if (raw_instruction == 0xff)
            break;
    }

    return mnemonics_r;
}

pub const mnemonics = generate_mnemonics();
