const builtin = @import("builtin");
const std = @import("std");

const uxn_asm = @import("uxn-asm");

pub const is_wasm = builtin.target.cpu.arch == .wasm32;
pub const is_freestanding = builtin.target.os.tag == .freestanding;

pub const alloc = if (is_wasm)
    std.heap.wasm_allocator
else
    std.heap.c_allocator;

const ReasonCode = enum(c_int) {
    ok = 0,
    out_of_memory,
    invalid_argument,
    assembly_error,
};

comptime {
    _ = if (!is_freestanding) struct {
        // Freestanding target has no file support so this is contingent.

        pub export fn uxn_asm_config_create() callconv(.c) ?*uxn_asm.InitOptions {
            if (alloc.create(uxn_asm.InitOptions)) |opts| {
                opts.* = uxn_asm.InitOptions{};

                return opts;
            } else |_| {
                return null;
            }
        }

        pub export fn uxn_asm_config_destroy(cfg: ?*uxn_asm.InitOptions) callconv(.c) void {
            if (cfg) |c| {
                return alloc.destroy(c);
            }
        }

        pub export fn uxn_asm_create(cfg: ?*uxn_asm.InitOptions) callconv(.c) ?*uxn_asm.Assembler(.{}) {
            return uxn_asm_create_internal(
                if (cfg) |c| c.* else .{},
            );
        }
    } else struct {
        pub export fn uxn_asm_create() callconv(.c) ?*uxn_asm.Assembler(.{}) {
            return uxn_asm_create_internal(.{});
        }
    };
}

fn uxn_asm_create_internal(cfg: uxn_asm.InitOptions) ?*uxn_asm.Assembler(.{}) {
    const io = comptime if (is_freestanding)
        std.Io.failing
    else
        std.Io.Threaded.global_single_threaded.io();

    if (alloc.create(uxn_asm.Assembler(.{}))) |ptr| {
        errdefer alloc.destroy(ptr);

        ptr.* = uxn_asm.Assembler(.{}).init(alloc, io, cfg) catch {
            return null;
        };

        return ptr;
    } else |_| {
        return null;
    }
}

pub export fn uxn_asm_destroy(assembler: ?*uxn_asm.Assembler(.{})) callconv(.c) void {
    if (assembler) |a| {
        a.deinit();
        alloc.destroy(a);
    }
}

pub export fn uxn_asm_assemble(
    assembler_: ?*uxn_asm.Assembler(.{}),
    src_: ?[*:0]u8,
    dst_: ?[*]u8,
    dst_len_: ?*usize,
    dst_err: ?*c_int,
) callconv(.c) ReasonCode {
    const assembler = assembler_ orelse return .invalid_argument;
    const src = src_ orelse return .invalid_argument;
    const dst = dst_ orelse return .invalid_argument;
    const dst_len = dst_len_ orelse return .invalid_argument;

    var src_rdr = std.Io.Reader.fixed(std.mem.sliceTo(src, 0));

    assembler.assemble(&src_rdr, dst[0..dst_len.*]) catch |e| {
        if (dst_err) |ed| {
            ed.* = @intFromError(e);
        }
        return .assembly_error;
    };

    dst_len.* = assembler.rom_length;

    return .ok;
}

pub export fn uxn_asm_get_diagnostic(
    assembler_: ?*uxn_asm.Assembler(.{}),
    code: c_int,
    dst_: ?[*]u8,
    dst_len: usize,
) callconv(.c) ReasonCode {
    const assembler = assembler_ orelse return ReasonCode.invalid_argument;
    const dst = dst_ orelse return ReasonCode.invalid_argument;
    const edst = dst[0..dst_len];

    @memset(edst, 0x00);

    // Leave the last element at 0 in any case
    var err_wrt = std.Io.Writer.fixed(edst[0 .. dst_len - 1]);

    assembler.issueDiagnostic(@errorFromInt(@as(u16, @intCast(code))), &err_wrt) catch {};
    err_wrt.flush() catch {};

    return .ok;
}

pub export fn uxn_asm_get_symbol_count(assembler_: ?*uxn_asm.Assembler(.{}), count_: ?*usize) callconv(.c) ReasonCode {
    const assembler = assembler_ orelse return .invalid_argument;
    const count = count_ orelse return .invalid_argument;

    count.* = assembler.labels.items.len;

    return .ok;
}

pub export fn uxn_asm_get_symbol(
    assembler_: ?*uxn_asm.Assembler(.{}),
    idx: usize,
    offset_: ?*u16,
    symbol_: ?*[*:0]u8,
) callconv(.c) ReasonCode {
    const assembler = assembler_ orelse return .invalid_argument;
    const offset = offset_ orelse return .invalid_argument;
    const symbol = symbol_ orelse return .invalid_argument;

    if (idx > assembler.labels.items.len) {
        return .invalid_argument;
    }

    offset.* = assembler.labels.items[idx].addr orelse 0xffff;
    symbol.* = &assembler.labels.items[idx].label;

    return .ok;
}
