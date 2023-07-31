const Cpu = @import("uxn-core").Cpu;

const Screen = @import("Screen.zig");

const std = @import("std");
const logger = std.log.scoped(.uxn_varvara_system);

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
};

addr: u4,

debug_callback: ?*const fn (cpu: *Cpu, data: ?*anyopaque) void = null,
callback_data: ?*anyopaque = null,
additional_pages: ?[][Cpu.page_size]u8 = null,

exit_code: ?u8 = null,
colors: [4]Color = .{
    .{ .r = 0, .g = 0, .b = 0 },
    .{ .r = 0, .g = 0, .b = 0 },
    .{ .r = 0, .g = 0, .b = 0 },
    .{ .r = 0, .g = 0, .b = 0 },
},

pub const ports = struct {
    pub const catch_vector = 0x00;
    pub const expansion = 0x02;
    pub const metadata = 0x06;
    pub const red = 0x08;
    pub const green = 0x0a;
    pub const blue = 0x0c;
    pub const debug = 0x0e;
    pub const state = 0x0f;
};

fn split_rgb(r: u16, g: u16, b: u16, c: u2) Color {
    const sw = @as(u4, 3 - c) * 4;

    return Color{
        .r = @truncate((r >> sw) & 0xf | ((r >> sw) & 0xf) << 4),
        .g = @truncate((g >> sw) & 0xf | ((g >> sw) & 0xf) << 4),
        .b = @truncate((b >> sw) & 0xf | ((b >> sw) & 0xf) << 4),
    };
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
        ports.state => {
            dev.exit_code = cpu.device_mem[base | ports.state] & 0x7f;

            logger.debug("System exit requested (code = {?})", .{dev.exit_code});
        },

        ports.debug => {
            if (dev.debug_callback) |cb|
                cb(cpu, dev.callback_data)
            else
                logger.debug("Debug port triggered, but no callback is available", .{});
        },

        ports.expansion + 1 => {
            try dev.handle_expansion(cpu, cpu.load_device_mem(u16, base | ports.expansion));
        },

        ports.red + 1, ports.green + 1, ports.blue + 1 => {
            // Layout:
            //   R 0xABCD
            //   G 0xEFGH
            //   B 0xIJKL => 0xAEI 0xBFJ 0xCGK 0xDHL
            const r = cpu.load_device_mem(u16, base | ports.red);
            const g = cpu.load_device_mem(u16, base | ports.green);
            const b = cpu.load_device_mem(u16, base | ports.blue);

            for (0..4) |i|
                dev.colors[i] = split_rgb(r, g, b, @truncate(i));
        },

        else => {},
    }
}

pub fn handle_fault(dev: @This(), cpu: *Cpu, fault: Cpu.SystemFault) !void {
    const base = @as(u8, dev.addr) << 4;
    const catch_vector = cpu.load_device_mem(u16, base | ports.catch_vector);

    if (catch_vector > 0x0000 and Cpu.is_catchable(fault)) {
        // Clear stacks, push fault information
        cpu.wst.sp = 0;
        cpu.rst.sp = 0;

        cpu.wst.push(u16, cpu.pc) catch unreachable;
        cpu.wst.push(u8, cpu.mem[cpu.pc]) catch unreachable;
        cpu.wst.push(u8, @as(u8, switch (fault) {
            error.StackUnderflow => 0x01,
            error.StackOverflow => 0x02,
            error.DivisionByZero => 0x03,

            else => unreachable,
        })) catch unreachable;

        cpu.evaluate_vector(catch_vector) catch |new_fault|
            try dev.handle_fault(cpu, new_fault);
    } else {
        return fault;
    }
}

fn select_memory_page(dev: @This(), cpu: *Cpu, page: u16) ?*[Cpu.page_size]u8 {
    if (page == 0x0000) {
        return cpu.mem;
    } else if (dev.additional_pages) |page_table| {
        if (page_table.len < page) {
            return &page_table[page];
        }
    }

    return null;
}

pub fn handle_expansion(dev: @This(), cpu: *Cpu, operation: u16) !void {
    switch (cpu.mem[operation]) {
        // copy
        0x01 => {
            // [ operation:u8 | len:u16 | srcpg:u16 | src:u16 | dstpg:u16 | dst:u16]
            const dat_len = cpu.load_mem(u16, operation + 1);

            const src_pge = cpu.load_mem(u16, operation + 3);
            const src_ptr = cpu.load_mem(u16, operation + 5);

            const dst_pge = cpu.load_mem(u16, operation + 7);
            const dst_ptr = cpu.load_mem(u16, operation + 9);

            logger.debug("Expansion: Request move of #{x} bytes from {x:0>4}:{x:0>4} to {x:0>4}:{x:0>4}", .{
                dat_len,
                src_pge,
                src_ptr,
                dst_pge,
                dst_ptr,
            });

            const src = dev.select_memory_page(cpu, src_pge) orelse {
                logger.warn("Expansion: Invalid source page {x:0>4}:{x:0>4}", .{ src_pge, src_ptr });

                return error.BadExpansion;
            };

            const dst = dev.select_memory_page(cpu, dst_pge) orelse {
                logger.warn("Expansion: Invalid destination page {x:0>4}:{x:0>4}", .{ dst_pge, dst_ptr });

                return error.BadExpansion;
            };

            const src_slice = src[src_ptr..src_ptr +| dat_len];
            var dst_slice = dst[dst_ptr..dst_ptr +| dat_len];

            if (src_slice.len != dst_slice.len) {
                logger.warn("Expansion: Source and destination lengths do not match due to " ++
                    "page boundary: {x:0>4}:{x:0>4} -> {x:0>4}:{x:0>4} ({} -> {})", .{
                    src_pge,       src_ptr,
                    dst_pge,       dst_ptr,
                    src_slice.len, dst_slice.len,
                });

                return error.BadExpansion;
            }

            @memcpy(dst_slice, src_slice);
        },

        else => {},
    }
}
