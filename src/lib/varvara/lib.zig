const std = @import("std");
const fs = std.fs;
const Io = std.Io;
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

pub const VarvaraDefault = struct {
    allocator: std.mem.Allocator,
    io: Io,
    page_table: ?[][uxn.Cpu.page_size]u8 = null,
    sandbox_base: ?Io.Dir = null,

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
        io: Io,
        env: *std.process.Environ.Map,
        stdout: *Io.Writer,
        stderr: *Io.Writer,
    ) !@This() {
        const page_table = try allocator.alloc([uxn.Cpu.page_size]u8, pages);

        var sys: @This() = .{
            .allocator = allocator,
            .io = io,
            .page_table = page_table,

            .system_device = .{
                .device = .init(0x0),
                .env = env,
                .additional_pages = page_table,
            },

            .console_device = .{
                .device = .init(0x1),
                .io = io,
                .stderr = stderr,
                .stdout = stdout,
            },

            .screen_device = .{
                .device = .init(0x2),
                .alloc = allocator,
            },

            .audio_devices = .{
                .{ .device = .init(0x3) },
                .{ .device = .init(0x4) },
                .{ .device = .init(0x5) },
                .{ .device = .init(0x6) },
            },
            .controller_device = .{ .device = .init(0x8) },
            .mouse_device = .{ .device = .init(0x9) },
            .file_devices = .{
                .{ .device = .init(0xa), .backend = file.File.defaultBackend(io) },
                .{ .device = .init(0xb), .backend = file.File.defaultBackend(io) },
            },
            .datetime_device = .{ .device = .init(0xc) },
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

    fn filterFileAccess(dev: *file.File, data: ?*anyopaque, path: []const u8, mode: file.Mode) bool {
        _ = dev;

        var buffer_path: [std.c.PATH_MAX]u8 = undefined;
        var buffer_self: [std.c.PATH_MAX]u8 = undefined;

        const ptr: *const @This() = @ptrCast(@alignCast(data));

        const file_path = ptr.sandbox_base.?.realPathFile(ptr.io, path, &buffer_path) catch |e| {
            logger.warn("Failed to realpath(\"{s}\"): {t}", .{path, e});

            return false;
        };

        const self_path = ptr.sandbox_base.?.realPathFile(ptr.io, ".", &buffer_self) catch |e| {
            logger.warn("Failed to realpath(\".\"): {t}", .{e});

            return false;
        };

        if (!mem.startsWith(u8, buffer_path[0..file_path], buffer_self[0..self_path])) {
            logger.warn("Preventing out-of-sandbox {s} access to {s}", .{ @tagName(mode), buffer_path[0..file_path] });

            return false;
        } else {
            return true;
        }
    }

    pub fn sandboxFiles(sys: *@This(), base_dir: Io.Dir) bool {
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

pub const headless_intercepts = struct {
    pub const output = .{ 0xc038, 0x8300, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0xa260, 0xa260, 0x0000, 0x0000, 0x0000, 0x0000 };
    pub const input = .{ 0x0030, 0x0060, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x07ff, 0x0000, 0x0000, 0x0000 };
};

pub const full_intercepts = struct {
    pub const output = .{ 0xff38, 0x8300, 0xc028, 0x8000, 0x8000, 0x8000, 0x8000, 0x0000, 0x0000, 0x0000, 0xa260, 0xa260, 0x0000, 0x0000, 0x0000, 0x0000 };
    pub const input = .{ 0x0030, 0x0060, 0x003c, 0x0014, 0x0014, 0x0014, 0x0014, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x07ff, 0x0000, 0x0000, 0x0000 };
};
