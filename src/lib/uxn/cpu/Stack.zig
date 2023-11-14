const Stack = @This();

const std = @import("std");

pub const faults_enabled = @import("../lib.zig").faults_enabled;

data: [0x100]u8,
sp: u8,
spt: u8,
spr: ?*u8,

pub fn init() Stack {
    return .{
        .data = [1]u8{0x00} ** 0x100,
        .sp = 0,
        .spt = 0,
        .spr = null,
    };
}

inline fn push_byte(s: *Stack, byte: u8) !void {
    if (faults_enabled and s.sp > 0xfe) {
        return error.StackOverflow;
    }

    s.data[s.sp] = byte;
    s.sp +%= 1;
}

inline fn pop_byte(s: *Stack) !u8 {
    const sp = s.spr orelse &s.sp;

    if (faults_enabled and sp.* == 0) {
        return error.StackUnderflow;
    }

    defer {
        sp.* -%= 1;
    }

    return s.data[sp.* -% 1];
}

pub fn push(s: *Stack, comptime T: type, v: T) !void {
    for (0..@sizeOf(T)) |i| {
        try s.push_byte(@truncate(v >> @truncate((@sizeOf(T) - 1 - i) * 8)));
    }
}

pub fn pop(s: *Stack, comptime T: type) !T {
    var res: T = 0;

    for (0..@sizeOf(T)) |i| {
        res |= @as(T, try s.pop_byte()) << @truncate(i * 8);
    }

    return res;
}

pub fn freeze_read(s: *Stack) void {
    s.spt = s.sp;
    s.spr = &s.spt;
}

pub fn thaw_read(s: *Stack) void {
    s.spr = null;
}
