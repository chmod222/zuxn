const Debug = @This();

const std = @import("std");

const Allocator = std.mem.Allocator;
const File = std.fs.File;

const Symbol = struct {
    addr: u16,
    symbol: [48:0]u8,
};

const Location = struct {
    closest: *const Symbol,
    offset: u16,
};

symbols: std.ArrayList(Symbol),

pub fn load_symbols(alloc: Allocator, file: File) !Debug {
    var symbol_list = std.ArrayList(Symbol).init(alloc);

    errdefer symbol_list.deinit();

    var reader = file.reader();

    return while (true) {
        var temp: Symbol = undefined;
        var fbs = std.io.FixedBufferStream([]u8){
            .buffer = &temp.symbol,
            .pos = 0,
        };

        temp.addr = reader.readIntBig(u16) catch
            return .{
            .symbols = symbol_list,
        };

        try reader.streamUntilDelimiter(fbs.writer(), 0x00, null);

        @memset(temp.symbol[fbs.getPos() catch unreachable ..], 0x00);

        try symbol_list.append(temp);
    } else unreachable;
}

pub fn unload(debug: Debug) void {
    debug.symbols.deinit();
}

pub fn locate_symbol(debug: *Debug, addr: u16) ?Location {
    var left: usize = 0;
    var right: usize = debug.symbols.items.len;
    var nearest_smaller: usize = 0;
    var nearest_bigger: usize = 0;

    const pos: ?usize = while (left < right) {
        const mid = left + (right - left) / 2;

        switch (std.math.order(addr, debug.symbols.items[mid].addr)) {
            .eq => break mid,
            .gt => {
                left = mid + 1;
                nearest_smaller = mid;
            },
            .lt => {
                right = mid;
                nearest_bigger = mid;
            },
        }
    } else null;

    if (pos) |direct_match| {
        return .{
            .closest = &debug.symbols.items[direct_match],
            .offset = 0,
        };
    } else {
        const b = &debug.symbols.items[nearest_bigger];
        const s = &debug.symbols.items[nearest_smaller];

        return if ((b.addr - addr) > (addr - s.addr)) .{
            .closest = s,
            .offset = addr - s.addr,
        } else .{
            .closest = b,
            .offset = b.addr - addr,
        };
    }
}
