pub const Cpu = @import("Cpu.zig");
//pub const Debug = @import("Debug.zig");

pub const faults_enabled = false;

const std = @import("std");
const io = std.io;

const Allocator = std.mem.Allocator;

pub fn loadRom(alloc: Allocator, reader: *io.Reader) !*[Cpu.page_size]u8 {
    const ram = try alloc.create([Cpu.page_size]u8);

    var writer = io.Writer.fixed(ram);

    // Fill zero page
    _ = try writer.splatByte(0x00, 0x100);

    // Read ROM data until EOF or full
    _ = reader.streamRemaining(&writer) catch |e| {
        if (e != error.WriteFailed) {
            return e;
        }
    };

    // Clear remaining ROM data
    _ = writer.splatByte(0x00, writer.unusedCapacityLen()) catch {};

    return ram;
}
