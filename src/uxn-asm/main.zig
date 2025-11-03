const std = @import("std");
const io = std.io;
const fs = std.fs;

const uxn = @import("uxn-core");
const uxn_asm = @import("uxn-asm");

const clap = @import("clap");

const Assembler = uxn_asm.Assembler(.{});

fn changeExtension(file: []const u8, ext: []const u8) [256:0]u8 {
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
        \\-r, --relative-include Consider includes to be relative to currently processed file
        \\-C <DIR>               Use DIR as the current working directory (overridden by `-r`)
        \\<FILE>                 Input source file name
        \\
    );

    var diag = clap.Diagnostic{};
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    const alloc = gpa.allocator();

    const parsers = comptime .{
        .FILE = clap.parsers.string,
        .DIR = clap.parsers.string,
    };

    var res = clap.parse(clap.Help, &params, parsers, clap.ParseOptions{
        .diagnostic = &diag,
        .allocator = alloc,
    }) catch |err| {
        // Report useful error and exit
        diag.reportToFile(.stderr(), err) catch {};

        return err;
    };

    defer res.deinit();

    if (res.args.help != 0)
        return clap.helpToFile(.stderr(), clap.Help, &params, .{});

    // Argparse end

    var output_rom: [0x10000]u8 = [1]u8{0x00} ** 0x10000;

    const base_dir = if (res.args.C) |c|
        try std.fs.cwd().openDir(c, .{})
    else
        std.fs.cwd();

    const input_file_name = res.positionals[0].?;
    const input_file = try base_dir.openFile(input_file_name, .{});
    defer input_file.close();

    const include_base = if (res.args.@"relative-include" != 0)
        try base_dir.openDir(fs.path.dirname(input_file_name).?, .{})
    else
        base_dir;

    var assembler = Assembler.init(alloc, include_base);
    defer assembler.deinit();

    assembler.include_follow = res.args.@"relative-include" != 0;
    assembler.default_input_filename = input_file_name;

    var read_buffer: [1024]u8 = undefined;
    var write_buffer: [1024]u8 = undefined;

    var reader = input_file.reader(&read_buffer);
    var err_writer = std.fs.File.stderr().writer(&write_buffer);

    assembler.assemble(&reader.interface, &output_rom) catch |err| {
        assembler.issueDiagnostic(err, &err_writer.interface) catch {};
        try err_writer.end();

        return;
    };

    const outfile_name = res.args.output orelse
        std.mem.sliceTo(&changeExtension(input_file_name, ".rom"), 0);

    const outfile = try base_dir.createFile(outfile_name, .{});
    defer outfile.close();

    var out_writer = outfile.writer(&write_buffer);

    try out_writer.interface.writeAll(output_rom[0x100..assembler.rom_length]);
    try out_writer.end();

    if (res.args.symbols) |symbol_file| {
        const symfile = try base_dir.createFile(symbol_file, .{});
        defer symfile.close();

        var sym_writer = symfile.writer(&write_buffer);

        try assembler.generateSymbols(&sym_writer.interface);
        try sym_writer.end();
    }
}
