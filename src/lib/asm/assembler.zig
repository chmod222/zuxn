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

        pub const DefinedLabel = struct {
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

        include_base: ?fs.Dir,
        include_follow: bool = true,
        include_stack: std.ArrayList([]const u8),

        last_root_label: ?Scanner.Label = null,
        current_token: ?Scanner.SourceToken = null,

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
            for (assembler.labels.items) |label| label.references.deinit();

            assembler.include_stack.deinit();
            assembler.lambdas.deinit();
            assembler.macros.deinit();
            assembler.labels.deinit();
        }

        fn lookup_label(assembler: *@This(), label: []const u8) ?u16 {
            for (assembler.labels.items) |l|
                if (mem.eql(u8, label, mem.sliceTo(&l.label, 0)))
                    return l.addr;

            return null;
        }

        fn retrieve_label(assembler: *@This(), label: Scanner.TypedLabel) !*DefinedLabel {
            const full = try assembler.full_label(label);

            for (assembler.labels.items) |*l|
                if (mem.eql(u8, &l.label, &full))
                    return l;

            var definition = assembler.labels.addOne() catch return error.TooManyLabels;

            definition.* = .{
                .label = full,
                .addr = null,
                .references = std.ArrayList(Reference).init(assembler.allocator),
            };

            return definition;
        }

        fn generate_lambda_label(id: usize) Scanner.TypedLabel {
            var lambda_label = [1:0]u8{0x00} ** Scanner.limits.identifier_length;
            var stream = std.io.fixedBufferStream(&lambda_label);

            stream.writer().print("lambda-{x}", .{id}) catch unreachable;

            return .{ .root = lambda_label };
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
                .label => |lbl| assembler.lookup_label(mem.sliceTo(&(try assembler.full_label(lbl)), 0)),
            };
        }

        fn remember_location(
            assembler: *@This(),
            reference: Scanner.Address,
            addr: u16,
            offset: u16,
        ) !void {
            var definition = try assembler.retrieve_label(reference.label);

            definition.references.append(.{
                .addr = addr,
                .offset = offset,
                .type = reference.type,
            }) catch return error.TooManyReferences;
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

                    try assembler.remember_location(addr, current_pos, 0);

                    switch (addr.type) {
                        .zero => try output.writeIntBig(u16, 0x80aa),
                        .zero_raw => try output.writeByte(0xaa),
                        .relative => try output.writeIntBig(u16, 0x80aa),
                        .relative_raw => try output.writeByte(0xaa),
                        .absolute => try output.writeIntBig(u24, 0xa0aaaa),
                        .absolute_raw => try output.writeIntBig(u16, 0xaaaa),
                    }
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
                    const ref = .{
                        .type = .absolute,
                        .label = label,
                    };

                    try assembler.remember_location(ref, @truncate(pos), @truncate(pos + 3));
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

                    if (start.token != .curly_open)
                        return error.InvalidMacroDefinition;

                    var body = std.ArrayList(Scanner.SourceToken).init(assembler.allocator);

                    while (try scanner.read_token(input)) |tok| {
                        if (tok.token == .curly_close)
                            break;

                        body.append(tok) catch return error.MacroBodyTooLong;
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

                .curly_open => {
                    const label = generate_lambda_label(assembler.lambda_counter);
                    const pos = try seekable.getPos();

                    assembler.lambdas.append(assembler.lambda_counter) catch
                        return error.TooManyNestedLambas;

                    assembler.lambda_counter += 1;

                    // Write JSI to location to be defined below
                    const ref = .{
                        .type = .absolute,
                        .label = label,
                    };

                    try assembler.remember_location(ref, @truncate(pos), @truncate(pos + 3));
                    try output.writeIntBig(u24, 0x60aaaa);
                },

                .curly_close => {
                    const lambda = assembler.lambdas.popOrNull() orelse return error.UnbalancedLambda;
                    const label = generate_lambda_label(lambda);

                    try assembler.define_label(label, @truncate(try seekable.getPos()));

                    // STH2r to put the lambda entry onto the main stack
                    try output.writeByte(0x6f);
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

            while (try scanner.read_token(input)) |token| {
                assembler.current_token = token;

                try assembler.process_token(&scanner, token, input, output, seekable);
            }

            // N.B. the reference assembler only tracks writes for the rom length,
            //      while this one includes pads. A pad without writes at the end
            //      of the source will include 0x00 bytes in the output while the
            //      reference will implicitely fill in those 0x00 when loading the rom.
            assembler.rom_length = try seekable.getPos();

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

            var full_path_buffer: [fs.MAX_PATH_BYTES]u8 = undefined;

            // Determine canonical path to included file
            const full_path = dir.realpath(path, &full_path_buffer) catch
                return error.IncludeNotFound;

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
            var reader = file.reader();
            var scanner = Scanner.init();

            while (try scanner.read_token(reader)) |token| {
                assembler.current_token = token;

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
                                .zero, .relative, .absolute => ref.addr + 1,
                                .zero_raw, .relative_raw, .absolute_raw => ref.addr,
                            };

                            try seekable.seekTo(ref_pos);

                            switch (ref.type) {
                                .zero, .zero_raw => {
                                    try output.writeByte(@truncate(addr));
                                },

                                .absolute, .absolute_raw => {
                                    try output.writeIntBig(u16, addr -% ref.offset);
                                },

                                .relative, .relative_raw => {
                                    const target_addr: i16 = @as(i16, @bitCast(addr -% ref.offset));

                                    const signed_pc: i16 = @intCast(ref_pos);
                                    const relative = target_addr - signed_pc - 2;

                                    if (relative > 127 or relative < -128)
                                        return error.ReferenceOutOfBounds;

                                    try output.writeIntBig(i8, @as(i8, @truncate(relative)));
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
            for (assembler.labels.items) |label| {
                if (label.addr) |addr| {
                    try output.writeIntBig(u16, addr);
                    try output.print("{s}\x00", .{mem.sliceTo(&label.label, 0)});
                }
            }
        }
    };
}
