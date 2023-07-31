const std = @import("std");
const fs = std.fs;
const io = std.io;

const Directory = struct {
    root: fs.IterableDir,
    iter: fs.IterableDir.Iterator,

    cached_entry: ?fs.IterableDir.Entry = null,

    fn render_dir_entry(
        dir: *Directory,
        entry: fs.IterableDir.Entry,
        slice: []u8,
    ) !usize {
        var fbw = io.FixedBufferStream([]u8){
            .buffer = slice,
            .pos = 0,
        };

        var writer = fbw.writer();

        if (entry.kind != .directory) {
            var stat = try dir.root.dir.statFile(entry.name);

            try if (stat.size > 0xffff)
                writer.print("???? {s}\n", .{entry.name})
            else
                writer.print("{x:0>4} {s}\n", .{ stat.size, entry.name });
        } else {
            try writer.print("---- {s}/\n", .{entry.name});
        }

        return fbw.pos;
    }
};

pub fn Impl(comptime Self: type) type {
    return struct {
        pub const Wrapper = ImplWrapper;

        pub fn open_readable(dev: *Self, path: []const u8) !Wrapper {
            _ = dev;

            if (fs.cwd().openIterableDir(path, .{})) |dir| {
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

        pub fn open_writable(dev: *Self, path: []const u8, truncate: bool) !Wrapper {
            _ = dev;

            return .{
                .file = try fs.cwd().createFile(path, .{ .truncate = truncate }),
            };
        }

        pub fn delete_file(dev: *Self, path: []const u8) !void {
            _ = dev;

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
                    offset += dir.render_dir_entry(entry, buf[offset..]) catch 0;

                    dir.cached_entry = null;
                }

                while (dir.iter.next() catch null) |entry| {
                    if (dir.render_dir_entry(entry, buf[offset..])) |written| {
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
