const std = @import("std");
const fs = std.fs;
const Io = std.Io;
const mem = std.mem;

const uxn = @import("uxn-core");

const logger = std.log.scoped(.uxn_varvara);

pub const Sandbox = @import("Sandbox.zig");

pub const system = @import("devices/system.zig");
pub const console = @import("devices/console.zig");
pub const screen = @import("devices/screen.zig");
pub const audio = @import("devices/audio.zig");
pub const controller = @import("devices/controller.zig");
pub const mouse = @import("devices/mouse.zig");
pub const file = @import("devices/file.zig");
pub const datetime = @import("devices/datetime.zig");

// Back-compat from when this was all generic.
pub const VarvaraDefault = Varvara;

pub const Varvara = struct {
    system_device: system.System,
    console_device: console.Console,
    screen_device: screen.Screen,
    audio_devices: [4]audio.Audio,
    controller_device: controller.Controller,
    mouse_device: mouse.Mouse,
    file_devices: [2]file.File,
    datetime_device: datetime.DefaultDatetime,

    pub fn init(
        allocator: std.mem.Allocator,
        io: Io,
        env: ?*std.process.Environ.Map,
        stdout: *Io.Writer,
        stderr: *Io.Writer,
    ) !Varvara {
        var sys: Varvara = .{
            .system_device = .init(0x0, env),
            .console_device = .init(0x1, io, stderr, stdout),
            .screen_device = .init(0x2, allocator),

            .audio_devices = .{
                .init(0x3),
                .init(0x4),
                .init(0x5),
                .init(0x6),
            },
            .controller_device = .init(0x8),
            .mouse_device = .init(0x9),
            .file_devices = .{
                .init(0xa, io),
                .init(0xb, io),
            },
            .datetime_device = .init(0xc),
        };

        try sys.screen_device.initializeGraphics();

        return sys;
    }

    pub fn deinit(sys: *Varvara) void {
        sys.screen_device.cleanupGraphics();

        for (&sys.file_devices) |*f|
            f.cleanup();
    }

    pub fn intercept(
        sys: *Varvara,
        cpu: *uxn.Cpu,
        addr: u8,
        kind: uxn.Cpu.InterceptKind,
    ) !void {
        const port: u4 = @truncate(addr & 0xf);

        switch (addr >> 4) {
            0x0 => {
                sys.system_device.intercept(cpu, port, kind);

                if (addr & 0xf >= system.ports.red and
                    addr & 0xf < system.ports.debug)
                {
                    sys.screen_device.forceRedraw();
                }
            },
            0x1 => try sys.console_device.intercept(cpu, port, kind),
            0x2 => sys.screen_device.intercept(cpu, port, kind),
            0x3 => sys.audio_devices[0].intercept(cpu, port, kind),
            0x4 => sys.audio_devices[1].intercept(cpu, port, kind),
            0x5 => sys.audio_devices[2].intercept(cpu, port, kind),
            0x6 => sys.audio_devices[3].intercept(cpu, port, kind),
            0x8 => sys.controller_device.intercept(cpu, port, kind),
            0x9 => sys.mouse_device.intercept(cpu, port, kind),
            0xa => try sys.file_devices[0].intercept(cpu, port, kind),
            0xb => try sys.file_devices[1].intercept(cpu, port, kind),
            0xc => sys.datetime_device.intercept(cpu, port, kind),

            else => {},
        }
    }
};

const InterceptMasks = struct { input: [0x10]u16, output: [0x10]u16 };

pub const headless_intercepts = InterceptMasks{
    .input = .{ 0x0030, 0x0060, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x07ff, 0x0000, 0x0000, 0x0000 },
    .output = .{ 0xc038, 0x8300, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0xa260, 0xa260, 0x0000, 0x0000, 0x0000, 0x0000 },
};

pub const full_intercepts = InterceptMasks{
    .input = .{ 0x0030, 0x0060, 0x003c, 0x0014, 0x0014, 0x0014, 0x0014, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x07ff, 0x0000, 0x0000, 0x0000 },
    .output = .{ 0xff38, 0x8300, 0xc028, 0x8000, 0x8000, 0x8000, 0x8000, 0x0000, 0x0000, 0x0000, 0xa260, 0xa260, 0x0000, 0x0000, 0x0000, 0x0000 },
};
