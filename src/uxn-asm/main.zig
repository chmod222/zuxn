const std = @import("std");
const io = std.io;

const uxn = @import("uxn-core");
const uxn_asm = @import("uxn-asm");

const clap = @import("clap");

const Assembler = uxn_asm.Assembler(.{});

fn change_extension(file: []const u8, ext: []const u8) [256:0]u8 {
    var out: [256:0]u8 = [1:0]u8{0x00} ** 256;

    const len = std.mem.lastIndexOfScalar(u8, file, '.') orelse file.len;

    @memcpy(out[0..len], file[0..len]);
    @memcpy(out[len .. len + ext.len], ext);

    return out;
}

pub fn main() !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help             Display this help and exit.
        \\-s, --symbols <FILE>   Generate symbol file
        \\-o, --output <FILE>    Input ROM file name (default: based on input file)
        \\<FILE>                 Input source file name
        \\
    );

    var diag = clap.Diagnostic{};
    var stderr = std.io.getStdErr().writer();

    const parsers = comptime .{
        .FILE = clap.parsers.string,
    };

    var res = clap.parse(clap.Help, &params, parsers, .{
        .diagnostic = &diag,
    }) catch |err| {
        // Report useful error and exit
        diag.report(stderr, err) catch {};

        return err;
    };

    defer res.deinit();

    if (res.args.help != 0)
        return clap.help(stderr, clap.Help, &params, .{});

    // Argparse end

    var output_rom: [0x10000]u8 = [1]u8{0x00} ** 0x10000;
    var output = std.io.fixedBufferStream(&output_rom);

    const input_file_name = res.positionals[0];
    const input_file = try std.fs.cwd().openFile(input_file_name, .{});
    defer input_file.close();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    var assembler = Assembler.init(alloc, std.fs.cwd());
    defer assembler.deinit();

    assembler.include_follow = false;
    assembler.default_input_filename = input_file_name;

    assembler.assemble(
        input_file.reader(),
        output.writer(),
        output.seekableStream(),
    ) catch |err| {
        assembler.issue_diagnostic(err, io.getStdErr().writer()) catch {};

        return;
    };

    const outfile_name = res.args.output orelse
        std.mem.sliceTo(&change_extension(input_file_name, ".rom"), 0);

    const outfile = try std.fs.cwd().createFile(outfile_name, .{});
    defer outfile.close();

    try outfile.writer().writeAll(output_rom[0x100..assembler.rom_length]);

    if (res.args.symbols) |symbol_file| {
        const symfile = try std.fs.cwd().createFile(symbol_file, .{});
        defer symfile.close();

        try assembler.generate_symbols(symfile.writer());
    }
}
