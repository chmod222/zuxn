const std = @import("std");

/// Describes an operands of an instruction.
pub const Operand = struct {
    /// Describes the size of an operand, in bytes, on the stack.
    pub const StackSize = enum {
        /// Size is 8 bits if the instruction is in byte mode, otherwise 16 bits.
        auto,

        /// Size is guaranteed to be 8 bits.
        byte,

        /// Size is guaranteed to be 16 bits.
        short,
    };

    /// The name of the operand.
    name: []const u8,

    /// The size of the operand.
    size: StackSize,

    /// Create a new named operand with the given stack size.
    fn sized(comptime name: []const u8, size: StackSize) Operand {
        return Operand{
            .name = name,
            .size = size,
        };
    }

    fn replaceAuto(operand: Operand, size: StackSize) Operand {
        return Operand{
            .name = operand.name,
            .size = if (operand.size == .auto) size else operand.size,
        };
    }
};

pub const Opcode = enum(u5) {
    /// `( -- a )` (LIT)
    /// `( cond8 -- )` (JCI)
    /// `( -- )` (BRK, JSI, JMI)
    BRK,

    /// `( a -- a+1 )
    INC,

    /// `( a -- )
    POP,

    /// `( a b -- b )
    NIP,

    /// `( a b -- b a )
    SWP,

    /// `( a b c -- b c a )
    ROT,

    /// `( a -- a a )
    DUP,

    /// `( a b -- a b a )
    OVR,

    /// `( a b -- bool8 )
    EQU,

    /// `( a b -- bool8 )
    NEQ,

    /// `( a b -- bool8 )
    GTH,

    /// `( a b -- bool8 )
    LTH,

    /// `( addr -- )
    JMP,

    /// `( cond8 addr -- )
    JCN,

    /// `( addr -- | ret16 )
    JSR,

    /// `( a -- | a )
    STH,

    /// `( addr8 -- v )`
    LDZ,

    /// `( v addr8 -- )`
    STZ,

    /// `( addr8 -- v )`
    LDR,

    /// `( v addr8 -- )`
    STR,

    /// `( addr16 -- v )`
    LDA,

    /// `( v addr16 -- )`
    STA,

    /// `( device8 -- v )`
    DEI,

    /// `( v device8 -- )`
    DEO,

    /// `( a b -- a+b )`
    ADD,

    /// `( a b -- a-b )`
    SUB,

    /// `( a b -- a*b )`
    MUL,

    /// `( a b -- a/b )`
    DIV,

    /// `( a b -- a&b )`
    AND,

    /// `( a b -- a|b )`
    ORA,

    /// `( a b -- a^b )`
    EOR,

    /// `( a shift8 -- c )`
    SFT,
};

fn readStackOperands(comptime notation: []const u8) []const Operand {
    var tokenizer = std.mem.tokenizeScalar(
        u8,
        notation,
        ' ',
    );

    var result: []const Operand = &.{};

    while (tokenizer.next()) |operand| {
        result = result ++ [1]Operand{Operand.sized(
            operand,
            if (std.mem.endsWith(u8, operand, "8"))
                .byte
            else if (std.mem.endsWith(u8, operand, "16"))
                .short
            else
                .auto,
        )};
    }

    return result;
}

fn readEffectNotationSide(
    comptime notation: []const u8,
) struct { []const Operand, []const Operand } {
    var stacks_iter = std.mem.splitScalar(
        u8,
        notation,
        '|',
    );

    const wst_notation = stacks_iter.next() orelse unreachable;

    if (stacks_iter.next()) |rst_notation| {
        return .{
            readStackOperands(wst_notation),
            readStackOperands(rst_notation),
        };
    } else {
        return .{ readStackOperands(wst_notation), &.{} };
    }
}

/// Holds information about the operands and result stack makeup for a specific
/// stack. (working or return stack)
pub const StackEffect = struct {
    /// The operands expected to reside on the given stack.
    before: []const Operand = &.{},

    /// The stack makeup after the effect has been applied. If the instruction
    /// was in keep-mode, this will not include the implicit before state that
    /// will remain on the stack.
    after: []const Operand = &.{},

    fn replaceAuto(comptime eff: StackEffect, size: Operand.StackSize) StackEffect {
        var new_before: []const Operand = &.{};
        var new_after: []const Operand = &.{};

        for (eff.before) |old_before| {
            new_before = new_before ++ [1]Operand{old_before.replaceAuto(size)};
        }

        for (eff.after) |old_after| {
            new_after = new_after ++ [1]Operand{old_after.replaceAuto(size)};
        }

        return StackEffect{
            .before = new_before,
            .after = new_after,
        };
    }
};

/// A structure describing the expected stack structures and effects of an
/// instruction. If the instruction is in keep-mode, the `before` states of
/// the stacks are implicitely prefixed to the `after` states and not duplicated
/// within them.
pub const StackEffects = struct {
    /// Effects applied to the working stack. (Adjusted for return-mode)
    working_stack: StackEffect = .{},

    /// Effects applied to the working stack. (Adjusted for return-mode)
    return_stack: StackEffect = .{},

    /// Parse the "standard" stack effect notation (e.g. `"a b | ra rb -- b | rb"`)
    /// into a structure of operands that can be visualized in a debugger.
    fn fromEffectNotation(comptime notation: []const u8) StackEffects {
        var iter = std.mem.splitSequence(
            u8,
            notation,
            "--",
        );

        const before = iter.next() orelse unreachable;
        const after = iter.next() orelse unreachable;

        const wst_in, const rst_in = readEffectNotationSide(before);
        const wst_out, const rst_out = readEffectNotationSide(after);

        return StackEffects{
            .working_stack = StackEffect{
                .before = wst_in,
                .after = wst_out,
            },
            .return_stack = StackEffect{
                .before = rst_in,
                .after = rst_out,
            },
        };
    }

    /// Returns a new structure where the input effects are prepended to the
    /// output effects, mirroring what the keep-mode does for instructions.
    fn keepInputs(eff: StackEffects) StackEffects {
        return StackEffects{
            .working_stack = StackEffect{
                .before = eff.working_stack.before,
                .after = eff.working_stack.before ++ eff.working_stack.after,
            },

            .return_stack = StackEffect{
                .before = eff.return_stack.before,
                .after = eff.return_stack.before ++ eff.return_stack.after,
            },
        };
    }

    /// Returns a new structure where the auto size operands are fixed size.
    fn replaceAuto(eff: StackEffects, size: Operand.StackSize) StackEffects {
        return StackEffects{
            .working_stack = eff.working_stack.replaceAuto(size),
            .return_stack = eff.return_stack.replaceAuto(size),
        };
    }
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

    pub fn stackEffects(i: Instruction) StackEffects {
        return effects[i.encode()];
    }
};

fn mnemonicSuffix(i: Instruction) []const u8 {
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

fn generateMnemonics() [0x100][]const u8 {
    var mnemonics_r = [1][]const u8{""} ** 0x100;
    var raw_instruction: u8 = 0x00;

    while (true) : (raw_instruction += 1) {
        const instruction = Instruction.decode(raw_instruction);

        mnemonics_r[raw_instruction] = if (instruction.opcode != .BRK)
            std.fmt.comptimePrint("{s}{s}", .{
                @tagName(instruction.opcode),
                mnemonicSuffix(instruction),
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

fn generateEffects() [0x100]StackEffects {
    // This is comparatively expensive, but only run during compilation of course.
    @setEvalBranchQuota(8192);

    var effects_r = [1]StackEffects{undefined} ** 0x100;

    // Skip BRK
    var raw_instruction: u8 = 0x00;

    while (raw_instruction < 0x20) : (raw_instruction += 1) {
        const instruction = Instruction.decode(raw_instruction);

        if (instruction.opcode == .BRK) {
            // The BRK instruction is overloaded with 3 entirely different effects
            // depending on its flags that completely change its meaning, so
            // it gets specialized here.

            // BRK
            effects_r[0x00] = StackEffects.fromEffectNotation("--");

            // JCI, JMI, JSI
            const jxi_eff = StackEffects.fromEffectNotation("addr8 --");

            effects_r[0x20] = jxi_eff;
            effects_r[0x40] = jxi_eff;
            effects_r[0x60] = jxi_eff;

            // LIT, LIT2, LITr, LIT2r
            const lit_eff = StackEffects.fromEffectNotation("-- a");

            effects_r[0x80] = lit_eff;
            effects_r[0xa0] = lit_eff;
            effects_r[0xc0] = lit_eff;
            effects_r[0xe0] = lit_eff;
        } else {
            // Determine the default stack effect of the instruction before
            // modifiers are applied.
            const default = switch (instruction.opcode) {
                .BRK => unreachable,

                .ADD => StackEffects.fromEffectNotation("a b -- a+b"),
                .SUB => StackEffects.fromEffectNotation("a b -- a-b"),
                .MUL => StackEffects.fromEffectNotation("a b -- a*b"),
                .DIV => StackEffects.fromEffectNotation("a b -- a/b"),
                .AND => StackEffects.fromEffectNotation("a b -- a&b"),
                .ORA => StackEffects.fromEffectNotation("a b -- a|b"),
                .EOR => StackEffects.fromEffectNotation("a b -- a^b"),
                .SFT => StackEffects.fromEffectNotation("a shift8 -- c"),

                .EQU, .NEQ, .LTH, .GTH => StackEffects.fromEffectNotation("a b -- bool8"),

                .DEO => StackEffects.fromEffectNotation("v device8 --"),
                .DEI => StackEffects.fromEffectNotation("device8 -- v"),

                .INC => StackEffects.fromEffectNotation("a -- a+1"),
                .SWP => StackEffects.fromEffectNotation("a b -- b a"),
                .ROT => StackEffects.fromEffectNotation("a b c -- b c a"),

                .STH => StackEffects.fromEffectNotation("a -- | a"),

                .LDZ, .LDR => StackEffects.fromEffectNotation("addr8 -- v"),
                .STZ, .STR => StackEffects.fromEffectNotation("v addr8 --"),

                .LDA => StackEffects.fromEffectNotation("addr16 -- v"),
                .STA => StackEffects.fromEffectNotation("v addr16 --"),

                .DUP => StackEffects.fromEffectNotation("a -- a a"),
                .OVR => StackEffects.fromEffectNotation("a b -- a b a"),
                .POP => StackEffects.fromEffectNotation("a --"),
                .NIP => StackEffects.fromEffectNotation("a b -- b"),

                .JMP => StackEffects.fromEffectNotation("addr -- "),
                .JCN => StackEffects.fromEffectNotation("cond8 addr -- "),
                .JSR => StackEffects.fromEffectNotation("addr -- | ret16"),
            };

            for (.{ 0x00, 0x20, 0x40, 0x60, 0x80, 0xa0, 0xc0, 0xe0 }) |flags|
                effects_r[flags | raw_instruction] = default;
        }
    }

    for (0.., &effects_r) |instr, *eff| {
        const instruction: Instruction = .decode(@truncate(instr));

        if (instruction.short_mode) {
            eff.* = eff.replacAuto(.short);
        } else {
            eff.* = eff.replaceAuto(.byte);
        }

        if (instruction.return_mode) {
            std.mem.swap(
                StackEffect,
                &eff.working_stack,
                &eff.return_stack,
            );
        }

        if (instruction.keep_mode) {
            eff.* = eff.keepInputs();
        }
    }

    return effects_r;
}

pub const mnemonics = generateMnemonics();
pub const effects = generateEffects();
