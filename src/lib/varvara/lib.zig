const std = @import("std");

const uxn = @import("uxn-core");

pub const System = @import("devices/System.zig");
pub const Console = @import("devices/Console.zig");
pub const Screen = @import("devices/Screen.zig");
pub const Audio = @import("devices/Audio.zig");
pub const Controller = @import("devices/Controller.zig");
pub const Mouse = @import("devices/Mouse.zig");
pub const File = @import("devices/File.zig");
pub const Datetime = @import("devices/Datetime.zig");

pub const pages = 4;

pub fn VarvaraSystem(comptime StdoutWriter: type, comptime StderrWriter: type) type {
    return struct {
        stderr: StderrWriter,
        stdout: StdoutWriter,

        allocator: std.mem.Allocator,
        page_table: ?[][uxn.Cpu.page_size]u8 = null,

        system_device: System,
        console_device: Console,
        screen_device: Screen,
        audio_devices: [4]Audio,
        controller_device: Controller,
        mouse_device: Mouse,
        file_devices: [2]File,
        datetime_device: Datetime,

        pub fn init(
            allocator: std.mem.Allocator,
            stdout: StdoutWriter,
            stderr: StderrWriter,
        ) !@This() {
            const page_table = try allocator.alloc([uxn.Cpu.page_size]u8, pages);

            var system: @This() = .{
                .stderr = stdout,
                .stdout = stderr,

                .allocator = allocator,
                .page_table = page_table,

                .system_device = .{ .addr = 0x0, .additional_pages = page_table },
                .console_device = .{ .addr = 0x1 },
                .screen_device = .{ .addr = 0x2, .alloc = allocator },
                .audio_devices = .{
                    .{ .addr = 0x3 },
                    .{ .addr = 0x4 },
                    .{ .addr = 0x5 },
                    .{ .addr = 0x6 },
                },
                .controller_device = .{ .addr = 0x8 },
                .mouse_device = .{ .addr = 0x9 },
                .file_devices = .{
                    .{ .addr = 0xa },
                    .{ .addr = 0xb },
                },
                .datetime_device = .{ .addr = 0xc },
            };

            try system.screen_device.initialize_graphics();

            return system;
        }

        pub fn deinit(sys: *@This()) void {
            sys.screen_device.cleanup_graphics();

            for (&sys.file_devices) |*f|
                f.cleanup();

            if (sys.system_device.additional_pages) |page_table|
                sys.allocator.free(page_table);
        }

        pub fn intercept(
            sys: *@This(),
            cpu: *uxn.Cpu,
            addr: u8,
            kind: uxn.Cpu.InterceptKind,
        ) !void {
            const port: u4 = @truncate(addr & 0xf);

            switch (addr >> 4) {
                0x0 => {
                    try sys.system_device.intercept(cpu, port, kind);

                    if (addr & 0xf >= System.ports.red and
                        addr & 0xf < System.ports.debug)
                    {
                        sys.screen_device.force_redraw();
                    }
                },
                0x1 => try sys.console_device.intercept(cpu, port, kind, sys.stdout, sys.stderr),
                0x2 => try sys.screen_device.intercept(cpu, port, kind),
                0x3 => try sys.audio_devices[0].intercept(cpu, port, kind),
                0x4 => try sys.audio_devices[1].intercept(cpu, port, kind),
                0x5 => try sys.audio_devices[2].intercept(cpu, port, kind),
                0x6 => try sys.audio_devices[3].intercept(cpu, port, kind),
                0x8 => try sys.controller_device.intercept(cpu, port, kind),
                0x9 => try sys.mouse_device.intercept(cpu, port, kind),
                0xa => try sys.file_devices[0].intercept(cpu, port, kind),
                0xb => try sys.file_devices[1].intercept(cpu, port, kind),
                0xc => try sys.datetime_device.intercept(cpu, port, kind),

                else => {},
            }
        }
    };
}

pub const headless_intercepts = struct {
    pub const output = .{ 0xc028, 0x0300, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0xa260, 0xa260, 0x0000, 0x0000, 0x0000, 0x0000 };
    pub const input = .{ 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x07ff, 0x0000, 0x0000, 0x0000 };
};

pub const full_intercepts = struct {
    pub const output = .{ 0xff28, 0x0300, 0xc028, 0x8000, 0x8000, 0x8000, 0x8000, 0x0000, 0x0000, 0x0000, 0xa260, 0xa260, 0x0000, 0x0000, 0x0000, 0x0000 };
    pub const input = .{ 0x0000, 0x0000, 0x003c, 0x0014, 0x0014, 0x0014, 0x0014, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x07ff, 0x0000, 0x0000, 0x0000 };
};
