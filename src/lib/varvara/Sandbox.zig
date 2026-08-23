const Sandbox = @This();

const std = @import("std");
const mem = std.mem;
const Io = std.Io;

const file = @import("devices/file.zig");
const Varvara = @import("root").Varvara;

const logger = std.log.scoped(.uxn_varvara_sandbox);

io: Io,
base: Io.Dir,

pub fn init(io: Io, sandbox_dir: Io.Dir) Sandbox {
    return Sandbox{
        .io = io,
        .base = sandbox_dir,
    };
}

pub fn filterFileAccess(dev: *file.File, data: ?*anyopaque, path: []const u8, mode: file.Mode) bool {
    _ = dev;

    var buffer_path: [std.c.PATH_MAX]u8 = undefined;
    var buffer_self: [std.c.PATH_MAX]u8 = undefined;

    const ptr: *const Sandbox = @ptrCast(@alignCast(data));

    const file_path = ptr.base.realPathFile(ptr.io, path, &buffer_path) catch |e| {
        logger.warn("Failed to realpath(\"{s}\"): {t}", .{ path, e });

        return false;
    };

    const self_path = ptr.base.realPathFile(ptr.io, ".", &buffer_self) catch |e| {
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

pub fn install(box: *const Sandbox, file_dev: *file.File) error{AccessFilterNotSupported}!void {
    if (!@hasDecl(file.File, "setAccessFilter")) {
        return error.AccessFilterNotSupported;
    }

    file_dev.setAccessFilter(@constCast(box), filterFileAccess);
}
