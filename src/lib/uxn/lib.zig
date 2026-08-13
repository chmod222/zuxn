pub const Cpu = @import("Cpu.zig");
//pub const Debug = @import("Debug.zig");

const std = @import("std");
const Io = std.Io;

const Allocator = std.mem.Allocator;

pub fn loadRom(alloc: Allocator, reader: *Io.Reader, min_pages: usize) ![]u8 {
    var writer = Io.Writer.Allocating.init(alloc);
    errdefer writer.deinit();

    // Fill the zero page
    _ = writer.writer.splatByte(0x00, 0x100) catch {
        return error.OutOfMemory;
    };

    _ = reader.streamRemaining(&writer.writer) catch |e| {
        if (e == error.WriteFailed) {
            return error.OutOfMemory;
        } else {
            // Reader failed, pass on the information.
            return e;
        }
    };

    // How much data was written so far and how much is needed to reach the next page boundary.
    const n = writer.written().len;
    const remain = Cpu.page_size - (n % Cpu.page_size);

    // How many pages there are after padding and how many are still needed to reach minimum
    const ps = (n + remain) / Cpu.page_size;
    const ps_remain = min_pages -| ps;

    // Total number of bytes to allocate
    const extra = (ps_remain * Cpu.page_size) + remain;

    _ = writer.writer.splatByte(0x00, extra) catch {
        return error.OutOfMemory;
    };

    return try writer.toOwnedSlice();
}
