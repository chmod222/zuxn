const Cpu = @import("uxn-core").Cpu;

const builtin = @import("builtin");
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

pub const File = struct {
    const Impl = if (builtin.target.os.tag != .freestanding)
        @import("fs/default.zig").Impl(@This())
    else
        @import("fs/noop.zig").Impl(@This());

    addr: u4,
    active_file: ?Impl.Wrapper = null,
    impl: Impl = .{},

    pub usingnamespace @import("impl.zig").DeviceMixin(@This());
    pub usingnamespace Impl;

    pub fn cleanup(dev: *@This()) void {
        if (dev.active_file) |*f| {
            f.close();

            logger.debug("[File@{x}] Closed previousely open target", .{
                dev.addr,
            });
        }

        dev.active_file = null;
    }

    fn get_port_slice(dev: *@This(), cpu: *Cpu, comptime port: comptime_int) []u8 {
        const ptr: usize = dev.load_port(u16, cpu, port);

        return if (port == ports.name)
            std.mem.sliceTo(cpu.mem[ptr..], 0x00)
        else
            return cpu.mem[ptr..ptr +| dev.load_port(u16, cpu, ports.length)];
    }

    pub fn intercept(
        dev: *@This(),
        cpu: *Cpu,
        port: u4,
        kind: Cpu.InterceptKind,
    ) !void {
        if (kind != .output)
            return;

        switch (port) {
            ports.name + 1 => {
                // Close a previously opened file
                dev.cleanup();
                dev.store_port(u16, cpu, ports.success, 0x0001);
            },

            ports.write + 1 => {
                const truncate = dev.load_port(u8, cpu, ports.append) == 0x00;

                const name_slice = dev.get_port_slice(cpu, ports.name);
                const data_slice = dev.get_port_slice(cpu, ports.write);

                var t = dev.active_file orelse dev.open_writable(name_slice, truncate) catch |err| {
                    logger.debug("[File@{x}] Failed opening \"{s}\" for {s} access: {}", .{
                        dev.addr,
                        name_slice,
                        if (truncate) "write" else "append",
                        err,
                    });

                    return dev.store_port(u16, cpu, ports.success, 0x0000);
                };

                if (dev.active_file == null) {
                    logger.debug("[File@{x}] Opened \"{s}\" for {s} access", .{
                        dev.addr,
                        name_slice,
                        if (truncate) "write" else "append",
                    });
                }

                const res: u16 = if (t.write(data_slice)) |n| r: {
                    logger.debug("[File@{x}] Wrote {} bytes", .{ dev.addr, n });

                    break :r n;
                } else |err| r: {
                    logger.debug("[File@{x}] Failed to write data: {}", .{ dev.addr, err });

                    break :r 0x0000;
                };

                dev.store_port(u16, cpu, ports.success, res);
                dev.active_file = t;
            },

            ports.read + 1 => {
                const name_slice = dev.get_port_slice(cpu, ports.name);
                const data_slice = dev.get_port_slice(cpu, ports.read);

                var t = dev.active_file orelse dev.open_readable(name_slice) catch |err| {
                    logger.debug("[File@{x}] Failed opening \"{s}\" for read access: {}", .{ dev.addr, name_slice, err });

                    return dev.store_port(u16, cpu, ports.success, 0x0000);
                };

                if (dev.active_file == null) {
                    logger.debug("[File@{x}] Opened \"{s}\" for read access", .{ dev.addr, name_slice });
                }

                const res: u16 = if (t.read(data_slice)) |n| r: {
                    logger.debug("[File@{x}] Read {} bytes", .{ dev.addr, n });

                    break :r n;
                } else |err| r: {
                    logger.debug("[File@{x}] Failed to read data: {}", .{ dev.addr, err });

                    break :r 0x0000;
                };

                dev.store_port(u16, cpu, ports.success, res);
                dev.active_file = t;
            },

            ports.delete => {
                const name_slice = dev.get_port_slice(cpu, ports.name);

                const res: u16 = if (dev.delete_file(name_slice)) r: {
                    logger.debug("[File@{x}] Deleted \"{s}\"", .{ dev.addr, name_slice });

                    break :r 0x0000;
                } else |err| r: {
                    logger.debug("[File@{x}] Failed deleting \"{s}\": {}", .{ dev.addr, name_slice, err });

                    break :r 0x0000;
                };

                dev.store_port(u16, cpu, ports.success, res);
            },

            ports.stat + 1 => {
                const name_slice = dev.get_port_slice(cpu, ports.name);

                logger.warn("[File@{x}] Called stat on \"{s}\"; not implemented", .{ dev.addr, name_slice });

                dev.store_port(u16, cpu, ports.success, 0x0000);
            },

            else => {},
        }
    }
};
