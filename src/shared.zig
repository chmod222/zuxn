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
    alloc: Allocator,
    rom: []u8,
    debug_symbols: ?Debug,

    pub fn deinit(res: *LoadResult) void {
        res.alloc.free(res.rom);

        if (res.debug_symbols) |*debug|
            debug.unload();
    }
};

pub fn handleCommonArgs(
    comptime params: []const clap.Param(clap.Help),
    allocator: Allocator,
    args: std.process.Args,
    output: *Io.Writer,
) ?clap.Result(clap.Help, params, parsers) {
    var diag = clap.Diagnostic{};

    const options = clap.ParseOptions{
        .diagnostic = &diag,
        .allocator = allocator,
    };

    if (clap.parse(clap.Help, params, parsers, args, options)) |res| {
        if (res.args.help != 0) {
            clap.help(output, clap.Help, params, .{}) catch {};

            return null;
        } else if (res.positionals[0] == null) {
            output.print("Usage: {s} ", .{args.vector[0]}) catch {};
            clap.usage(output, clap.Help, params) catch {};
            output.print("\n", .{}) catch {};

            return null;
        }

        return res;
    } else |err| {
        // Report useful error and exit
        diag.report(output, err) catch {};

        return null;
    }
}

pub fn loadOrAssembleRom(
    alloc: std.mem.Allocator,
    io: Io,
    clap_res: anytype,
    input_source: []const u8,
    debug_source: ?[]const u8,
    output: *Io.Writer,
) !LoadResult {
    var cwd = Io.Dir.cwd();

    if (build_options.enable_jit_assembly) {
        if (clap_res.args.C) |dir| {
            cwd = try cwd.openDir(io, dir, .{});
        }
    }

    const input_file = try cwd.openFile(io, input_source, .{});
    var input_file_buffer: [1024]u8 = undefined;
    var input_file_reader = input_file.reader(io, &input_file_buffer);

    defer input_file.close(io);

    const min_pages = 0x10;

    if (build_options.enable_jit_assembly and
        std.ascii.endsWithIgnoreCase(input_source, ".tal"))
    {
        var assembler = try Assembler.init(alloc, io, .{
            .working_dir = cwd,
            .input_filename = clap_res.positionals[0],
            .relative_include_resolution = if (clap_res.args.@"relative-include" > 0)
                .relative_to_file
            else
                .relative_to_working_dir,
        });

        defer assembler.deinit();

        var rom_data = try alloc.alloc(u8, min_pages * uxn.Cpu.page_size);
        errdefer alloc.free(rom_data);

        @memset(rom_data[0..], 0x00);

        assembler.assemble(
            &input_file_reader.interface,
            rom_data,
        ) catch |err| {
            if (err == error.ReadFailed) {
                return input_file_reader.err orelse err;
            }

            assembler.issueDiagnostic(err, output) catch {};

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
        const ram = try uxn.loadRom(alloc, &input_file_reader.interface, min_pages);

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
