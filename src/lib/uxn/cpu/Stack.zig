const Stack = @This();

const std = @import("std");

data: [0x100]u8,
sp: u8,

pub fn init() Stack {
    return .{
        .data = [1]u8{0x00} ** 0x100,
        .sp = 0,
    };
}

inline fn pushByte(s: *Stack, byte: u8) void {
    s.data[s.sp] = byte;
    s.sp +%= 1;
}

inline fn popByte(s: *Stack) u8 {
    defer {
        s.sp -%= 1;
    }

    return s.data[s.sp -% 1];
}

pub fn push(s: *Stack, comptime T: type, v: T) void {
    inline for (0..@sizeOf(T)) |i| {
        s.pushByte(@truncate(v >> @truncate((@sizeOf(T) - 1 - i) * 8)));
    }
}

pub fn pop(s: *Stack, comptime T: type) T {
    var res: T = 0;

    inline for (0..@sizeOf(T)) |i| {
        res |= @as(T, s.popByte()) << @truncate(i * 8);
    }

    return res;
}
