const Stack = @This();

const std = @import("std");

data: [0x100]u8,
sp: u8,
spt: u8,
spr: ?*u8,

xflow_behaviour: enum {
    wrap,
    fault,
} = .wrap,

pub fn init() Stack {
    return .{
        .data = [1]u8{0x00} ** 0x100,
        .sp = 0,
        .spt = 0,
        .spr = null,
    };
}

inline fn pushByte(s: *Stack, byte: u8) !void {
    if (s.xflow_behaviour == .fault and s.sp > 0xfe) {
        return error.StackOverflow;
    }

    s.data[s.sp] = byte;
    s.sp +%= 1;
}

inline fn popByte(s: *Stack) !u8 {
    const sp = s.spr orelse &s.sp;

    if (s.xflow_behaviour == .fault and sp.* == 0) {
        return error.StackUnderflow;
    }

    defer {
        sp.* -%= 1;
    }

    return s.data[sp.* -% 1];
}

pub fn push(s: *Stack, comptime T: type, v: T) !void {
    for (0..@sizeOf(T)) |i| {
        try s.pushByte(@truncate(v >> @truncate((@sizeOf(T) - 1 - i) * 8)));
    }
}

pub fn pop(s: *Stack, comptime T: type) !T {
    var res: T = 0;

    for (0..@sizeOf(T)) |i| {
        res |= @as(T, try s.popByte()) << @truncate(i * 8);
    }

    return res;
}

pub fn freezeRead(s: *Stack) void {
    s.spt = s.sp;
    s.spr = &s.spt;
}

pub fn thawRead(s: *Stack) void {
    s.spr = null;
}
