const builtin = @import("builtin");
const std = @import("std");
const fs = std.fs;
const io = std.io;

const Directory = struct {
    root: fs.Dir,
    iter: fs.Dir.Iterator,

    cached_entry: ?fs.Dir.Entry = null,

    fn renderDirEntry(
        dir: *Directory,
        entry: fs.Dir.Entry,
        slice: []u8,
    ) !usize {
        var fbw = io.FixedBufferStream([]u8){
            .buffer = slice,
            .pos = 0,
        };

        var writer = fbw.writer();

        if (entry.kind != .directory) {
            const file_size = if (comptime builtin.os.tag == .wasi) s: {
                // Some problems with statFile not working under WASI
                if (dir.root.dir.openFile(entry.name, .{})) |f| {
                    defer f.close();

                    break :s f.getEndPos() catch 0x10000;
                } else |_| {
                    break :s 0x10000;
                }
            } else (try dir.root.statFile(entry.name)).size;

            try if (file_size > 0xffff)
                writer.print("???? {s}\n", .{entry.name})
            else
                writer.print("{x:0>4} {s}\n", .{ file_size, entry.name });
        } else {
            try writer.print("---- {s}/\n", .{entry.name});
        }

        return fbw.pos;
    }
};

pub fn Impl(comptime Self: type) type {
    return struct {
        pub const Mode = enum {
            read,
            write,
            append,
            delete,
        };

        access_filter: ?*const fn (
            dev: *Self,
            data: ?*anyopaque,
            path: []const u8,
            access_type: Mode,
        ) bool = null,

        access_filter_arg: ?*anyopaque = null,

        pub const Wrapper = ImplWrapper;

        pub fn openReadable(dev: *Self, path: []const u8) !Wrapper {
            if (dev.impl.access_filter) |filter| {
                if (!filter(dev, dev.impl.access_filter_arg, path, .read))
                    return error.Sandboxed;
            }

            if (fs.cwd().openDir(path, .{ .iterate = true })) |dir| {
                return .{
                    .directory = .{
                        .root = dir,
                        .iter = dir.iterate(),
                    },
                };
            } else |err| {
                if (err == error.NotDir) {
                    return .{
                        .file = try fs.cwd().openFile(path, .{}),
                    };
                }
            }

            return error.CannotOpen;
        }

        pub fn setAccessFilter(
            dev: *Self,
            context: anytype,
            filter_fun: *const fn (
                dev: *Self,
                data: ?*anyopaque,
                path: []const u8,
                access_type: Mode,
            ) bool,
        ) void {
            dev.impl.access_filter = filter_fun;
            dev.impl.access_filter_arg = context;
        }

        pub fn openWritable(dev: *Self, path: []const u8, truncate: bool) !Wrapper {
            if (dev.impl.access_filter) |filter| {
                if (!filter(dev, dev.impl.access_filter_arg, path, if (truncate) .write else .append))
                    return error.Sandboxed;
            }

            return .{
                .file = try fs.cwd().createFile(path, .{ .truncate = truncate }),
            };
        }

        pub fn deleteFile(dev: *Self, path: []const u8) !void {
            if (dev.impl.access_filter) |filter| {
                if (!filter(dev, dev.impl.access_filter_arg, path, .delete))
                    return error.Sandboxed;
            }

            try fs.cwd().deleteFile(path);
        }
    };
}

pub const ImplWrapper = union(enum) {
    directory: Directory,
    file: fs.File,

    pub fn read(self: *@This(), buf: []u8) !u16 {
        switch (self.*) {
            .directory => |*dir| {
                var offset: usize = 0;

                if (dir.cached_entry) |entry| {
                    offset += dir.renderDirEntry(entry, buf[offset..]) catch 0;

                    dir.cached_entry = null;
                }

                while (dir.iter.next() catch null) |entry| {
                    if (dir.renderDirEntry(entry, buf[offset..])) |written| {
                        offset += written;
                    } else |err| {
                        if (err == error.NoSpaceLeft) {
                            // If we cannot write the current entry, we rember it for the next call.
                            dir.cached_entry = entry;

                            break;
                        } else {
                            return err;
                        }
                    }
                }

                @memset(buf[offset..], 0x00);

                return @truncate(offset);
            },

            .file => |*f| {
                return @truncate(try f.readAll(buf));
            },
        }
    }

    pub fn write(self: *@This(), buf: []const u8) !u16 {
        return switch (self.*) {
            .file => |f| {
                return @truncate(try f.write(buf));
            },

            else => error.NotImplemented,
        };
    }

    pub fn close(self: *@This()) void {
        switch (self.*) {
            .directory => |*dir| dir.root.close(),
            .file => |*file| file.close(),
        }
    }
};
