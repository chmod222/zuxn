const Stack = @This();

const std = @import("std");

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

pub fn push(s: *Stack, comptime T: type, v: T) !void {
    if (s.sp > 0xff - @sizeOf(T))
        return error.StackOverflow;

    std.mem.writeIntBig(
        T,
        @as(*[@sizeOf(T)]u8, @ptrCast(s.data[s.sp .. s.sp + @sizeOf(T)])),
        v,
    );

    s.sp += @sizeOf(T);
}

pub fn pop(s: *Stack, comptime T: type) !T {
    const sp = s.spr orelse &s.sp;

    if (sp.* < @sizeOf(T))
        return error.StackUnderflow;

    defer {
        sp.* -= @sizeOf(T);
    }

    return std.mem.readIntBig(
        T,
        @as(*[@sizeOf(T)]u8, @ptrCast(s.data[sp.* - @sizeOf(T) .. sp.*])),
    );
}

pub fn freeze_read(s: *Stack) void {
    s.spt = s.sp;
    s.spr = &s.spt;
}

pub fn thaw_read(s: *Stack) void {
    s.spr = null;
}
