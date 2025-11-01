const Cpu = @import("uxn-core").Cpu;

const builtin = @import("builtin");
const impl = @import("impl.zig");
const std = @import("std");
const logger = std.log.scoped(.uxn_varvara_file);

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

pub const Mode = enum {
    read,
    write,
    append,
    delete,
};

pub const AccessFilterFn = fn (*File, ?*anyopaque, []const u8, Mode) bool;

pub const File = struct {
    device: impl.DeviceMixin,
    backend: if (builtin.target.os.tag != .freestanding)
        @import("fs/NativeBackend.zig")
    else
        @import("fs/NoopBackend.zig") = .{},

    access_filter: *const AccessFilterFn = &File.permitAllFilter,
    access_filter_arg: ?*anyopaque = null,

    pub fn cleanup(file: *File) void {
        file.backend.deinit();

        logger.debug("[File@{x}] Cleaning up", .{
            file.device.addr,
        });
    }

    fn permitAllFilter(_: *File, _: ?*anyopaque, _: []const u8, _: Mode) bool {
        return true;
    }

    pub fn setAccessFilter(
        file: *File,
        context: *anyopaque,
        filter_fun: *const AccessFilterFn,
    ) void {
        file.access_filter = filter_fun;
        file.access_filter_arg = context;
    }

    fn getPortSlice(file: *@This(), cpu: *Cpu, comptime port: comptime_int) []u8 {
        const ptr: usize = file.device.loadPort(u16, cpu, port);

        return if (port == ports.name)
            std.mem.sliceTo(cpu.mem[ptr..], 0x00)
        else
            return cpu.mem[ptr..ptr +| file.device.loadPort(u16, cpu, ports.length)];
    }

    pub fn intercept(
        file: *File,
        cpu: *Cpu,
        port: u4,
        kind: Cpu.InterceptKind,
    ) !void {
        if (kind != .output)
            return;

        switch (port) {
            ports.name + 1 => {
                // Close a previously opened file
                file.backend.deinit();
                file.device.storePort(u16, cpu, ports.success, 0x0001);
            },

            ports.write + 1 => {
                const truncate = file.device.loadPort(u8, cpu, ports.append) == 0x00;

                const name_slice = file.getPortSlice(cpu, ports.name);
                const data_slice = file.getPortSlice(cpu, ports.write);

                const res: u16 = if (!file.access_filter(file, file.access_filter_arg, name_slice, .write)) r: {
                    logger.debug("[File@{x}] Denying sandboxed write to {s}", .{ file.device.addr, name_slice });

                    break :r 0x0000;
                } else if (file.backend.writeFile(name_slice, data_slice, truncate)) |n| r: {
                    logger.debug("[File@{x}] Wrote {} bytes", .{ file.device.addr, n });

                    break :r n;
                } else |err| r: {
                    logger.debug("[File@{x}] Failed to write data: {}", .{ file.device.addr, err });

                    break :r 0x0000;
                };

                file.device.storePort(u16, cpu, ports.success, res);
            },

            ports.read + 1 => {
                const name_slice = file.getPortSlice(cpu, ports.name);
                const data_slice = file.getPortSlice(cpu, ports.read);

                const res: u16 = if (!file.access_filter(file, file.access_filter_arg, name_slice, .read)) r: {
                    logger.debug("[File@{x}] Denying sandboxed read to {s}", .{ file.device.addr, name_slice });

                    break :r 0x0000;
                } else if (file.backend.readFile(name_slice, data_slice)) |n| r: {
                    logger.debug("[File@{x}] Read {} bytes", .{ file.device.addr, n });

                    break :r n;
                } else |err| r: {
                    logger.debug("[File@{x}] Failed to read data: {}", .{ file.device.addr, err });

                    break :r 0x0000;
                };

                file.device.storePort(u16, cpu, ports.success, res);
            },

            ports.delete => {
                const name_slice = file.getPortSlice(cpu, ports.name);

                const res: u16 = if (!file.access_filter(file, file.access_filter_arg, name_slice, .delete)) r: {
                    logger.debug("[File@{x}] Denying sandboxed delete of {s}", .{ file.device.addr, name_slice });

                    break :r 0x0000;
                } else if (file.backend.deleteFile(name_slice)) |_| r: {
                    logger.debug("[File@{x}] Deleted \"{s}\"", .{ file.device.addr, name_slice });

                    break :r 0x0000;
                } else |err| r: {
                    logger.debug("[File@{x}] Failed deleting \"{s}\": {}", .{ file.device.addr, name_slice, err });

                    break :r 0x0000;
                };

                file.device.storePort(u16, cpu, ports.success, res);
            },

            ports.stat + 1 => {
                const name_slice = file.getPortSlice(cpu, ports.name);

                logger.warn("[File@{x}] Called stat on \"{s}\"; not implemented", .{ file.device.addr, name_slice });

                file.device.storePort(u16, cpu, ports.success, 0x0000);
            },

            else => {},
        }
    }
};
