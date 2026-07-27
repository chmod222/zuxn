const std = @import("std");
const Io = std.Io;

const uxn = @import("uxn-core");
const uxn_asm = @import("uxn-asm");
const shared = @import("uxn-shared");

const clap = @import("clap");

const Assembler = uxn_asm.Assembler(.{});

fn changeExtension(file: []const u8, ext: []const u8) [256:0]u8 {
    var out: [256:0]u8 = [1:0]u8{0x00} ** 256;

    const len = std.mem.lastIndexOfScalar(u8, file, '.') orelse file.len;

    @memcpy(out[0..len], file[0..len]);
    @memcpy(out[len .. len + ext.len], ext);

    return out;
}

pub fn main(init: std.process.Init) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help             Display this help and exit.
        \\-s, --symbols <FILE>   Generate symbol file
        \\-o, --output <FILE>    Input ROM file name (default: based on input file)
        \\-r, --relative-include Consider includes to be relative to currently processed file
        \\-C <DIR>               Use DIR as the current working directory (overridden by `-r`)
        \\-v, --verbose          Output extra information after successful assembly
        \\<FILE>                 Input source file name
        \\
    );

    var diag = clap.Diagnostic{};

    const alloc = init.gpa;

    const parsers = comptime .{
        .FILE = clap.parsers.string,
        .DIR = clap.parsers.string,
    };

    var res = clap.parse(clap.Help, &params, parsers, init.minimal.args, clap.ParseOptions{
        .diagnostic = &diag,
        .allocator = alloc,
    }) catch |err| {
        // Report useful error and exit
        diag.reportToFile(init.io, .stderr(), err) catch {};

        return err;
    };

    defer res.deinit();

    if (res.args.help != 0)
        return clap.helpToFile(init.io, .stderr(), clap.Help, &params, .{});

    // Argparse end

    var output_rom: [0x10000]u8 = [1]u8{0x00} ** 0x10000;

    const base_dir = if (res.args.C) |c|
        try Io.Dir.cwd().openDir(init.io, c, .{})
    else
        Io.Dir.cwd();

    const input_file_name = res.positionals[0].?;
    const input_file = try base_dir.openFile(init.io, input_file_name, .{});
    defer input_file.close(init.io);

    var assembler = try shared.createAssembler(init.io, res, alloc);
    defer assembler.deinit();

    var read_buffer: [1024]u8 = undefined;
    var write_buffer: [1024]u8 = undefined;

    var reader = input_file.reader(init.io, &read_buffer);
    var err_writer = Io.File.stderr().writer(init.io, &write_buffer);

    assembler.assemble(&reader.interface, &output_rom) catch |err| {
        assembler.issueDiagnostic(err, &err_writer.interface) catch {};
        try err_writer.end();

        return;
    };

    const outfile_name = res.args.output orelse
        std.mem.sliceTo(&changeExtension(input_file_name, ".rom"), 0);

    const outfile = try base_dir.createFile(init.io, outfile_name, .{});
    defer outfile.close(init.io);

    var out_writer = outfile.writer(init.io, &write_buffer);

    try out_writer.interface.writeAll(output_rom[0x100..assembler.rom_length]);
    try out_writer.end();

    if (res.args.symbols) |symbol_file| {
        const symfile = try base_dir.createFile(init.io, symbol_file, .{});
        defer symfile.close(init.io);

        var sym_writer = symfile.writer(init.io, &write_buffer);

        try assembler.generateSymbols(&sym_writer.interface);
        try sym_writer.end();
    }

    if (res.args.verbose != 0) {
        var buf: [1024]u8 = undefined;
        var w = Io.File.stdout().writer(init.io, &buf);

        try w.interface.print("ROM Size: {Bi:.2}\n", .{assembler.rom_length});
        try w.interface.flush();
    }
}
