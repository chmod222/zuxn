const std = @import("std");

pub const System = @import("devices/System.zig");
pub const Console = @import("devices/Console.zig");
pub const Screen = @import("devices/Screen.zig");
pub const Audio = @import("devices/Audio.zig");
pub const Controller = @import("devices/Controller.zig");
pub const Mouse = @import("devices/Mouse.zig");
pub const File = @import("devices/File.zig");
pub const Datetime = @import("devices/Datetime.zig");

pub const VarvaraSystem = struct {
    system_device: System,
    console_device: Console,
    screen_device: Screen,
    audio_devices: [4]Audio,
    controller_device: Controller,
    mouse_device: Mouse,
    file_devices: [2]File,
    datetime_device: Datetime,

    pub fn init(allocator: std.mem.Allocator) !VarvaraSystem {
        var system: VarvaraSystem = .{
            .system_device = .{ .addr = 0x0 },
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

    pub fn deinit(sys: *VarvaraSystem) void {
        sys.screen_device.cleanup_graphics();

        for (&sys.file_devices) |*f|
            f.cleanup();
    }
};

pub const headless_intercepts = struct {
    pub const output = .{ 0xc028, 0x0300, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0xa260, 0xa260, 0x0000, 0x0000, 0x0000, 0x0000 };
    pub const input = .{ 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x07ff, 0x0000, 0x0000, 0x0000 };
};

pub const full_intercepts = struct {
    pub const output = .{ 0xff28, 0x0300, 0xc028, 0x8000, 0x8000, 0x8000, 0x8000, 0x0000, 0x0000, 0x0000, 0xa260, 0xa260, 0x0000, 0x0000, 0x0000, 0x0000 };
    pub const input = .{ 0x0000, 0x0000, 0x003c, 0x0014, 0x0014, 0x0014, 0x0014, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x07ff, 0x0000, 0x0000, 0x0000 };
};
