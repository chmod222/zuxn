const Cpu = @import("uxn-core").Cpu;
const std = @import("std");

addr: u4,

active_file: ?AnyTarget = null,
mode: std.fs.File.OpenFlags = .{},

pub const ports = struct {
    pub const vector = 0x0;
    pub const success = 0x2;
    pub const stat = 0x4;
    pub const delete = 0x6;
    pub const append = 0x7;
    pub const name = 0x8;
    pub const length = 0xa;
    pub const read = 0xc;
    pub const write = 0xe;
};

const Directory = struct {
    root: std.fs.IterableDir,
    iter: std.fs.IterableDir.Iterator,

    cached_entry: ?std.fs.IterableDir.Entry = null,

    fn render_dir_entry(
        dir: *Directory,
        entry: std.fs.IterableDir.Entry,
        slice: []u8,
    ) !usize {
        var fbw = std.io.FixedBufferStream([]u8){
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

const File = struct {
    file: std.fs.File,
};

const AnyTarget = union(enum) {
    directory: Directory,
    file: File,

    fn read(self: *AnyTarget, buf: []u8) ?u16 {
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
                            return null;
                        }
                    }
                }

                @memset(buf[offset..], 0x00);

                return @truncate(offset);
            },

            .file => |*f| {
                return @truncate(f.file.readAll(buf) catch return null);
            },
        }

        return null;
    }

    fn write(self: *AnyTarget, buf: []const u8) ?u16 {
        return switch (self.*) {
            .file => |f| {
                return @truncate(f.file.write(buf) catch return null);
            },

            else => null,
        };
    }

    fn close(self: *AnyTarget) void {
        switch (self.*) {
            .directory => |*dir| dir.root.close(),
            .file => |*file| file.file.close(),
        }
    }
};

fn open_directory(path: []const u8) !Directory {
    const dir = try std.fs.cwd().openIterableDir(path, .{});

    return Directory{
        .root = dir,
        .iter = dir.iterate(),
    };
}

fn open_file(path: []const u8) !File {
    return File{
        .file = try std.fs.cwd().openFile(path, .{}),
    };
}

fn open_file_write(path: []const u8, truncate: bool) !File {
    return File{
        .file = try std.fs.cwd().createFile(path, .{ .truncate = truncate }),
    };
}

pub fn cleanup(dev: *@This()) void {
    if (dev.active_file) |*f| {
        f.close();
    }

    dev.active_file = null;
}

fn open_readable(path: []const u8) !AnyTarget {
    if (open_directory(path)) |dir| {
        return .{ .directory = dir };
    } else |err| {
        if (err == error.NotDir) {
            return .{ .file = try open_file(path) };
        }
    }

    return error.CannotOpen;
}

fn open_writable(path: []const u8, truncate: bool) !AnyTarget {
    return .{
        .file = try open_file_write(path, truncate),
    };
}

fn get_current_name_slice(dev: *@This(), cpu: *Cpu) []const u8 {
    const base = @as(u8, dev.addr) << 4;
    const name_ptr = cpu.load_device_mem(u16, base | ports.name);

    return std.mem.sliceTo(cpu.mem[name_ptr..], 0x00);
}

fn get_current_read_slice(dev: *@This(), cpu: *Cpu) []u8 {
    const base = @as(u8, dev.addr) << 4;

    const data_ptr: usize = cpu.load_device_mem(u16, base | ports.read);
    const len = cpu.load_device_mem(u16, base | ports.length);

    return cpu.mem[data_ptr..data_ptr +| len];
}

fn get_current_write_slice(dev: *@This(), cpu: *Cpu) []const u8 {
    const base = @as(u8, dev.addr) << 4;

    const data_ptr: usize = cpu.load_device_mem(u16, base | ports.write);
    const len = cpu.load_device_mem(u16, base | ports.length);

    return cpu.mem[data_ptr..data_ptr +| len];
}

pub fn intercept(
    dev: *@This(),
    cpu: *Cpu,
    port: u4,
    kind: Cpu.InterceptKind,
) !void {
    if (kind != .output)
        return;

    const base = @as(u8, dev.addr) << 4;

    switch (port) {
        ports.name + 1 => {
            // Close a previously opened file
            dev.cleanup();

            cpu.store_device_mem(u16, base | ports.success, 0x0001);
        },

        ports.write + 1 => {
            const truncate = cpu.load_device_mem(u16, base | ports.append) == 0x00;

            const name_slice = dev.get_current_name_slice(cpu);
            const data_slice = dev.get_current_write_slice(cpu);

            var t = dev.active_file orelse open_writable(name_slice, truncate) catch {
                return cpu.store_device_mem(u16, base | ports.success, 0x0000);
            };

            cpu.store_device_mem(u16, base | ports.success, t.write(data_slice) orelse 0);
            dev.active_file = t;
        },

        ports.read + 1 => {
            const data_slice = dev.get_current_read_slice(cpu);
            const name_slice = dev.get_current_name_slice(cpu);

            var t = dev.active_file orelse open_readable(name_slice) catch {
                return cpu.store_device_mem(u16, base | ports.success, 0x0000);
            };

            var r = t.read(data_slice) orelse 0;

            cpu.store_device_mem(u16, base | ports.success, r);
            dev.active_file = t;
        },

        ports.delete => {
            const name_slice = dev.get_current_name_slice(cpu);

            std.fs.cwd().deleteFile(name_slice) catch {};

            cpu.store_device_mem(u16, base | ports.success, 0x0001);
        },

        ports.stat + 1 => {
            cpu.store_device_mem(u16, base | ports.success, 0x0000);
        },

        else => {},
    }
}
