const build_options = @import("build_options");

const std = @import("std");
const clap = @import("clap");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const uxn = @import("uxn-core");
const uxn_asm = @import("uxn-asm");

const Assembler = uxn_asm.Assembler(.{});

pub const Debug = @import("Debug.zig");

pub const parsers = .{
    .FILE = clap.parsers.string,
    .DIR = clap.parsers.string,
    .ARG = clap.parsers.string,
    .INT = clap.parsers.int(usize, 10),
};

pub const jit_assembly_args =
    \\-r, --relative-include Consider includes to be relative to currently processed file
    \\-C <DIR>               Use DIR as the current assembler working directory (overridden by `-r`)
;

pub const LoadResult = struct {
    alloc: std.mem.Allocator,

    rom: []u8,
    debug_symbols: ?Debug,

    pub fn deinit(res: *LoadResult) void {
        res.alloc.free(res.rom);

        if (res.debug_symbols) |*debug|
            debug.unload();
    }
};

pub fn createAssembler(io: Io, clap_res: anytype, alloc: Allocator) !Assembler {
    const input_file_name = clap_res.positionals[0].?;

    const base_dir = if (clap_res.args.C) |c|
        try Io.Dir.cwd().openDir(io, c, .{})
    else
        Io.Dir.cwd();

    const include_base = if (clap_res.args.@"relative-include" != 0)
        try base_dir.openDir(io, std.fs.path.dirname(input_file_name).?, .{})
    else
        base_dir;

    var assembler = Assembler.init(alloc, io, include_base);

    assembler.include_follow = clap_res.args.@"relative-include" != 0;
    assembler.default_input_filename = input_file_name;

    return assembler;
}

pub fn handleCommonArgs(
    io: Io,
    clap_res: anytype,
    params: anytype,
) ?u8 {
    var stderr_buffer: [1024]u8 = undefined;
    var stderr = Io.File.stderr().writer(io, &stderr_buffer);
    defer stderr.interface.flush() catch unreachable;

    if (clap_res.args.help != 0) {
        clap.help(&stderr.interface, clap.Help, &params, .{}) catch {};

        return 0;
    }

    if (clap_res.positionals.len < 1) {
        stderr.print("Usage: {s} ", .{std.os.argv[0]}) catch {};
        clap.usage(stderr, clap.Help, &params) catch {};
        stderr.print("\n", .{}) catch {};

        return 0;
    }

    return null;
}

pub fn loadOrAssembleRom(
    alloc: std.mem.Allocator,
    io: Io,
    args: anytype,
    input_source: []const u8,
    debug_source: ?[]const u8,
) !LoadResult {
    const cwd = if (!@hasField(@TypeOf(args.args), "C"))
        Io.Dir.cwd()
    else if (args.args.C) |c|
        try Io.Dir.cwd().openDir(io, c, .{})
    else
        Io.Dir.cwd();

    const input_file = try cwd.openFile(io, input_source, .{});
    defer input_file.close(io);

    var stderr_buffer: [1024]u8 = undefined;
    var stderr = Io.File.stderr().writer(io, &stderr_buffer);
    defer stderr.interface.flush() catch {};

    var buffer: [1024]u8 = undefined;
    var file_reader = input_file.reader(io, &buffer);

    const min_pages = 0x10;

    if (build_options.enable_jit_assembly and
        std.ascii.endsWithIgnoreCase(input_source, ".tal"))
    {
        var assembler = try createAssembler(io, args, alloc);
        defer assembler.deinit();

        var rom_data = try alloc.alloc(u8, min_pages * uxn.Cpu.page_size);
        errdefer alloc.free(rom_data);

        @memset(rom_data[0..], 0x00);

        assembler.assemble(
            &file_reader.interface,
            rom_data,
        ) catch |err| {
            if (err == error.ReadFailed) {
                return file_reader.err orelse err;
            }

            assembler.issueDiagnostic(err, &stderr.interface) catch {};

            return error.AssemblyFailed;
        };

        return .{
            .alloc = alloc,

            .rom = rom_data,

            .debug_symbols = if (debug_source) |_| r: {
                var symbol_writer = Io.Writer.Allocating.init(alloc);
                defer symbol_writer.deinit();

                try assembler.generateSymbols(&symbol_writer.writer);

                var symbol_reader = Io.Reader.fixed(symbol_writer.writer.buffered());

                break :r try Debug.loadSymbols(alloc, &symbol_reader);
            } else null,
        };
    } else {
        const ram = try uxn.loadRom(alloc, &file_reader.interface, min_pages);

        return .{
            .alloc = alloc,

            .rom = ram,

            .debug_symbols = if (debug_source) |debug_symbols| r: {
                const symbols_file = try cwd.openFile(io, debug_symbols, .{});
                defer symbols_file.close(io);

                var read_buffer: [1024]u8 = undefined;
                var reader = symbols_file.reader(io, &read_buffer);

                break :r Debug.loadSymbols(alloc, &reader.interface) catch |err| {
                    if (err == error.ReadFailed)
                        return reader.err orelse err;

                    return err;
                };
            } else null,
        };
    }
}
