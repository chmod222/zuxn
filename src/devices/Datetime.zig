const Cpu = @import("../Cpu.zig");
const std = @import("std");

const ctime = @cImport({
    @cInclude("time.h");
});

addr: u4,

localtime: bool = true,

pub const ports = struct {
    const year = 0x0;
    const month = 0x2;
    const day = 0x3;
    const hour = 0x4;
    const minute = 0x5;
    const second = 0x6;
    const dotw = 0x7;
    const doty = 0x8;
    const isdst = 0xa;
};

pub fn intercept(
    dev: @This(),
    cpu: *Cpu,
    port: u4,
    kind: Cpu.InterceptKind,
) !void {
    if (kind != .input)
        return;

    const now = ctime.time(null);
    const local = if (dev.localtime) ctime.localtime(&now) else ctime.gmtime(&now);

    const base = @as(u8, dev.addr) << 4;

    switch (port) {
        ports.year, ports.year + 1 => {
            cpu.store_device_mem(u16, base | ports.year, @as(u16, @intCast(local.*.tm_year + 1900)));
        },
        ports.month => {
            cpu.store_device_mem(u8, base | ports.month, @as(u8, @intCast(local.*.tm_mon)));
        },
        ports.day => {
            cpu.store_device_mem(u8, base | ports.day, @as(u8, @intCast(local.*.tm_mday)));
        },
        ports.hour => {
            cpu.store_device_mem(u8, base | ports.hour, @as(u8, @intCast(local.*.tm_hour)));
        },
        ports.minute => {
            cpu.store_device_mem(u8, base | ports.minute, @as(u8, @intCast(local.*.tm_min)));
        },
        ports.second => {
            cpu.store_device_mem(u8, base | ports.second, @as(u8, @intCast(local.*.tm_sec)));
        },
        ports.dotw => {
            cpu.store_device_mem(u8, base | ports.dotw, @as(u8, @intCast(local.*.tm_wday)));
        },
        ports.doty, ports.doty + 1 => {
            cpu.store_device_mem(u16, base | ports.doty, @as(u8, @intCast(local.*.tm_yday)));
        },
        ports.isdst => {
            cpu.store_device_mem(u8, base | ports.isdst, @as(u8, @intCast(local.*.tm_isdst)));
        },

        else => {},
    }
}
