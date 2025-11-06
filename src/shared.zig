const build_options = @import("build_options");

const std = @import("std");
const clap = @import("clap");

const Allocator = std.mem.Allocator;
const os = std.os;
const fs = std.fs;

const uxn = @import("uxn-core");
const uxn_asm = @import("uxn-asm");

const Assembler = uxn_asm.Assembler(.{});

pub const Debug = @import("Debug.zig");

pub const parsers = .{
    .FILE = clap.parsers.string,
    .DIR = clap.parsers.string,
    .ARG = clap.parsers.string,
    .INT = clap.parsers.int(u8, 10),
};

pub const jit_assembly_args =
    \\-r, --relative-include Consider includes to be relative to currently processed file
    \\-C <DIR>               Use DIR as the current assembler working directory (overridden by `-r`)
;

pub const LoadResult = struct {
    alloc: std.mem.Allocator,

    rom: *[uxn.Cpu.page_size]u8,
    debug_symbols: ?Debug,

    pub fn deinit(res: *LoadResult) void {
        res.alloc.free(res.rom);

        if (res.debug_symbols) |*debug|
            debug.unload();
    }
};

pub fn createAssembler(clap_res: anytype, alloc: Allocator) !Assembler {
    const input_file_name = clap_res.positionals[0].?;

    const base_dir = if (clap_res.args.C) |c|
        try std.fs.cwd().openDir(c, .{})
    else
        std.fs.cwd();

    const include_base = if (clap_res.args.@"relative-include" != 0)
        try base_dir.openDir(fs.path.dirname(input_file_name).?, .{})
    else
        base_dir;

    var assembler = Assembler.init(alloc, include_base);

    assembler.include_follow = clap_res.args.@"relative-include" != 0;
    assembler.default_input_filename = input_file_name;

    return assembler;
}

pub fn handleCommonArgs(
    clap_res: anytype,
    params: anytype,
) ?u8 {
    var stderr_buffer: [1024]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&stderr_buffer);
    defer stderr.interface.flush() catch unreachable;

    if (clap_res.args.help != 0) {
        clap.help(&stderr.interface, clap.Help, &params, .{}) catch {};

        return 0;
    }

    if (clap_res.positionals.len < 1) {
        stderr.print("Usage: {s} ", .{os.argv[0]}) catch {};
        clap.usage(stderr, clap.Help, &params) catch {};
        stderr.print("\n", .{}) catch {};

        return 0;
    }

    return null;
}

pub fn loadOrAssembleRom(
    alloc: std.mem.Allocator,
    args: anytype,
    input_source: []const u8,
    debug_source: ?[]const u8,
) !LoadResult {
    const cwd = if (!@hasField(@TypeOf(args.args), "C"))
        std.fs.cwd()
    else if (args.args.C) |c|
        try std.fs.cwd().openDir(c, .{})
    else
        std.fs.cwd();

    const input_file = try cwd.openFile(input_source, .{});
    defer input_file.close();

    var stderr_buffer: [1024]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&stderr_buffer);
    defer stderr.interface.flush() catch {};

    var buffer: [1024]u8 = undefined;
    var file_reader = input_file.reader(&buffer);

    if (build_options.enable_jit_assembly and
        std.ascii.endsWithIgnoreCase(input_source, ".tal"))
    {
        var assembler = try createAssembler(args, alloc);
        defer assembler.deinit();

        var rom_data = try alloc.create([uxn.Cpu.page_size]u8);

        @memset(rom_data[0..], 0x00);

        assembler.assemble(
            &file_reader.interface,
            rom_data,
        ) catch |err| {
            assembler.issueDiagnostic(err, &stderr.interface) catch {};

            alloc.free(rom_data);

            return error.AssemblyFailed;
        };

        return .{
            .alloc = alloc,

            .rom = rom_data,

            .debug_symbols = if (debug_source) |_| r: {
                var symbol_writer = std.io.Writer.Allocating.init(alloc);
                defer symbol_writer.deinit();

                try assembler.generateSymbols(&symbol_writer.writer);

                var symbol_data = symbol_writer.toArrayList();
                defer symbol_data.deinit(alloc);

                var symbol_reader = std.io.Reader.fixed(symbol_data.items);

                break :r try Debug.loadSymbols(alloc, &symbol_reader);
            } else null,
        };
    } else {
        return .{
            .alloc = alloc,

            .rom = try uxn.loadRom(alloc, &file_reader.interface),

            .debug_symbols = if (debug_source) |debug_symbols| r: {
                const symbols_file = try cwd.openFile(debug_symbols, .{});
                defer symbols_file.close();

                var read_buffer: [1024]u8 = undefined;
                var reader = symbols_file.reader(&read_buffer);

                break :r try Debug.loadSymbols(alloc, &reader.interface);
            } else null,
        };
    }
}
