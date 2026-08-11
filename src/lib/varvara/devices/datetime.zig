const Cpu = @import("uxn-core").Cpu;

const std = @import("std");
const builtin = @import("builtin");
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

const Timestamp = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    dotw: u8,
    doty: u16,
    isdst: bool,
};

const NoopBackend = struct {
    fn now() Timestamp {
        return Timestamp{
            .year = 1970,
            .month = 0,
            .day = 1,
            .hour = 0,
            .minute = 0,
            .second = 0,
            .dotw = 4,
            .doty = 1,
            .isdst = false,
        };
    }
};

const LibcBackend = struct {
    const localtime = true;

    const c = if (builtin.link_libc) @import("sys") else unreachable;

    fn now() Timestamp {
        const timestamp = c.time(null);
        const local = if (localtime) c.localtime(&timestamp) else c.gmtime(&timestamp);

        return Timestamp{
            .year = @intCast(local.*.tm_year + 1900),
            .month = @intCast(local.*.tm_mon),
            .day = @intCast(local.*.tm_mday),
            .hour = @intCast(local.*.tm_hour),
            .minute = @intCast(local.*.tm_min),
            .second = @intCast(local.*.tm_sec),
            .dotw = @intCast(local.*.tm_wday),
            .doty = @intCast(local.*.tm_yday),
            .isdst = local.*.tm_isdst != 0,
        };
    }
};

pub const Datetime = struct {
    device: impl.DeviceMixin,
    localtime: bool = true,

    const Backend = if (builtin.link_libc)
        LibcBackend
    else
        NoopBackend;

    pub fn init(addr: u4) Datetime {
        return Datetime{
            .device = .init(addr),
        };
    }

    pub fn intercept(
        clk: *Datetime,
        cpu: *Cpu,
        port: u4,
        kind: Cpu.InterceptKind,
    ) void {
        if (kind != .input)
            return;

        const t = Backend.now();

        switch (port) {
            ports.year, ports.year + 1 => {
                clk.device.storePort(u16, cpu, ports.year, t.year);
            },
            ports.month => {
                clk.device.storePort(u8, cpu, ports.month, t.month);
            },
            ports.day => {
                clk.device.storePort(u8, cpu, ports.day, t.day);
            },
            ports.hour => {
                clk.device.storePort(u8, cpu, ports.hour, t.hour);
            },
            ports.minute => {
                clk.device.storePort(u8, cpu, ports.minute, t.minute);
            },
            ports.second => {
                clk.device.storePort(u8, cpu, ports.second, t.second);
            },
            ports.dotw => {
                clk.device.storePort(u8, cpu, ports.dotw, t.dotw);
            },
            ports.doty, ports.doty + 1 => {
                clk.device.storePort(u16, cpu, ports.doty, t.doty);
            },
            ports.isdst => {
                clk.device.storePort(u8, cpu, ports.isdst, @intFromBool(t.isdst));
            },

            else => {},
        }
    }
};
