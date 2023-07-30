pub const Cpu = @import("Cpu.zig");
//pub const Debug = @import("Debug.zig");

const std = @import("std");

const Allocator = std.mem.Allocator;

pub fn load_rom(alloc: Allocator, reader: anytype) !*[0x10000]u8 {
    var ram_pos: u16 = 0x0100;
    var ram = try alloc.alloc(u8, 0x10000);

    while (true) {
        const r = try reader.readAll(ram[ram_pos..ram_pos +| 0x1000]);

        ram_pos += @truncate(r);

        if (r < 0x1000)
            break;
    }

    // Zero out the zero-page and everything behind the ROM
    @memset(ram[0..0x100], 0x00);
    @memset(ram[ram_pos..0x10000], 0x00);

    return @ptrCast(ram);
}
