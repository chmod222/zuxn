const Cpu = @import("uxn-core").Cpu;

const ctime = @cImport({
    @cInclude("time.h");
});

const impl = @import("impl.zig");

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

pub const Datetime = struct {
    device: impl.DeviceMixin,
    localtime: bool = true,

    pub fn intercept(
        clk: @This(),
        cpu: *Cpu,
        port: u4,
        kind: Cpu.InterceptKind,
    ) !void {
        if (kind != .input)
            return;

        const now = ctime.time(null);
        const local = if (clk.localtime) ctime.localtime(&now) else ctime.gmtime(&now);

        switch (port) {
            ports.year, ports.year + 1 => {
                clk.device.storePort(u16, cpu, ports.year, @as(u16, @intCast(local.*.tm_year + 1900)));
            },
            ports.month => {
                clk.device.storePort(u8, cpu, ports.month, @as(u8, @intCast(local.*.tm_mon)));
            },
            ports.day => {
                clk.device.storePort(u8, cpu, ports.day, @as(u8, @intCast(local.*.tm_mday)));
            },
            ports.hour => {
                clk.device.storePort(u8, cpu, ports.hour, @as(u8, @intCast(local.*.tm_hour)));
            },
            ports.minute => {
                clk.device.storePort(u8, cpu, ports.minute, @as(u8, @intCast(local.*.tm_min)));
            },
            ports.second => {
                clk.device.storePort(u8, cpu, ports.second, @as(u8, @intCast(local.*.tm_sec)));
            },
            ports.dotw => {
                clk.device.storePort(u8, cpu, ports.dotw, @as(u8, @intCast(local.*.tm_wday)));
            },
            ports.doty, ports.doty + 1 => {
                clk.device.storePort(u16, cpu, ports.doty, @as(u8, @intCast(local.*.tm_yday)));
            },
            ports.isdst => {
                clk.device.storePort(u8, cpu, ports.isdst, @as(u8, @intCast(local.*.tm_isdst)));
            },

            else => {},
        }
    }
};
