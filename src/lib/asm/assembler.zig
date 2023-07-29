const std = @import("std");

pub const Limits = struct {
    identifier_length: usize = 0x40,
    word_length: usize = 0x40,
    path_length: usize = 0x100,

    labels: usize = 0x400,
    references: usize = 0x200,
    macros: usize = 0x40,
    macro_length: usize = 0x40,
};

pub const AssemblerError = error{
    TooManyMacros,
    TooManyReferences,
    TooManyLabels,

    ReferenceOutOfBound,
    LabelAlreadyDefined,

    MissingScopeLabel,

    UndefinedLabel,
    UndefinedMacro,
    InvalidMacroDefinition,
    MacroBodyTooLong,

    NotImplemented,
};

pub fn Assembler(comptime lim: Limits) type {
    return struct {
        pub const limits = lim;

        pub const Labels = std.BoundedArray(DefinedLabel, limits.labels);
        pub const References = std.BoundedArray(Reference, limits.references);
        pub const MacroBody = std.BoundedArray(Scanner.SourceToken, limits.macro_length);
        pub const Macros = std.BoundedArray(Macro, limits.macros);

        pub const Scanner = @import("scanner.zig").Scanner(.{
            .identifier_length = limits.identifier_length,
            .word_length = limits.word_length,
            .path_length = limits.path_length,
        });

        pub const DefinedLabel = struct {
            label: Scanner.Label,
            addr: ?u16,
            references: References,
        };

        pub const ReferenceType = union(enum) {
            zero: void,
            relative: u16,
            absolute: void,
        };

        pub const Reference = struct {
            addr: u16,
            offset: u16,
            type: ReferenceType,
        };

        pub const Macro = struct {
            name: Scanner.Label,
            body: MacroBody,
        };

        rom_length: usize = 0,

        last_root_label: ?Scanner.Label = null,

        labels: Labels = Labels.init(0) catch unreachable,
        macros: Macros = Macros.init(0) catch unreachable,

        fn lookup_label(assembler: *@This(), label: []const u8) ?u16 {
            for (assembler.labels.slice()) |l|
                if (std.mem.eql(u8, label, std.mem.sliceTo(&l.label, 0)))
                    return l.addr;

            return null;
        }

        fn retrieve_label(assembler: *@This(), label: Scanner.TypedLabel) !*DefinedLabel {
            const full = try assembler.full_label(label);

            for (assembler.labels.slice()) |*l|
                if (std.mem.eql(u8, &l.label, &full))
                    return l;

            var definition = assembler.labels.addOne() catch return error.TooManyLabels;

            definition.* = .{
                .label = full,
                .addr = null,
                .references = References.init(0) catch unreachable,
            };

            return definition;
        }

        fn define_label(assembler: *@This(), label: Scanner.TypedLabel, addr: u16) !void {
            var definition = try assembler.retrieve_label(label);

            if (definition.addr != null)
                return error.LabelAlreadyDefined;

            definition.*.addr = addr;
        }

        fn full_label(assembler: *@This(), label: Scanner.TypedLabel) !Scanner.Label {
            switch (label) {
                .root => |l| return l,
                .scoped => |s| {
                    const parent = std.mem.sliceTo(&(assembler.last_root_label orelse return error.MissingScopeLabel), 0);
                    const child = std.mem.sliceTo(&s, 0);

                    var full: Scanner.Label = [1:0]u8{0x00} ** Scanner.limits.identifier_length;

                    @memcpy(full[0..parent.len], parent);
                    @memcpy(full[parent.len + 1 .. parent.len + 1 + child.len], child);

                    full[parent.len] = '/';

                    return full;
                },
            }
        }

        fn lookup_offset(assembler: *@This(), offset: Scanner.Offset) !?u16 {
            return switch (offset) {
                .literal => |lit| lit,
                .label => |lbl| assembler.lookup_label(std.mem.sliceTo(&(try assembler.full_label(lbl)), 0)),
            };
        }

        fn remember_location(
            assembler: *@This(),
            label: Scanner.TypedLabel,
            addr: u16,
            ref_type: ReferenceType,
            offset: u16,
        ) !void {
            var definition = try assembler.retrieve_label(label);

            definition.references.append(.{
                .addr = addr,
                .offset = offset,
                .type = ref_type,
            }) catch return error.TooManyReferences;
        }

        fn process_token(
            assembler: *@This(),
            scanner: *Scanner,
            token: Scanner.SourceToken,
            input: anytype,
            output: anytype,
            seekable: anytype,
        ) !void {
            switch (token.token) {
                .literal, .raw_literal => |lit| {
                    if (token.token != .raw_literal)
                        if (lit == .byte)
                            // LIT
                            try output.writeByte(0x80)
                        else
                            // LIT2
                            try output.writeByte(0xa0);

                    switch (lit) {
                        .byte => |b| try output.writeByte(b),
                        .short => |s| try output.writeIntBig(u16, s),
                    }
                },

                .label => |l| {
                    try assembler.define_label(l, @truncate(try seekable.getPos()));

                    if (l == .root) {
                        assembler.last_root_label = l.root;
                    }
                },
                .address => |addr| {
                    const current_pos: u16 = @truncate(try seekable.getPos());

                    switch (addr) {
                        .zero => |label| {
                            // LIT xx
                            try assembler.remember_location(label, current_pos + 1, .zero, 0);
                            try output.writeIntBig(u16, 0x80aa);
                        },
                        .relative => |label| {
                            // LIT xx (relative to current loc)
                            try assembler.remember_location(label, current_pos + 1, .{ .relative = current_pos + 1 }, 0);
                            try output.writeIntBig(u16, 0x80aa);
                        },
                        .absolute => |label| {
                            // LIT2 xxxx
                            try assembler.remember_location(label, current_pos + 1, .absolute, 0);
                            try output.writeIntBig(u24, 0xa0aaaa);
                        },

                        .raw_zero => |label| {
                            // xx
                            try assembler.remember_location(label, current_pos, .zero, 0);
                            try output.writeByte(0xaa);
                        },
                        .raw_relative => |label| {
                            // xx (relative to current loc)
                            try assembler.remember_location(label, current_pos, .{ .relative = current_pos }, 0);
                            try output.writeByte(0xaa);
                        },
                        .raw_absolute => |label| {
                            // xxxx
                            try assembler.remember_location(label, current_pos, .absolute, 0);
                            try output.writeIntBig(u16, 0xaaaa);
                        },
                    }
                },
                .padding => |pad| try switch (pad) {
                    .absolute => |offset| seekable.seekTo(try assembler.lookup_offset(offset) orelse return error.UndefinedLabel),
                    .relative => |offset| seekable.seekBy(try assembler.lookup_offset(offset) orelse return error.UndefinedLabel),
                },
                .include => |_| {
                    return error.NotImplemented;
                },
                .instruction => |op| {
                    try output.writeByte(op.encoded);
                },
                .jci, .jmi, .jsi => |label| {
                    const pos = try seekable.getPos();

                    try assembler.remember_location(label, @truncate(pos + 1), .absolute, @truncate(pos + 3));

                    try output.writeByte(switch (token.token) {
                        .jci => 0x20,
                        .jmi => 0x40,
                        else => 0x60,
                    });

                    try output.writeIntBig(u16, 0xaaaa);
                },
                .word => |w| {
                    for (w) |o|
                        if (o == 0)
                            break
                        else
                            try output.writeByte(o);
                },

                .macro_definition => |name| {
                    const start = try scanner.read_token(input) orelse
                        return error.InvalidMacroDefinition;

                    if (start.token != .macro_start)
                        return error.InvalidMacroDefinition;

                    var body = MacroBody.init(0) catch unreachable;

                    while (try scanner.read_token(input)) |tok| {
                        if (tok.token == .macro_end)
                            break;

                        body.append(tok) catch return error.MacroBodyTooLong;
                    }

                    assembler.macros.append(.{
                        .name = name,
                        .body = body,
                    }) catch return error.TooManyMacros;
                },
                .macro_expansion => |name| {
                    const macro = for (assembler.macros.slice()) |macro| {
                        if (std.mem.eql(u8, &macro.name, &name))
                            break macro;
                    } else return error.UndefinedMacro;

                    // XXX: A macro can include itself and murder our stack. Introduce a max evaluation depth.
                    for (macro.body.slice()) |macro_token|
                        try assembler.process_token(scanner, macro_token, input, output, seekable);
                },

                .macro_start, .macro_end => {
                    return error.InvalidMacroDefinition;
                },
            }
        }

        pub fn init() @This() {
            return .{};
        }

        fn AssembleError(
            comptime Reader: type,
            comptime Writer: type,
            comptime Seeker: type,
        ) type {
            return AssemblerError ||
                Reader.Error ||
                Writer.Error ||
                Seeker.GetSeekPosError ||
                Seeker.SeekError ||
                Scanner.Error;
        }

        pub fn assemble(
            assembler: *@This(),
            input: anytype,
            output: anytype,
            seekable: anytype,
        ) AssembleError(@TypeOf(input), @TypeOf(output), @TypeOf(seekable))!void {
            var scanner = Scanner{};

            while (try scanner.read_token(input)) |token| {
                try assembler.process_token(&scanner, token, input, output, seekable);
            }

            // N.B. the reference assembler only tracks writes for the rom length,
            //      while this one includes pads. A pad without writes at the end
            //      of the source will include 0x00 bytes in the output while the
            //      reference will implicitely fill in those 0x00 when loading the rom.
            assembler.rom_length = try seekable.getPos();

            for (assembler.labels.slice()) |label| {
                if (label.addr) |addr| {
                    if (label.references.len == 0) {
                        // TODO: issue diagnostic
                    } else {
                        for (label.references.slice()) |ref| {
                            try seekable.seekTo(ref.addr);

                            switch (ref.type) {
                                .zero => {
                                    try output.writeByte(@truncate(addr));
                                },

                                .absolute => {
                                    try output.writeIntBig(u16, addr -% ref.offset);
                                },

                                .relative => |to| {
                                    const target_addr: i16 = @as(i16, @bitCast(addr -% ref.offset));

                                    const signed_pc: i16 = @intCast(to);
                                    const relative = target_addr - signed_pc - 2;

                                    if (relative > 127 or relative < -128)
                                        return error.ReferenceOutOfBound;

                                    try output.writeIntBig(i8, @as(i8, @truncate(relative)));
                                },
                            }
                        }
                    }
                } else if (label.references.len > 0) {
                    // Undefined and unreachable should be impossible.
                    unreachable;
                }
            }
        }

        pub fn generate_symbols(
            assembler: *@This(),
            output: anytype,
        ) @TypeOf(output).Error!void {
            for (assembler.labels.slice()) |label| {
                if (label.addr) |addr| {
                    try output.writeIntBig(u16, addr);
                    try output.print("{s}\x00", .{std.mem.sliceTo(&label.label, 0)});
                }
            }
        }
    };
}
