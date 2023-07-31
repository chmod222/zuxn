const Cpu = @import("uxn-core").Cpu;

const ctime = @cImport({
    @cInclude("time.h");
});

addr: u4,

localtime: bool = true,

pub const ports = struct {
    pub const year = 0x0;
    pub const month = 0x2;
    pub const day = 0x3;
    pub const hour = 0x4;
    pub const minute = 0x5;
    pub const second = 0x6;
    pub const dotw = 0x7;
    pub const doty = 0x8;
    pub const isdst = 0xa;
};

pub usingnamespace @import("impl.zig").DeviceMixin(@This());

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

    switch (port) {
        ports.year, ports.year + 1 => {
            cpu.store_device_mem(u16, dev.port_address(ports.year), @as(u16, @intCast(local.*.tm_year + 1900)));
        },
        ports.month => {
            cpu.store_device_mem(u8, dev.port_address(ports.month), @as(u8, @intCast(local.*.tm_mon)));
        },
        ports.day => {
            cpu.store_device_mem(u8, dev.port_address(ports.day), @as(u8, @intCast(local.*.tm_mday)));
        },
        ports.hour => {
            cpu.store_device_mem(u8, dev.port_address(ports.hour), @as(u8, @intCast(local.*.tm_hour)));
        },
        ports.minute => {
            cpu.store_device_mem(u8, dev.port_address(ports.minute), @as(u8, @intCast(local.*.tm_min)));
        },
        ports.second => {
            cpu.store_device_mem(u8, dev.port_address(ports.second), @as(u8, @intCast(local.*.tm_sec)));
        },
        ports.dotw => {
            cpu.store_device_mem(u8, dev.port_address(ports.dotw), @as(u8, @intCast(local.*.tm_wday)));
        },
        ports.doty, ports.doty + 1 => {
            cpu.store_device_mem(u16, dev.port_address(ports.doty), @as(u8, @intCast(local.*.tm_yday)));
        },
        ports.isdst => {
            cpu.store_device_mem(u8, dev.port_address(ports.isdst), @as(u8, @intCast(local.*.tm_isdst)));
        },

        else => {},
    }
}
