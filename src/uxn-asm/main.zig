const std = @import("std");
const Io = std.Io;

const uxn = @import("uxn-core");
const uxn_asm = @import("uxn-asm");
const shared = @import("uxn-shared");

const clap = @import("clap");

const Assembler = uxn_asm.Assembler(.{});

fn changeExtension(file: []const u8, ext: []const u8) [256:0]u8 {
    var out: [256:0]u8 = @splat(0x00);

    const len = std.mem.lastIndexOfScalar(u8, file, '.') orelse file.len;

    @memcpy(out[0..len], file[0..len]);
    @memcpy(out[len .. len + ext.len], ext);

    return out;
}

pub fn main(init: std.process.Init) !void {
    var stderr_buffer: [1024]u8 = undefined;
    var stderr = Io.File.stderr().writer(init.io, &stderr_buffer);
    defer stderr.interface.flush() catch {};

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

    const res = shared.handleCommonArgs(
        &params,
        init.gpa,
        init.minimal.args,
        &stderr.interface,
    ) orelse return;

    defer res.deinit();

    const input_file_name = res.positionals[0].?;

    var output_rom: [0x10000]u8 = @splat(0x00);

    const cwd = if (res.args.C) |c|
        try Io.Dir.cwd().openDir(init.io, c, .{})
    else
        Io.Dir.cwd();

    var assembler = try Assembler.init(init.gpa, init.io, .{
        .working_dir = cwd,
        .input_filename = input_file_name,
        .relative_include_resolution = if (res.args.@"relative-include" > 0)
            .relative_to_file
        else
            .relative_to_working_dir,
    });

    defer assembler.deinit();

    const input_file = try cwd.openFile(init.io, input_file_name, .{});
    var input_file_buffer: [1024]u8 = undefined;
    var input_file_reader = input_file.reader(init.io, &input_file_buffer);

    defer input_file.close(init.io);

    assembler.assemble(&input_file_reader.interface, &output_rom) catch |err| {
        return assembler.issueDiagnostic(err, &stderr.interface);
    };

    const outfile_name = res.args.output orelse
        std.mem.sliceTo(&changeExtension(input_file_name, ".rom"), 0);

    const outfile = try cwd.createFile(init.io, outfile_name, .{});
    defer outfile.close(init.io);

    try outfile.writeStreamingAll(init.io, output_rom[0x100..assembler.rom_length]);

    if (res.args.symbols) |symbol_file| {
        const symfile = try cwd.createFile(init.io, symbol_file, .{});
        defer symfile.close(init.io);

        // Reuse stderr buffer since we no longer need it
        var sym_writer = symfile.writer(init.io, &stderr_buffer);

        try assembler.generateSymbols(&sym_writer.interface);
        try sym_writer.end();
    }

    if (res.args.verbose != 0) {
        // Reuse stderr buffer since we no longer need it
        var w = Io.File.stdout().writer(init.io, &stderr_buffer);

        try w.interface.print("ROM Size: {Bi:.2}\n", .{assembler.rom_length});
        try w.interface.flush();
    }
}
