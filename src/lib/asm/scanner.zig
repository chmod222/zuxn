const uxn = @import("uxn-core");

const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const ascii = std.ascii;

pub const Limits = struct {
    identifier_length: usize = 64,
    word_length: usize = 64,
    path_length: usize = 256,
};

fn parse_hex_digit(octet: u8) !u4 {
    if (!ascii.isHex(octet) or (!ascii.isDigit(octet) and !ascii.isLower(octet)))
        return error.InvalidHexLiteral;

    return @truncate(fmt.charToDigit(octet, 16) catch unreachable);
}

fn parse_hex_literal(comptime T: type, raw: []const u8, fixed_width: bool) !T {
    if (fixed_width) {
        const w = if (T == u8) 2 else if (T == u16) 4 else unreachable;

        if (raw.len != w)
            return error.InvalidHexLiteral;
    }

    for (raw) |oct|
        if (!ascii.isHex(oct) or (!ascii.isDigit(oct) and !ascii.isLower(oct)))
            return error.InvalidHexLiteral;

    return fmt.parseInt(T, raw, 16) catch unreachable;
}

pub fn Scanner(comptime lim: Limits) type {
    return struct {
        pub const limits = lim;

        pub const Literal = union(enum) {
            byte: u8,
            short: u16,
        };

        pub const TypedLabel = union(enum) {
            root: Label,
            scoped: Label,
        };

        pub const Address = union(enum) {
            zero: TypedLabel,
            relative: TypedLabel,
            absolute: TypedLabel,

            raw_zero: TypedLabel,
            raw_relative: TypedLabel,
            raw_absolute: TypedLabel,
        };

        pub const Instruction = struct {
            mnemonic: []const u8,
            encoded: u8,
        };

        pub const Offset = union(enum) {
            literal: u16,
            label: TypedLabel,
        };

        pub const Padding = union(enum) {
            relative: Offset,
            absolute: Offset,
        };

        pub const Location = struct { usize, usize };

        pub const Label = [limits.identifier_length:0]u8;

        line: usize = 1,
        column: usize = 1,

        macro_names: std.BoundedArray(Label, 0x100) =
            std.BoundedArray(Label, 0x100).init(0) catch unreachable,

        pub const Token = union(enum) {
            macro_definition: Label,
            curly_open: void,
            curly_close: void,
            macro_expansion: Label,

            literal: Literal,
            raw_literal: Literal,
            label: TypedLabel,
            address: Address,
            padding: Padding,
            instruction: Instruction,
            jci: TypedLabel,
            jmi: TypedLabel,
            jsi: TypedLabel,
            word: [limits.word_length:0]u8,
            include: [limits.path_length:0]u8,
        };

        pub const SourceToken = struct {
            start: Location,
            end: Location,

            token: Token,
        };

        pub const Error = error{
            PrematureEof,
            InvalidToken,
            InvalidHexLiteral,
            TokenTooLong,
            PathTooLong,
            UppercaseLabelForbidden,
        };

        pub fn init() @This() {
            return .{};
        }

        fn read_byte(scanner: *@This(), input: anytype) ?u8 {
            const b = input.readByte() catch return null;

            if (b == '\n') {
                scanner.line += 1;
                scanner.column = 1;
            } else {
                scanner.column += 1;
            }

            return b;
        }

        fn read_hex_digit(scanner: *@This(), input: anytype) Error!?u4 {
            return try parse_hex_digit(scanner.read_byte(input) orelse return null);
        }

        fn read_literal(scanner: *@This(), input: anytype) Error!Literal {
            const h0n: u8 = try scanner.read_hex_digit(input) orelse return error.PrematureEof;
            const l0n: u8 = try scanner.read_hex_digit(input) orelse return error.PrematureEof;

            // Catch EOF as whitespace so we exit cleanly in case "#xy" is the very last thing in the input
            const next = scanner.read_byte(input) orelse ' ';

            const h1n: u8 = if (ascii.isWhitespace(next))
                return .{ .byte = @as(u8, h0n << 4) | l0n }
            else
                try parse_hex_digit(next);

            const l1n = try scanner.read_hex_digit(input) orelse return error.PrematureEof;

            return .{
                .short = @as(u16, h0n) << 12 |
                    @as(u16, l0n) << 8 |
                    @as(u16, h1n) << 4 |
                    @as(u16, l1n) << 0,
            };
        }

        fn read_whitespace_delimited(
            scanner: *@This(),
            comptime maxlen: usize,
            input: anytype,
        ) Error![maxlen:0]u8 {
            var output = [1:0]u8{0x00} ** maxlen;
            var fbs = std.io.fixedBufferStream(&output);
            var writer = fbs.writer();

            while (true) {
                var oct = scanner.read_byte(input) orelse ' ';

                if (ascii.isWhitespace(oct))
                    break;

                writer.writeByte(oct) catch {
                    return error.TokenTooLong;
                };
            }

            return output;
        }

        fn read_label(scanner: *@This(), input: anytype) Error!Label {
            const label = try scanner.read_whitespace_delimited(limits.identifier_length, input);

            for (label) |oct| {
                if (ascii.isLower(oct) or !ascii.isAlphanumeric(oct))
                    break;
            } else return error.UppercaseLabelForbidden;

            return label;
        }

        fn read_path(scanner: *@This(), input: anytype) Error![256:0]u8 {
            return scanner.read_whitespace_delimited(256, input) catch {
                return error.PathTooLong;
            };
        }

        pub fn location(scanner: *@This()) Location {
            return .{ scanner.line, scanner.column };
        }

        fn to_typed_label(label: Label) TypedLabel {
            if (label[0] == '&') {
                var cpy = label;

                mem.copyForwards(u8, &cpy, cpy[1..]);

                return .{ .scoped = cpy };
            } else {
                return .{ .root = label };
            }
        }

        fn register_macro(scanner: *@This(), ident: Label) void {
            // TODO
            scanner.macro_names.append(ident) catch unreachable;
        }

        fn recall_macro(scanner: *@This(), ident: Label) bool {
            for (scanner.macro_names.slice()) |n| {
                if (mem.eql(u8, &n, &ident))
                    return true;
            }

            return false;
        }

        pub fn read_token(scanner: *@This(), input: anytype) Error!?SourceToken {
            var comment_depth: usize = 0;

            while (scanner.read_byte(input)) |b| {
                if (comment_depth > 0 and (b != ')') and (b != '('))
                    continue;

                var start = scanner.location();
                start[1] -= 1;

                var end: Location = undefined;

                const token: Token = switch (b) {
                    '(' => {
                        comment_depth += 1;

                        continue;
                    },
                    ')' => {
                        comment_depth -= 1;

                        continue;
                    },

                    '[', ']', ' ', '\t', '\n', '\r' => continue,

                    '@', '&' => b: {
                        // Labels
                        const label = try scanner.read_label(input);

                        end = Location{ start[0], start[1] + 1 + mem.sliceTo(&label, 0).len };

                        break :b if (b == '@')
                            .{ .label = .{ .root = label } }
                        else
                            .{ .label = .{ .scoped = label } };
                    },

                    ',', '.', ';', '_', '-', '=', ':' => b: {
                        // Adressing
                        const label = try scanner.read_label(input);
                        const typed = to_typed_label(label);

                        end = Location{ start[0], start[1] + 1 + mem.sliceTo(&label, 0).len };

                        break :b switch (b) {
                            '.' => .{ .address = .{ .zero = typed } },
                            ',' => .{ .address = .{ .relative = typed } },
                            ';' => .{ .address = .{ .absolute = typed } },
                            '-' => .{ .address = .{ .raw_zero = typed } },
                            '_' => .{ .address = .{ .raw_relative = typed } },
                            '=', ':' => .{ .address = .{ .raw_absolute = typed } },
                            else => unreachable,
                        };
                    },
                    '#' => b: {
                        // Literal hex
                        const literal = try scanner.read_literal(input);
                        const litlen: usize = switch (literal) {
                            .byte => 2,
                            .short => 4,
                        };

                        end = Location{ start[0], start[1] + 1 + litlen };

                        break :b .{ .literal = literal };
                    },

                    '|', '$' => b: {
                        // Padding (TODO)
                        var pad = try scanner.read_whitespace_delimited(limits.identifier_length, input);

                        end = Location{ start[0], start[1] + 1 + mem.sliceTo(&pad, 0).len };

                        const offset: Offset = if (parse_hex_literal(u16, mem.sliceTo(&pad, 0), false) catch null) |lit|
                            .{ .literal = lit }
                        else
                            .{ .label = to_typed_label(pad) };

                        break :b if (b == '|')
                            .{ .padding = .{ .absolute = offset } }
                        else
                            .{ .padding = .{ .relative = offset } };
                    },

                    '?' => b: {
                        const label = try scanner.read_label(input);

                        end = Location{ start[0], start[1] + 1 + mem.sliceTo(&label, 0).len };

                        break :b .{ .jci = to_typed_label(label) };
                    },

                    '!' => b: {
                        const label = try scanner.read_label(input);

                        end = Location{ start[0], start[1] + 1 + mem.sliceTo(&label, 0).len };

                        break :b .{ .jmi = to_typed_label(label) };
                    },

                    '~' => b: {
                        const path = try scanner.read_path(input);

                        end = Location{ start[0], start[1] + 1 + mem.sliceTo(&path, 0).len };

                        break :b .{ .include = path };
                    },

                    '%' => b: {
                        const ident = try scanner.read_whitespace_delimited(limits.identifier_length, input);

                        scanner.register_macro(ident);

                        end = Location{ start[0], start[1] + 1 + mem.sliceTo(&ident, 0).len };

                        break :b .{ .macro_definition = ident };
                    },

                    '{', '}' => b: {
                        end = Location{ start[0], start[1] + 1 };

                        break :b if (b == '{')
                            .curly_open
                        else
                            .curly_close;
                    },

                    '"' => b: {
                        var word = [1:0]u8{0x00} ** 64;
                        var i: usize = 0;

                        while (scanner.read_byte(input)) |oct| : (i += 1) {
                            if (ascii.isWhitespace(oct))
                                break;

                            word[i] = oct;
                        }

                        end = Location{ start[0], start[1] + 1 + mem.sliceTo(&word, 0).len };

                        break :b .{ .word = word };
                    },

                    else => b: {
                        var needle = [1:0]u8{b} ++ [1:0]u8{0x00} ** (limits.identifier_length - 1);
                        var remain = try scanner.read_whitespace_delimited(limits.identifier_length, input);

                        end = Location{ start[0], start[1] + 1 + mem.sliceTo(&remain, 0).len };

                        for (1.., mem.sliceTo(&remain, 0)) |j, oct|
                            needle[j] = oct;

                        for (0.., uxn.Cpu.mnemonics) |instr, m| {
                            if (mem.eql(u8, mem.sliceTo(m, 0), mem.sliceTo(&needle, 0)))
                                break :b .{
                                    .instruction = .{
                                        .mnemonic = m,
                                        .encoded = @as(u8, @truncate(instr)),
                                    },
                                };
                        } else {
                            const slice = mem.sliceTo(&needle, 0);

                            break :b if (parse_hex_literal(u8, slice, true) catch null) |byte|
                                .{ .raw_literal = .{ .byte = byte } }
                            else if (parse_hex_literal(u16, slice, true) catch null) |short|
                                .{ .raw_literal = .{ .short = short } }
                            else if (scanner.recall_macro(needle))
                                .{ .macro_expansion = needle }
                            else
                                .{ .jsi = to_typed_label(needle) };
                        }
                    },
                };

                return .{
                    .start = start,
                    .end = end,
                    .token = token,
                };
            }

            return null;
        }
    };
}
