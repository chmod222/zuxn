const std = @import("std");
const mem = std.mem;

const scan = @import("scanner.zig");

const can_include = true;

const fs = std.fs;
const os = std.os;

pub const AssemblerError = error{
    OutOfMemory,

    TooManyMacros,
    TooManyReferences,
    TooManyLabels,
    TooManyNestedLambas,
    UnbalancedLambda,

    ReferenceOutOfBounds,
    LabelAlreadyDefined,

    MissingScopeLabel,

    UndefinedLabel,
    UndefinedMacro,
    InvalidMacroDefinition,
    MacroBodyTooLong,

    NotImplemented,

    IncludeNotFound,
    NotAllowed,
    CannotOpenFile,
};

pub fn Assembler(comptime lim: scan.Limits) type {
    return struct {
        pub const Scanner = scan.Scanner(lim);

        pub const Span = struct {
            line: usize,
            column: usize,
        };

        pub const LexicalInformation = struct {
            file: ?[]const u8,
            from: Span,
            to: Span,
        };

        pub const DefinedLabel = struct {
            definition: ?LexicalInformation = null,

            label: Scanner.Label,
            addr: ?u16,
            references: std.ArrayList(Reference),
        };

        pub const ReferenceType = union(enum) {
            zero: void,
            relative: u16,
            absolute: void,
        };

        pub const Reference = struct {
            definition: ?LexicalInformation = null,

            addr: u16,
            offset: u16,
            type: Scanner.AddressType,
        };

        pub const Macro = struct {
            name: Scanner.Label,
            body: std.ArrayList(Scanner.SourceToken),
        };

        allocator: mem.Allocator,

        rom_length: usize = 0,

        default_input_filename: ?[]const u8 = null,
        include_base: ?fs.Dir,
        include_follow: bool = true,
        include_stack: std.ArrayList([]const u8),

        last_root_label: ?Scanner.Label = null,

        err_input_pos: ?LexicalInformation = null,
        err_token: ?Scanner.SourceToken = null,

        labels: std.ArrayList(DefinedLabel),
        macros: std.ArrayList(Macro),
        lambdas: std.ArrayList(usize),
        lambda_counter: usize = 0,

        pub fn init(alloc: mem.Allocator, include_base: ?fs.Dir) @This() {
            return .{
                .allocator = alloc,
                .include_base = include_base,

                .labels = std.ArrayList(DefinedLabel).init(alloc),
                .macros = std.ArrayList(Macro).init(alloc),
                .lambdas = std.ArrayList(usize).init(alloc),
                .include_stack = std.ArrayList([]const u8).init(alloc),
            };
        }

        pub fn deinit(assembler: *@This()) void {
            for (assembler.include_stack.items) |inc| assembler.allocator.free(inc);
            for (assembler.macros.items) |macro| macro.body.deinit();
            for (assembler.labels.items) |label| {
                if (label.definition) |def|
                    if (def.file) |f|
                        assembler.allocator.free(f);

                for (label.references.items) |ref|
                    if (ref.definition) |def|
                        if (def.file) |f|
                            assembler.allocator.free(f);

                label.references.deinit();
            }

            assembler.include_stack.deinit();
            assembler.lambdas.deinit();
            assembler.macros.deinit();
            assembler.labels.deinit();

            if (assembler.err_input_pos) |err|
                if (err.file) |f|
                    assembler.allocator.free(f);
        }

        fn lexical_information_from_token(
            assembler: *@This(),
            token: Scanner.SourceToken,
        ) LexicalInformation {
            const file = if (assembler.include_stack.getLastOrNull()) |last|
                assembler.allocator.dupe(u8, last) catch null
            else
                null;

            return .{
                .file = file,
                .from = .{
                    .line = token.start[0],
                    .column = token.start[1],
                },
                .to = .{
                    .line = token.end[0],
                    .column = token.end[1],
                },
            };
        }

        fn lexical_information_from_scanner(
            assembler: *@This(),
            scanner: *const Scanner,
        ) LexicalInformation {
            const file = if (assembler.include_stack.getLastOrNull()) |last|
                assembler.allocator.dupe(u8, last) catch null
            else
                null;

            return .{
                .file = file,
                .from = .{
                    .line = scanner.location[0],
                    .column = scanner.location[1],
                },
                .to = .{
                    .line = scanner.location[0],
                    .column = scanner.location[1] + 1,
                },
            };
        }

        fn lookup_label(assembler: *@This(), label: Scanner.Label) ?*DefinedLabel {
            for (assembler.labels.items) |*l|
                if (mem.eql(u8, &label, &l.label))
                    return l;

            return null;
        }

        fn retrieve_label(assembler: *@This(), label: Scanner.TypedLabel) !*DefinedLabel {
            const full = try assembler.full_label(label);

            if (assembler.lookup_label(full)) |def| {
                return def;
            }

            const definition = assembler.labels.addOne() catch return error.TooManyLabels;

            definition.* = .{
                .definition = null,
                .label = full,
                .addr = null,
                .references = std.ArrayList(Reference).init(assembler.allocator),
            };

            return definition;
        }

        fn define_label(assembler: *@This(), label: Scanner.TypedLabel, addr: u16) !*DefinedLabel {
            const definition = try assembler.retrieve_label(label);

            if (definition.addr != null)
                return error.LabelAlreadyDefined;

            definition.*.addr = addr;

            return definition;
        }

        fn generate_lambda_label(id: usize) Scanner.TypedLabel {
            var lambda_label = [1:0]u8{0x00} ** Scanner.limits.identifier_length;
            var stream = std.io.fixedBufferStream(&lambda_label);

            stream.writer().print("lambda/{x:0>3}", .{id}) catch unreachable;

            return .{ .root = lambda_label };
        }

        fn full_label(assembler: *@This(), label: Scanner.TypedLabel) !Scanner.Label {
            switch (label) {
                .root => |l| {
                    // Special case "smart" lambda labels that get a unique identifier whenever encountered.
                    if (std.mem.eql(u8, "{", mem.sliceTo(&l, 0))) {
                        const ll = generate_lambda_label(assembler.lambda_counter).root;

                        assembler.lambdas.append(assembler.lambda_counter) catch
                            return error.TooManyNestedLambas;

                        assembler.lambda_counter += 1;

                        return ll;
                    } else {
                        return l;
                    }
                },

                .scoped => |s| {
                    const parent = mem.sliceTo(&(assembler.last_root_label orelse return error.MissingScopeLabel), 0);
                    const child = mem.sliceTo(&s, 0);

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
                .label => |lbl| if (assembler.lookup_label(try assembler.full_label(lbl))) |l| l.addr else null,
            };
        }

        fn remember_location(
            assembler: *@This(),
            reference: Scanner.Address,
            addr: u16,
            offset: u16,
        ) !*Reference {
            var definition = try assembler.retrieve_label(reference.label);

            const ref = definition.references.addOne() catch
                return error.TooManyReferences;

            ref.* = .{
                .addr = addr,
                .offset = offset,
                .type = reference.type,
            };

            return ref;
        }

        fn AssembleError(
            comptime Reader: type,
            comptime Writer: type,
            comptime Seeker: type,
        ) type {
            return AssemblerError ||
                Reader.Error ||
                fs.File.Reader.Error ||
                Writer.Error ||
                Seeker.GetSeekPosError ||
                Seeker.SeekError ||
                Scanner.Error;
        }

        fn process_token(
            assembler: *@This(),
            scanner: *Scanner,
            token: Scanner.SourceToken,
            input: anytype,
            output: anytype,
            seekable: anytype,
        ) AssembleError(@TypeOf(input), @TypeOf(output), @TypeOf(seekable))!void {
            assembler.err_token = null;

            errdefer {
                assembler.err_token = token;
            }

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
                        .short => |s| try output.writeInt(u16, s, .big),
                    }
                },

                .label => |l| {
                    var label_def = try assembler.define_label(l, @truncate(try seekable.getPos()));

                    label_def.definition = assembler.lexical_information_from_token(token);

                    if (l == .root) {
                        assembler.last_root_label = l.root;
                    }
                },
                .address => |addr| {
                    var ref = try assembler.remember_location(addr, @truncate(try seekable.getPos()), 0);

                    ref.definition = assembler.lexical_information_from_token(token);

                    try switch (addr.type) {
                        .zero => output.writeInt(u16, 0x80aa, .big),
                        .zero_raw => output.writeByte(0xaa),
                        .relative => output.writeInt(u16, 0x80aa, .big),
                        .relative_raw => output.writeByte(0xaa),
                        .absolute => output.writeInt(u24, 0xa0aaaa, .big),
                        .absolute_raw => output.writeInt(u16, 0xaaaa, .big),
                    };
                },
                .padding => |pad| try switch (pad) {
                    .absolute => |offset| seekable.seekTo(try assembler.lookup_offset(offset) orelse return error.UndefinedLabel),
                    .relative => |offset| seekable.seekBy(try assembler.lookup_offset(offset) orelse return error.UndefinedLabel),
                },
                .include => |path| if (can_include) {
                    try assembler.include_file(
                        output,
                        seekable,
                        mem.sliceTo(&path, 0),
                    );
                } else {
                    return error.NotImplemented;
                },
                .instruction => |op| {
                    try output.writeByte(op.encoded);
                },
                .jci, .jmi, .jsi => |label| {
                    const pos = try seekable.getPos();
                    const reference = Scanner.Address{
                        .type = .absolute,
                        .label = label,
                    };

                    var ref = try assembler.remember_location(reference, @truncate(pos), @truncate(pos + 3));

                    ref.definition = assembler.lexical_information_from_token(token);

                    try output.writeByte(switch (token.token) {
                        .jci => 0x20,
                        .jmi => 0x40,
                        else => 0x60,
                    });

                    try output.writeInt(u16, 0xaaaa, .big);
                },

                .word => |w| try output.writeAll(mem.sliceTo(&w, 0)),

                .macro_definition => |name| {
                    const start = try scanner.read_token(input) orelse
                        return error.InvalidMacroDefinition;

                    // %MACRO { } gets scanned as: <macro_definition> <jsi: '{'> so we expect that here.
                    if (start.token != .jsi and start.token.jsi != .root) {
                        return error.InvalidMacroDefinition;
                    }

                    // Special case it a bit so that "{}" and "{ }" both work as empty body definitions
                    const empty_body = if (mem.eql(u8, "{", mem.sliceTo(&start.token.jsi.root, 0)))
                        false
                    else if (mem.eql(u8, "{}", mem.sliceTo(&start.token.jsi.root, 0)))
                        true
                    else
                        return error.InvalidMacroDefinition;

                    var body = std.ArrayList(Scanner.SourceToken).init(assembler.allocator);

                    if (!empty_body) {
                        while (try scanner.read_token(input)) |tok| {
                            if (tok.token == .curly_close)
                                break;

                            body.append(tok) catch return error.MacroBodyTooLong;
                        }
                    }

                    assembler.macros.append(.{
                        .name = name,
                        .body = body,
                    }) catch return error.TooManyMacros;
                },
                .macro_expansion => |name| {
                    const macro = for (assembler.macros.items) |macro| {
                        if (mem.eql(u8, &macro.name, &name))
                            break macro;
                    } else return error.UndefinedMacro;

                    // XXX: A macro can include itself and murder our stack. Introduce a max evaluation depth.
                    for (macro.body.items) |macro_token|
                        try assembler.process_token(scanner, macro_token, input, output, seekable);
                },

                .curly_close => {
                    const lambda = assembler.lambdas.popOrNull() orelse return error.UnbalancedLambda;
                    const label = generate_lambda_label(lambda);

                    var label_def = try assembler.define_label(label, @truncate(try seekable.getPos()));

                    label_def.definition = assembler.lexical_information_from_token(token);
                },
            }
        }

        pub fn assemble(
            assembler: *@This(),
            input: anytype,
            output: anytype,
            seekable: anytype,
        ) AssembleError(@TypeOf(input), @TypeOf(output), @TypeOf(seekable))!void {
            var scanner = Scanner.init();

            errdefer {
                assembler.err_input_pos = assembler.lexical_information_from_scanner(&scanner);
            }

            while (try scanner.read_token(input)) |token| {
                try assembler.process_token(&scanner, token, input, output, seekable);
            }

            // N.B. the reference assembler only tracks writes for the rom length,
            //      while this one includes pads. A pad without writes at the end
            //      of the source will include 0x00 bytes in the output while the
            //      reference will implicitely fill in those 0x00 when loading the rom.
            assembler.rom_length = @truncate(try seekable.getPos());

            try assembler.resolve_references(output, seekable);
        }

        pub fn include_file(
            assembler: *@This(),
            output: anytype,
            seekable: anytype,
            path: []const u8,
        ) !void {
            const dir = assembler.include_base orelse
                return error.NotAllowed;

            var full_path_buffer: [fs.max_path_bytes]u8 = undefined;

            // Determine canonical path to included file
            const builtin = @import("builtin");

            const full_path = if (builtin.target.cpu.arch != .wasm32)
                dir.realpath(path, &full_path_buffer) catch return error.IncludeNotFound
            else
                path;

            // Open the include file
            const file = dir.openFile(full_path, .{}) catch
                return error.CannotOpenFile;

            defer file.close();

            // If we're following relative includes, update our include_base to point
            // to the parent folder of the included file and set it back to our old value
            // once finished with that file.
            if (assembler.include_follow) {
                const basename = fs.path.dirname(full_path) orelse
                    return error.IncludeNotFound;

                assembler.include_base = dir.openDir(basename, .{}) catch
                    return error.IncludeNotFound;
            }

            defer if (assembler.include_follow) {
                assembler.include_base.?.close();
                assembler.include_base = dir;
            };

            try assembler.include_stack.ensureUnusedCapacity(1);

            const included_path = try assembler.allocator.dupe(u8, full_path);

            assembler.include_stack.appendAssumeCapacity(included_path);

            // Do assemble
            const reader = file.reader();
            var scanner = Scanner.init();

            errdefer {
                assembler.err_input_pos = assembler.lexical_information_from_scanner(&scanner);
            }

            while (try scanner.read_token(reader)) |token| {
                try assembler.process_token(
                    &scanner,
                    token,
                    reader,
                    output,
                    seekable,
                );
            }

            // We don't defer this so our include stack remains valid and pointed
            // at the failing file if the loop fails
            assembler.allocator.free(assembler.include_stack.pop());
        }

        fn resolve_references(
            assembler: *@This(),
            output: anytype,
            seekable: anytype,
        ) !void {
            for (assembler.labels.items) |label| {
                if (label.addr) |addr| {
                    if (label.references.items.len == 0) {
                        // TODO: issue diagnostic for unused label
                    } else {
                        for (label.references.items) |ref| {
                            const ref_pos = switch (ref.type) {
                                // Literal references start after the LIT/LIT2/JSI/JMI/JCI opcode
                                .zero, .relative, .absolute => ref.addr + 1,

                                // Raw references start wherever they start.
                                .zero_raw, .relative_raw, .absolute_raw => ref.addr,
                            };

                            // Seek to the reference position and replace our placeholder 0xaa... with the
                            // resolved reference.
                            try seekable.seekTo(ref_pos);

                            switch (ref.type) {
                                .zero, .zero_raw => {
                                    try output.writeByte(@truncate(addr));
                                },

                                .absolute, .absolute_raw => {
                                    try output.writeInt(u16, addr -% ref.offset, .big);
                                },

                                .relative, .relative_raw => {
                                    const target_addr: i16 = @as(i16, @bitCast(addr -% ref.offset));

                                    const signed_pc: i16 = @intCast(ref_pos);
                                    const relative = target_addr - signed_pc - 2;

                                    if (relative > 127 or relative < -128)
                                        return error.ReferenceOutOfBounds;

                                    try output.writeInt(i8, @as(i8, @truncate(relative)), .big);
                                },
                            }
                        }
                    }
                } else if (label.references.items.len > 0) {
                    return error.UndefinedLabel;
                }
            }
        }

        pub fn generate_symbols(
            assembler: *@This(),
            output: anytype,
        ) @TypeOf(output).Error!void {
            // TODO: sort these
            for (assembler.labels.items) |label| {
                if (label.addr) |addr| {
                    try output.writeInt(u16, addr, .big);
                    try output.print("{s}\x00", .{mem.sliceTo(&label.label, 0)});
                }
            }
        }

        pub fn issue_diagnostic(assembler: *@This(), err: anyerror, output: anytype) !void {
            const default_input = assembler.default_input_filename orelse "<input>";

            const error_str = switch (err) {
                error.OutOfMemory => "Out of memory",
                error.TooManyMacros => "Macro limit exceeded",
                error.TooManyReferences => "Reference limit exceeded",
                error.TooManyLabels => "Label limit exceeded",
                error.TooManyNestedLambas => "Nested lambda depth exceeded",
                error.UnbalancedLambda => "Unbalanced lambda paranetheses",
                error.ReferenceOutOfBounds => "Relative reference distance too far from definition",
                error.LabelAlreadyDefined => "Label already defined",
                error.MissingScopeLabel => "Missing parent label",
                error.UndefinedLabel => "Undefined label found where definition is required",
                error.UndefinedMacro => "Undefined macro name",
                error.InvalidMacroDefinition => "Malformed macro definition",
                error.MacroBodyTooLong => "Macro body limit exceeded",
                error.NotImplemented => "Not implemented yet",
                error.IncludeNotFound => "Include file not found",
                error.NotAllowed => "Function disabled",
                error.CannotOpenFile => "Cannot open file",

                else => @errorName(err),
            };

            if (err == error.UndefinedLabel) {
                try output.print("{s}: undefined labels found:\n", .{
                    assembler.include_stack.getLastOrNull() orelse default_input,
                });

                for (assembler.labels.items) |label| {
                    if (label.addr == null and label.references.items.len > 0) {
                        const first_ref = label.references.items[0];

                        try output.print("{s}:   @{s} (first referenced: {s}:{}:{})\n", .{
                            assembler.include_stack.getLastOrNull() orelse default_input,
                            label.label,
                            first_ref.definition.?.file orelse default_input,
                            first_ref.definition.?.from.line,
                            first_ref.definition.?.from.column,
                        });
                    }
                }
            } else if (assembler.err_token) |token_err| {
                const location = token_err.start;

                if (token_err.token == .label and err == error.LabelAlreadyDefined) {
                    const first_ref = assembler.retrieve_label(token_err.token.label) catch {
                        try output.print("{s}:{}:{}: {s}\n", .{
                            assembler.include_stack.getLastOrNull() orelse default_input,
                            location[0],
                            location[1],
                            error_str,
                        });

                        return;
                    };

                    try output.print("{s}:{}:{}: {s} (first defined: {s}:{}:{})\n", .{
                        assembler.include_stack.getLastOrNull() orelse default_input,
                        location[0],
                        location[1],
                        error_str,
                        first_ref.definition.?.file orelse default_input,
                        first_ref.definition.?.from.line,
                        first_ref.definition.?.from.column,
                    });
                } else {
                    try output.print("{s}:{}:{}: {s}\n", .{
                        assembler.include_stack.getLastOrNull() orelse default_input,
                        location[0],
                        location[1],
                        error_str,
                    });
                }
            } else if (assembler.err_input_pos) |lexer_err_pos| {
                try output.print("{s}:{}:{}: {s}\n", .{
                    lexer_err_pos.file orelse default_input,
                    lexer_err_pos.from.line,
                    lexer_err_pos.from.column,
                    error_str,
                });
            } else {
                try output.print("{s}: {s}\n", .{
                    assembler.include_stack.getLastOrNull() orelse default_input,
                    error_str,
                });
            }
        }
    };
}
