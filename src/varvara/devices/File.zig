const Cpu = @import("uxn-core").Cpu;
const std = @import("std");

const Directory = struct {
    root: std.fs.IterableDir,
    iter: std.fs.IterableDir.Iterator,
    init: bool,
};

const Target = union(enum) {
    file: std.fs.File,
    dir: Directory,
};

addr: u4,

file: ?Target = null,
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

pub fn cleanup(dev: *@This()) void {
    if (dev.file) |*open_file| switch (open_file.*) {
        .file => |f| {
            f.close();
        },

        .dir => |*d| {
            d.root.close();
        },
    };

    dev.file = null;
}

fn open_readable(path: []const u8) !Target {
    if (std.fs.cwd().openIterableDir(path, .{})) |dir| {
        return Target{
            .dir = .{
                .root = dir,
                .iter = dir.iterate(),
                .init = true,
            },
        };
    } else |e| {
        if (e == error.NotDir) {
            return Target{
                .file = try std.fs.cwd().openFile(path, .{}),
            };
        } else {
            return e;
        }
    }
}

fn open_writable(path: []const u8, truncate: bool) !Target {
    return Target{
        .file = try std.fs.cwd().createFile(path, .{ .truncate = truncate }),
    };
}

fn make_dir_entry(dir: *Directory, slice: []u8) !u16 {
    var fbw = std.io.FixedBufferStream([]u8){
        .buffer = slice,
        .pos = 0,
    };

    if (dir.init) {
        try fbw.writer().print("---- ../\n", .{});

        dir.init = false;
    } else if (dir.iter.next() catch null) |entry| {
        var stat = try dir.root.dir.statFile(entry.name);

        try if (entry.kind != .directory)
            if (stat.size > 0xffff)
                fbw.writer().print("????", .{})
            else
                fbw.writer().print("{x:0>4}", .{stat.size})
        else
            fbw.writer().print("----", .{});

        try fbw.writer().print(" {s}", .{entry.name});

        if (entry.kind == .directory)
            try fbw.writer().print("/", .{});

        try fbw.writer().print("\n", .{});
    }

    @memset(slice[fbw.getPos() catch unreachable ..], 0x00);

    return @as(u16, @truncate(fbw.getPos() catch unreachable));
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
        },

        ports.write + 1 => {
            const data_ptr = cpu.load_device_mem(u16, base | port - 1);
            const len = cpu.load_device_mem(u16, base | ports.length);

            const name_ptr = cpu.load_device_mem(u16, base | ports.name);
            const name_slice = std.mem.sliceTo(cpu.mem[name_ptr..], 0x00);

            const truncate = cpu.load_device_mem(u16, base | ports.append) == 0x00;

            var t = dev.file orelse open_writable(name_slice, truncate) catch {
                return cpu.store_device_mem(u16, base | ports.success, 0x0000);
            };

            var f = switch (t) {
                .file => |f| f,
                .dir => return,
            };

            var writer = f.writer();

            cpu.store_device_mem(
                u16,
                base | ports.success,

                if (writer.write(cpu.mem[data_ptr .. data_ptr + len])) |n|
                    @as(u16, @truncate(n))
                else |_|
                    0x0000,
            );

            if (dev.file == null)
                dev.file = t;
        },

        ports.read + 1 => {
            const data_ptr = cpu.load_device_mem(u16, base | port - 1);
            const len = cpu.load_device_mem(u16, base | ports.length);
            const data_slice = cpu.mem[data_ptr..data_ptr +| len];

            const name_ptr = cpu.load_device_mem(u16, base | ports.name);
            const name_slice = std.mem.sliceTo(cpu.mem[name_ptr..], 0x00);

            var t = dev.file orelse open_readable(name_slice) catch {
                return cpu.store_device_mem(u16, base | ports.success, 0x0000);
            };

            switch (t) {
                .file => |f| {
                    var reader = f.reader();

                    cpu.store_device_mem(
                        u16,
                        base | ports.success,

                        if (reader.read(data_slice)) |n|
                            @as(u16, @truncate(n))
                        else |_|
                            0x0000,
                    );
                },

                .dir => |*d| {
                    const n = make_dir_entry(d, data_slice) catch 0x0000;

                    cpu.store_device_mem(u16, base | ports.success, n);
                },
            }

            dev.file = t;
        },

        ports.delete => {
            const name_ptr = cpu.load_device_mem(u16, base | ports.name);
            const name_slice = std.mem.sliceTo(cpu.mem[name_ptr..], 0x00);

            std.fs.cwd().deleteFile(name_slice) catch {
                cpu.store_device_mem(u16, base | ports.success, 0x0000);
            };
        },

        else => {},
    }
}
