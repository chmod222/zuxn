const std = @import("std");
const uxn = @import("uxn-core");

const Assembler = @import("Assembler.zig");

pub fn main() !void {
    var output_rom: [0x10000]u8 = [1]u8{0x00} ** 0x10000;
    var output = std.io.fixedBufferStream(&output_rom);

    var assembler = Assembler.init();

    const input_file = try std.fs.cwd().openFile("test.tal", .{});
    defer input_file.close();

    try assembler.assemble(
        input_file.reader(),
        output.writer(),
        output.seekableStream(),
    );

    const outfile = try std.fs.cwd().createFile("test.rom", .{});
    defer outfile.close();

    try outfile.writer().writeAll(output_rom[0x100..assembler.rom_length]);

    const symfile = try std.fs.cwd().createFile("test.rom.sym", .{});
    defer symfile.close();

    try assembler.generate_symbols(symfile.writer());
}
