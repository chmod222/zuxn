const Cpu = @import("uxn-core").Cpu;

const std = @import("std");
const impl = @import("impl.zig");
const logger = std.log.scoped(.uxn_varvara_system);

/// Determine how a read or write across a page boundary should be treated.
const PageSplit = enum {
    /// Do not split the memory, truncate the operation instead. This is the default
    /// strategy specified by Varvara.
    truncate,

    /// Wrap the memory access back around on the same page, starting back from 0
    /// inside the page’s zero area.
    wrap,

    /// Treat the pages as the contiguous slice of memory that they are internally.
    contiguous,
};

const cross_boundary_behaviour = PageSplit.truncate;

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
};

pub const WellKnownMetadata = union(enum) {
    varvara_version: u16,
    app_icon: *const [144]u8,
    manifest: u16,
    muxn_api: u16,
};

pub const MetadataElement = struct {
    identifier: u8,
    value: u16,

    pub fn wellKnown(elem: *const MetadataElement, cpu: *Cpu) ?WellKnownMetadata {
        switch (elem.identifier) {
            0x56 => {
                return WellKnownMetadata{
                    .varvara_version = elem.value,
                };
            },

            0x83 => {
                const ptr = cpu.mem[elem.value..][0..144];

                return WellKnownMetadata{
                    .app_icon = @ptrCast(ptr.ptr),
                };
            },

            0xa0 => {
                return WellKnownMetadata{
                    .manifest = elem.value,
                };
            },

            0xf0 => {
                return WellKnownMetadata{
                    .muxn_api = elem.value,
                };
            },

            else => {
                return null;
            },
        }
    }
};

pub const MetadataIterator = struct {
    cpu: *Cpu,
    ptr: u16,
    remain: u8,

    pub fn next(iter: *MetadataIterator) ?MetadataElement {
        if (iter.remain == 0) {
            return null;
        }

        defer iter.remain -= 1;

        const ident = iter.cpu.loadMem(u8, iter.ptr);
        const value = iter.cpu.loadMem(u16, iter.ptr + 1);

        iter.ptr += 3;

        return MetadataElement{
            .identifier = ident,
            .value = value,
        };
    }
};

pub const Metadata = struct {
    version: u8,
    text: []const u8,
};

const CopyDirection = enum { left_to_right, right_to_left };

// Use manual looping instead of @memcpy and @memmove builtins with safety
// disabled.
const safe_copy = false;

/// The result of a page boundary crossing memory slicing when the possibily of splitting exists.
const SplitPageSlice = union(enum) {
    /// A single contiguous slice that either:
    ///   a. does not cross the boundary, or
    ///   b. was truncated, or
    ///   c. did cross a page boundary but the underlying memory is in fact
    ///      contiguous and can represent this.
    contiguous: []u8,

    /// A split slice consisting of the uppermost part of the origin page, and
    /// depending on mode:
    ///   a. the lowermost part of that same page (PageSplit.wrap)
    ///   b. the lowermost part of the next page (PageSplit.contiguous) if the
    ///      underlying memory representation cannot be treated as one contiguous
    ///      blob of memory.
    disjoint: struct { []u8, []u8 },

    fn initContiguous(slice: []u8) SplitPageSlice {
        return SplitPageSlice{ .contiguous = slice };
    }

    fn initDisjoint(slice0: []u8, slice1: []u8) SplitPageSlice {
        return SplitPageSlice{ .disjoint = .{ slice0, slice1 } };
    }

    fn fill(slice: SplitPageSlice, value: u8) void {
        switch (slice) {
            .contiguous => |c| {
                @memset(c, value);
            },

            .disjoint => |d| {
                @memset(d.@"0", value);
                @memset(d.@"1", value);
            },
        }
    }

    fn copyDisjoint(
        src0: []const u8,
        src1: []const u8,
        dst0: []u8,
        dst1: []u8,
        comptime dir: CopyDirection,
    ) void {
        const src_parts: [2][]const u8 = .{ src0, src1 };
        const dst_parts: [2][]u8 = .{ dst0, dst1 };

        if (dir == .left_to_right) {
            var si: usize = 0;
            var di: usize = 0;
            var so: usize = 0;
            var doff: usize = 0;

            while (si < src_parts.len and di < dst_parts.len) {
                const src = src_parts[si][so..];
                const dst = dst_parts[di][doff..];
                const n = @min(src.len, dst.len);

                if (safe_copy) {
                    for (0..n) |i| {
                        dst[i] = src[i];
                    }
                } else {
                    @setRuntimeSafety(false);
                    @memmove(dst[0..n], src[0..n]);
                }

                so += n;
                doff += n;

                if (so == src_parts[si].len) {
                    si += 1;
                    so = 0;
                }
                if (doff == dst_parts[di].len) {
                    di += 1;
                    doff = 0;
                }
            }
        } else {
            var si: usize = src_parts.len - 1;
            var di: usize = dst_parts.len - 1;

            var so: usize = src_parts[si].len;
            var doff: usize = dst_parts[di].len;

            while (true) {
                const n = @min(so, doff);
                const src = src_parts[si][so - n .. so];
                const dst = dst_parts[di][doff - n .. doff];

                if (safe_copy) {
                    for (0..n) |i| {
                        dst[n - i - 1] = src[n - i - 1];
                    }
                } else {
                    @setRuntimeSafety(false);
                    @memmove(dst, src);
                }

                so -= n;
                doff -= n;

                if (so == 0) {
                    if (si == 0)
                        break;

                    si -= 1;
                    so = src_parts[si].len;
                }
                if (doff == 0) {
                    if (di == 0)
                        break;

                    di -= 1;
                    doff = dst_parts[di].len;
                }
            }
        }
    }

    fn copyFrom(dst: SplitPageSlice, src: SplitPageSlice, comptime dir: CopyDirection) void {
        switch (src) {
            .contiguous => |src0| {
                switch (dst) {
                    .contiguous => |dst0| {
                        copyDisjoint(src0, &.{}, dst0, &.{}, dir);
                    },
                    .disjoint => |dstD| {
                        copyDisjoint(src0, &.{}, dstD.@"0", dstD.@"1", dir);
                    },
                }
            },
            .disjoint => |srcD| {
                switch (dst) {
                    .contiguous => |dst0| {
                        copyDisjoint(srcD.@"0", srcD.@"1", dst0, &.{}, dir);
                    },
                    .disjoint => |dstD| {
                        copyDisjoint(srcD.@"0", srcD.@"1", dstD.@"0", dstD.@"1", dir);
                    },
                }
            },
        }
    }
};

const SimplePageSlice = struct {
    slice: []u8,

    inline fn initContiguous(slice: []u8) SimplePageSlice {
        return SimplePageSlice{ .slice = slice };
    }

    inline fn fill(dst: SimplePageSlice, value: u8) void {
        @memset(dst.slice, value);
    }

    inline fn copyFrom(dst: SimplePageSlice, src: SimplePageSlice, comptime dir: CopyDirection) void {
        const n = @min(src.slice.len, dst.slice.len);

        if (dir == .left_to_right) {
            if (safe_copy) {
                for (0..n) |i| {
                    dst.slice[i] = src.slice[i];
                }
            } else {
                @setRuntimeSafety(false);
                @memmove(dst.slice[0..n], src.slice[0..n]);
            }
        } else {
            if (safe_copy) {
                for (0..n) |i| {
                    dst.slice[n - i - 1] = src.slice[n - i - 1];
                }
            } else {
                @setRuntimeSafety(false);
                @memmove(dst.slice[0..n], src.slice[0..n]);
            }
        }
    }
};

// If we can get away with it based on the strategy, comptime-select the simple page slice
// for the least amount of overhead.
const PageSlice = if (cross_boundary_behaviour == .truncate) SimplePageSlice else SplitPageSlice;

pub const ports = struct {
    pub const catch_vector = 0x00;
    pub const expansion = 0x02;
    pub const wsp = 0x04;
    pub const rsp = 0x05;
    pub const metadata = 0x06;
    pub const red = 0x08;
    pub const green = 0x0a;
    pub const blue = 0x0c;
    pub const debug = 0x0e;
    pub const state = 0x0f;
};

pub const System = struct {
    device: impl.DeviceMixin,

    debug_callback: ?*const fn (cpu: *Cpu, data: ?*anyopaque) void = null,
    callback_data: ?*anyopaque = null,

    exit_code: ?u8 = null,
    colors: [4]Color = .{
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
    },

    env: *std.process.Environ.Map,

    fn splitRgb(r: u16, g: u16, b: u16, c: u2) Color {
        const sw = @as(u4, 3 - c) * 4;

        return Color{
            .r = @truncate((r >> sw) & 0xf | ((r >> sw) & 0xf) << 4),
            .g = @truncate((g >> sw) & 0xf | ((g >> sw) & 0xf) << 4),
            .b = @truncate((b >> sw) & 0xf | ((b >> sw) & 0xf) << 4),
        };
    }

    pub fn init(addr: u4, env: *std.process.Environ.Map) System {
        return System{
            .device = .init(addr),
            .env = env,
        };
    }

    pub fn intercept(
        sys: *System,
        cpu: *Cpu,
        port: u4,
        kind: Cpu.InterceptKind,
    ) void {
        if (kind == .input) {
            switch (port) {
                ports.wsp => sys.device.storePort(u8, cpu, ports.wsp, cpu.wst.sp),
                ports.rsp => sys.device.storePort(u8, cpu, ports.rsp, cpu.rst.sp),

                else => {},
            }
        } else {
            switch (port) {
                ports.state => {
                    sys.exit_code = switch (sys.device.loadPort(u8, cpu, ports.state)) {
                        0 => null,
                        else => |c| c & 0x7f,
                    };

                    if (std.log.logEnabled(.debug, .uxn_varvara_system)) {
                        if (sys.exit_code) |c| {
                            logger.debug("System exit requested (code = {}; {s})", .{ c, if (c > 0) "error" else "success" });
                        } else {
                            logger.debug("System reverted exit code", .{});
                        }
                    }
                },

                ports.wsp => cpu.wst.sp = sys.device.loadPort(u8, cpu, ports.wsp),
                ports.rsp => cpu.rst.sp = sys.device.loadPort(u8, cpu, ports.rsp),

                ports.debug => {
                    if (sys.debug_callback) |cb|
                        cb(cpu, sys.callback_data)
                    else
                        logger.debug("Debug port triggered, but no callback is available", .{});
                },

                ports.expansion + 1 => {
                    sys.handleExpansion(cpu, sys.device.loadPort(u16, cpu, ports.expansion));
                },

                ports.red + 1, ports.green + 1, ports.blue + 1 => {
                    // Layout:
                    //   R 0xABCD
                    //   G 0xEFGH
                    //   B 0xIJKL => 0xAEI 0xBFJ 0xCGK 0xDHL
                    const r = sys.device.loadPort(u16, cpu, ports.red);
                    const g = sys.device.loadPort(u16, cpu, ports.green);
                    const b = sys.device.loadPort(u16, cpu, ports.blue);

                    for (0..4) |i|
                        sys.colors[i] = splitRgb(r, g, b, @truncate(i));
                },

                else => {},
            }
        }
    }

    pub fn fetchMetadata(sys: *System, cpu: *Cpu) ?struct { Metadata, MetadataIterator } {
        var ptr = sys.device.loadPort(u16, cpu, ports.metadata);

        if (ptr == 0x0000) {
            return null;
        }

        const version = cpu.loadMem(u8, ptr);
        ptr += 1;

        const text = std.mem.sliceTo(cpu.mem[ptr..], 0);
        ptr += @as(u16, @truncate(text.len)) + 1;

        const fields = cpu.loadMem(u8, ptr);

        ptr += 1;

        return .{
            Metadata{
                .version = version,
                .text = text,
            },
            MetadataIterator{
                .cpu = cpu,
                .ptr = ptr,
                .remain = fields,
            },
        };
    }

    fn selectMemoryPage(cpu: *Cpu, page: u16) ?*[Cpu.page_size]u8 {
        if (page >= cpu.pages.len) {
            return null;
        }

        return &cpu.pages[page];
    }

    fn crossesBoundary(offset: u16, len: u16) bool {
        return @as(usize, offset) + len >= Cpu.page_size;
    }

    fn getPageSlice(cpu: *Cpu, page: u16, offset: u16, len: u16) ?PageSlice {
        const src = selectMemoryPage(cpu, page) orelse {
            return null;
        };

        if (!crossesBoundary(offset, len)) {
            @branchHint(.likely);
            return .initContiguous(src[offset .. offset + len]);
        } else if (cross_boundary_behaviour == .truncate) {
            return .initContiguous(src[offset..]);
        } else if (cross_boundary_behaviour == .wrap) {
            return .initDisjoint(src[offset..Cpu.page_size], src[0 .. (@as(usize, offset) + len) - Cpu.page_size]);
        } else if (cross_boundary_behaviour == .contiguous) {
            const src_next = selectMemoryPage(cpu, page + 1) orelse {
                return null;
            };

            // Shortcut if the pages are just artificially split
            if (src.ptr + Cpu.page_size == src_next.ptr) {
                return .initContiguous(src.ptr[offset .. @as(usize, offset) + len]);
            } else {
                return .initDisjoint(src[offset..], src_next[0 .. (@as(usize, offset) + len) - Cpu.page_size]);
            }
        }
    }

    fn handleExpansion(sys: *System, cpu: *Cpu, operation: u16) void {
        switch (cpu.mem[operation]) {
            0x00 => {
                // fill [ operation:u8 | len:u16 | srcpg:u16 | src:u16 | value ]
                const len = cpu.loadMem(u16, operation + 1);
                const page = cpu.loadMem(u16, operation + 3);
                const offset = cpu.loadMem(u16, operation + 5);
                const value = cpu.loadMem(u8, operation + 7);

                logger.debug("Expansion: Request fill of #{x} bytes (#{x:0>2}) at {x:0>4}:{x:0>4}", .{
                    len,
                    value,
                    page,
                    offset,
                });

                const dst = getPageSlice(cpu, page, offset, len) orelse {
                    logger.debug("Expansion: Invalid source page {x:0>4}:{x:0>4}", .{ page, offset });

                    return;
                };

                dst.fill(value);
            },

            0x01, 0x02 => {
                // cpyl, copyr [ operation:u8 | len:u16 | srcpg:u16 | src:u16 | dstpg:u16 | dst:u16]

                const len = cpu.loadMem(u16, operation + 1);

                const src_page = cpu.loadMem(u16, operation + 3);
                const src_offset = cpu.loadMem(u16, operation + 5);

                const dst_page = cpu.loadMem(u16, operation + 7);
                const dst_offset = cpu.loadMem(u16, operation + 9);

                logger.debug("Expansion: Request move of #{x} bytes from {x:0>4}:{x:0>4} to {x:0>4}:{x:0>4}", .{
                    len,
                    src_page,
                    src_offset,
                    dst_page,
                    dst_offset,
                });

                const src = getPageSlice(cpu, src_page, src_offset, len) orelse {
                    logger.debug("Expansion: Invalid source page {x:0>4}:{x:0>4}", .{ src_page, src_offset });

                    return;
                };

                const dst = getPageSlice(cpu, dst_page, dst_offset, len) orelse {
                    logger.debug("Expansion: Invalid destination page {x:0>4}:{x:0>4}", .{ dst_page, dst_offset });

                    return;
                };

                if (cpu.mem[operation] == 0x01) {
                    // memcpy
                    dst.copyFrom(src, .left_to_right);
                } else {
                    // memmove
                    dst.copyFrom(src, .right_to_left);
                }
            },

            // Let's use >0x80 for our own things until the reference implementation assigns them values
            0x80 => {
                // Retrieve environment variable

                // [ operation:u8 | name:u16 | dest:u16 | len:u16]
                // Retrieve the environment variable with the 0-terminated name referenced by "name" and store
                // its value (if any) into the memory pointed to by "dest" (of max. length "len")
                const name_ptr = cpu.loadMem(u16, operation + 1);

                const dest_ptr = cpu.loadMem(u16, operation + 3);
                const dest_len = cpu.loadMem(u16, operation + 5);

                const env_name = std.mem.sliceTo(cpu.mem[name_ptr..], 0);
                var dest = cpu.mem[dest_ptr .. dest_ptr + dest_len];

                logger.debug("Expansion: Fetch environment variable \"{s}\" (dest len = {})", .{ env_name, dest_len });

                const env = sys.env.get(env_name) orelse "";
                const cpy_len = @min(env.len, dest.len);

                if (cpy_len > 0) {
                    @memcpy(dest[0..cpy_len], env[0..cpy_len]);

                    if (dest.len > env.len)
                        dest[cpy_len] = 0x00
                    else
                        dest[cpy_len - 1] = 0x00;
                }
            },

            else => {},
        }
    }
};
