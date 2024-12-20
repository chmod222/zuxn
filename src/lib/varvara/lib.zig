const std = @import("std");
const fs = std.fs;
const mem = std.mem;

const uxn = @import("uxn-core");

const logger = std.log.scoped(.uxn_varvara);

pub const system = @import("devices/system.zig");
pub const console = @import("devices/console.zig");
pub const screen = @import("devices/screen.zig");
pub const audio = @import("devices/audio.zig");
pub const controller = @import("devices/controller.zig");
pub const mouse = @import("devices/mouse.zig");
pub const file = @import("devices/file.zig");
pub const datetime = @import("devices/datetime.zig");

pub const pages = 4;

pub fn VarvaraSystem(comptime StdoutWriter: type, comptime StderrWriter: type) type {
    return struct {
        stderr: StderrWriter,
        stdout: StdoutWriter,

        allocator: std.mem.Allocator,
        page_table: ?[][uxn.Cpu.page_size]u8 = null,
        sandbox_base: ?fs.Dir = null,

        system_device: system.System,
        console_device: console.Console,
        screen_device: screen.Screen,
        audio_devices: [4]audio.Audio,
        controller_device: controller.Controller,
        mouse_device: mouse.Mouse,
        file_devices: [2]file.File,
        datetime_device: datetime.Datetime,

        pub fn init(
            allocator: std.mem.Allocator,
            stdout: StdoutWriter,
            stderr: StderrWriter,
        ) !@This() {
            const page_table = try allocator.alloc([uxn.Cpu.page_size]u8, pages);

            var sys: @This() = .{
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

            try sys.screen_device.initializeGraphics();

            return sys;
        }

        pub fn deinit(sys: *@This()) void {
            sys.screen_device.cleanupGraphics();

            for (&sys.file_devices) |*f|
                f.cleanup();

            if (sys.system_device.additional_pages) |page_table|
                sys.allocator.free(page_table);
        }

        fn filterFileAccess(dev: *file.File, data: ?*anyopaque, path: []const u8, mode: file.File.Mode) bool {
            _ = dev;

            var buffer_path: [256]u8 = undefined;
            var buffer_self: [256]u8 = undefined;

            const ptr: *const @This() = @ptrCast(@alignCast(data));

            const file_path = ptr.sandbox_base.?.realpath(path, &buffer_path) catch return false;
            const self_path = ptr.sandbox_base.?.realpath(".", &buffer_self) catch return false;

            if (!mem.startsWith(u8, file_path, self_path)) {
                logger.warn("Preventing out-of-sandbox {s} access to {s}", .{ @tagName(mode), file_path });

                return false;
            } else {
                return true;
            }
        }

        pub fn sandboxFiles(sys: *@This(), base_dir: fs.Dir) bool {
            if (!@hasDecl(file.File, "setAccessFilter")) {
                return false;
            }

            sys.sandbox_base = base_dir;

            for (&sys.file_devices) |*fd| {
                fd.setAccessFilter(sys, filterFileAccess);
            }

            return true;
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

                    if (addr & 0xf >= system.ports.red and
                        addr & 0xf < system.ports.debug)
                    {
                        sys.screen_device.forceRedraw();
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
    pub const output = .{ 0xc038, 0x0300, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0xa260, 0xa260, 0x0000, 0x0000, 0x0000, 0x0000 };
    pub const input = .{ 0x0030, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x07ff, 0x0000, 0x0000, 0x0000 };
};

pub const full_intercepts = struct {
    pub const output = .{ 0xff38, 0x0300, 0xc028, 0x8000, 0x8000, 0x8000, 0x8000, 0x0000, 0x0000, 0x0000, 0xa260, 0xa260, 0x0000, 0x0000, 0x0000, 0x0000 };
    pub const input = .{ 0x0030, 0x0000, 0x003c, 0x0014, 0x0014, 0x0014, 0x0014, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x07ff, 0x0000, 0x0000, 0x0000 };
};
