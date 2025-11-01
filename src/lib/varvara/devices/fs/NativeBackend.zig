pub const NativeBackend = @This();

const builtin = @import("builtin");
const std = @import("std");
const fs = std.fs;
const io = std.io;

// TOOD: readFile/writeFile more efficient buffering
const Opened = union(enum) {
    none,
    file: fs.File,
    directory: fs.Dir.Iterator,
};

open_file: Opened = .none,

pub fn deinit(bck: *NativeBackend) void {
    switch (bck.open_file) {
        .none => {},

        .file => |*file| {
            file.close();
        },

        .directory => |*dir| {
            dir.dir.close();
        },
    }

    bck.open_file = .none;
}

pub fn readFile(bck: *NativeBackend, path: []const u8, dest: []u8) !u16 {
    if (bck.open_file == .none) {
        if (fs.cwd().openDir(path, .{ .iterate = true })) |dir| {
            bck.open_file = .{ .directory = dir.iterate() };
        } else |e| {
            if (e == error.NotDir) {
                bck.open_file = .{
                    .file = try fs.cwd().openFile(path, .{}),
                };
            }
        }
    }

    const n: usize = r: switch (bck.open_file) {
        .file => |f| {
            var writer = f.readerStreaming(&.{});

            break :r try writer.interface.readSliceShort(dest);
        },

        .directory => |*d| {
            var writer = std.io.Writer.fixed(dest);

            if (d.next() catch null) |entry| {
                if (entry.kind != .directory) {
                    const file_size = if (comptime builtin.os.tag == .wasi) s: {
                        // Some problems with statFile not working under WASI
                        if (d.dir.openFile(entry.name, .{})) |f| {
                            defer f.close();

                            break :s f.getEndPos() catch 0x10000;
                        } else |_| {
                            break :s 0x10000;
                        }
                    } else (try d.dir.statFile(entry.name)).size;

                    try if (file_size > 0xffff)
                        writer.print("???? {s}\n", .{entry.name})
                    else
                        writer.print("{x:0>4} {s}\n", .{ file_size, entry.name });
                } else {
                    try writer.print("---- {s}/\n", .{entry.name});
                }

                writer.writeByte(0x00) catch {};

                break :r writer.end;
            } else {
                break :r 0;
            }
        },

        else => {
            break :r 0;
        },
    };

    return @truncate(n);
}

pub fn writeFile(
    bck: *NativeBackend,
    path: []const u8,
    src: []const u8,
    truncate: bool,
) !u16 {
    if (bck.open_file == .none) {
        bck.open_file = .{
            .file = try fs.cwd().createFile(path, .{ .truncate = truncate }),
        };
    }

    var writer = bck.open_file.file.writerStreaming(&.{});
    try writer.interface.writeAll(src);
    try writer.interface.flush();

    return @truncate(src.len);
}

pub fn deleteFile(bck: *NativeBackend, path: []const u8) !void {
    _ = bck;

    try fs.cwd().deleteFile(path);
}
