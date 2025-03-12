const build_options = @import("build_options");

const std = @import("std");
const clap = @import("clap");

const os = std.os;

const uxn = @import("uxn-core");
const uxn_asm = @import("uxn-asm");

pub const Debug = @import("Debug.zig");

pub const parsers = .{
    .FILE = clap.parsers.string,
    .ARG = clap.parsers.string,
    .INT = clap.parsers.int(u8, 10),
};

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

pub fn handleCommonArgs(
    clap_res: anytype,
    params: anytype,
) ?u8 {
    const stderr = std.io.getStdErr().writer();

    if (clap_res.args.help != 0) {
        clap.help(stderr, clap.Help, &params, .{}) catch {};

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
    input_source: []const u8,
    debug_source: ?[]const u8,
) !LoadResult {
    const cwd = std.fs.cwd();
    const input_file = try cwd.openFile(input_source, .{});

    defer input_file.close();

    if (build_options.enable_jit_assembly and
        std.ascii.endsWithIgnoreCase(input_source, ".tal"))
    {
        var assembler = uxn_asm.Assembler(.{}).init(alloc, cwd);
        defer assembler.deinit();

        var rom_data = try alloc.create([uxn.Cpu.page_size]u8);
        var rom_writer = std.io.fixedBufferStream(rom_data);

        @memset(rom_data[0..], 0x00);

        assembler.include_follow = false;
        assembler.default_input_filename = input_source;

        assembler.assemble(
            input_file.reader(),
            rom_writer.writer(),
            rom_writer.seekableStream(),
        ) catch |err| {
            assembler.issueDiagnostic(err, std.io.getStdErr().writer()) catch {};

            alloc.free(rom_data);

            return error.AssemblyFailed;
        };

        return .{
            .alloc = alloc,

            .rom = rom_data,

            .debug_symbols = if (debug_source) |_| r: {
                var fifo = std.fifo.LinearFifo(u8, .Dynamic).init(alloc);
                defer fifo.deinit();

                try assembler.generateSymbols(fifo.writer());

                break :r try Debug.loadSymbols(alloc, fifo.reader());
            } else null,
        };
    } else {
        return .{
            .alloc = alloc,

            .rom = try uxn.loadRom(alloc, input_file),

            .debug_symbols = if (debug_source) |debug_symbols| r: {
                const symbols_file = try cwd.openFile(debug_symbols, .{});
                defer symbols_file.close();

                break :r try Debug.loadSymbols(alloc, symbols_file.reader());
            } else null,
        };
    }
}
