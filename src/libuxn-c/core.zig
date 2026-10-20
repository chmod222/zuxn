const builtin = @import("builtin");
const std = @import("std");

const uxn = @import("uxn-core");

pub const std_options = std.Options{
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .uxn_cpu, .level = .info },
    },

    .logFn = if (is_wasm)
        noopLog
    else
        std.log.defaultLog,
};

fn noopLog(comptime _: std.log.Level, comptime _: @EnumLiteral(), comptime _: []const u8, _: anytype) void {}

pub const is_wasm = builtin.target.cpu.arch == .wasm32;
pub const is_freestanding = builtin.target.os.tag == .freestanding;

pub const alloc = if (is_wasm)
    std.heap.wasm_allocator
else
    std.heap.c_allocator;

const ResultCode = enum(c_int) {
    paused = -1,
    ok = 0,
    out_of_memory = 1,
    invalid_argument = 2,
    trapped = 3,
};

pub export fn uxn_alloc(n: usize) callconv(.c) ?[*]u8 {
    if (alloc.alloc(u8, @sizeOf(usize) + n)) |ptr| {
        std.mem.writeInt(usize, @ptrCast(ptr), n, .native);

        return @ptrCast(ptr[@sizeOf(usize)..]);
    } else |_| {
        return null;
    }
}

pub export fn uxn_free(ptr: ?[*]u8) callconv(.c) void {
    if (ptr) |p| {
        const size = std.mem.readInt(usize, @ptrCast(p - @sizeOf(usize)), .native);

        alloc.free(p[0 .. size + @sizeOf(usize)]);
    }
}

pub export fn uxn_rom_create(page_count: usize, rom_dst_: ?*[*]u8) callconv(.c) ResultCode {
    const rom_dst = rom_dst_ orelse return .invalid_argument;

    const size = (page_count + 1) * uxn.Cpu.page_size;
    const rom = alloc.alloc(u8, @sizeOf(usize) + size) catch {
        return .out_of_memory;
    };

    @memset(rom[@sizeOf(usize)..], 0x00);
    std.mem.writeInt(usize, @ptrCast(rom), size, .native);

    rom_dst.* = @ptrCast(rom.ptr + @sizeOf(usize));

    return .ok;
}

pub export fn uxn_rom_size(rom_: ?[*]u8) callconv(.c) c_int {
    const rom = rom_ orelse return -1;
    const base = rom - @sizeOf(usize);

    return @intCast(std.mem.readInt(usize, @ptrCast(base), .native));
}

pub export fn uxn_rom_destroy(rom_: ?[*]u8) callconv(.c) ResultCode {
    const rom = rom_ orelse return .invalid_argument;

    const base = rom - @sizeOf(usize);
    const size = std.mem.readInt(usize, @ptrCast(base), .native);

    alloc.free(base[0 .. size + @sizeOf(usize)]);

    return .ok;
}

const CpuContext = struct {
    cpu: uxn.Cpu,
    c_callback_dei: ?CCallbackPtr,
    c_callback_deo: ?CCallbackPtr,
};

const CCallbackPtr = *const fn (*uxn.Cpu, u8, ?*anyopaque) callconv(.c) c_int;

pub export fn uxn_cpu_create(
    rom_: ?[*]u8,
    cpu_dst_: ?**uxn.Cpu,
) callconv(.c) ResultCode {
    const rom = rom_ orelse return .invalid_argument;
    const cpu_dst = cpu_dst_ orelse return .invalid_argument;

    const base = rom - @sizeOf(usize);
    const size = std.mem.readInt(usize, @ptrCast(base), .native);

    const ctx = alloc.create(CpuContext) catch return .out_of_memory;

    ctx.* = CpuContext{
        .cpu = uxn.Cpu.init(rom[0..size]),
        .c_callback_dei = null,
        .c_callback_deo = null,
    };

    ctx.cpu.callback_data = null;
    ctx.cpu.device_intercept = uxn_cpu_trampoline;

    cpu_dst.* = &ctx.cpu;

    return .ok;
}

fn uxn_cpu_trampoline(
    cpu: *uxn.Cpu,
    address: u8,
    kind: uxn.Cpu.InterceptKind,
    udata: ?*anyopaque,
) !void {
    const ctx: *CpuContext = @fieldParentPtr("cpu", cpu);
    const cb = if (kind == .input)
        ctx.c_callback_dei
    else
        ctx.c_callback_deo;

    if (cb) |c_callback_ptr| {
        const c_callback: CCallbackPtr = @ptrCast(c_callback_ptr);

        if (c_callback(cpu, address, udata) != 0) {
            return error.Trapped;
        }
    }

    return;
}

pub export fn uxn_cpu_destroy(
    cpu_: ?*uxn.Cpu,
) callconv(.c) ResultCode {
    const cpu = cpu_ orelse return .invalid_argument;
    const ctx: *CpuContext = @fieldParentPtr("cpu", cpu);

    alloc.destroy(ctx);

    return .ok;
}

pub export fn uxn_cpu_evaluate(
    cpu_: ?*uxn.Cpu,
    vector: u16,
) callconv(.c) ResultCode {
    const cpu = cpu_ orelse return .invalid_argument;

    if (cpu.evaluateVector(vector)) |_| {
        return .ok;
    } else |_| {
        return .trapped;
    }
}

pub export fn uxn_cpu_evaluate_limit(
    cpu_: ?*uxn.Cpu,
    vector: u16,
    max_steps: usize,
) callconv(.c) ResultCode {
    const cpu = cpu_ orelse return .invalid_argument;

    if (cpu.evaluateVectorLimited(vector, max_steps)) |res| {
        if (res) |_| {
            return .ok;
        } else {
            return .paused;
        }
    } else |_| {
        return .trapped;
    }
}

pub export fn uxn_cpu_get_pc(
    cpu_: ?*uxn.Cpu,
    pc: *u16,
) callconv(.c) ResultCode {
    const cpu = cpu_ orelse return .invalid_argument;

    pc.* = cpu.pc;
    return .ok;
}

pub export fn uxn_cpu_set_pc(
    cpu_: ?*uxn.Cpu,
    pc: u16,
) callconv(.c) ResultCode {
    const cpu = cpu_ orelse return .invalid_argument;

    cpu.pc = pc;
    return .ok;
}

pub export fn uxn_cpu_run(
    cpu_: ?*uxn.Cpu,
    max_steps: usize,
) callconv(.c) ResultCode {
    const cpu = cpu_ orelse return .invalid_argument;

    if (cpu.run(max_steps)) |res| {
        if (res) |_| {
            return .ok;
        } else {
            return .paused;
        }
    } else |_| {
        return .trapped;
    }
}

pub export fn uxn_cpu_get_page_ptr(
    cpu_: ?*uxn.Cpu,
    page: usize,
    dst_: ?**[uxn.Cpu.page_size]u8,
) callconv(.c) ResultCode {
    const cpu = cpu_ orelse return .invalid_argument;
    const dst = dst_ orelse return .invalid_argument;

    if (page > cpu.pages.len) {
        return .invalid_argument;
    }

    dst.* = &cpu.pages[page];

    return .ok;
}

pub export fn uxn_cpu_get_device_page_ptr(
    cpu_: ?*uxn.Cpu,
    dst_: ?**[uxn.Cpu.device_page_size]u8,
) callconv(.c) ResultCode {
    const cpu = cpu_ orelse return .invalid_argument;
    const dst = dst_ orelse return .invalid_argument;

    dst.* = &cpu.device_mem;

    return .ok;
}

pub export fn uxn_cpu_set_input_interrupt_handler(
    cpu_: ?*uxn.Cpu,
    callback: ?CCallbackPtr,
) callconv(.c) ResultCode {
    const cpu = cpu_ orelse return .invalid_argument;
    const ctx: *CpuContext = @fieldParentPtr("cpu", cpu);

    ctx.c_callback_dei = @ptrCast(callback);

    return .ok;
}

pub export fn uxn_cpu_set_output_interrupt_handler(
    cpu_: ?*uxn.Cpu,
    callback: ?CCallbackPtr,
) callconv(.c) ResultCode {
    const cpu = cpu_ orelse return .invalid_argument;
    const ctx: *CpuContext = @fieldParentPtr("cpu", cpu);

    ctx.c_callback_deo = @ptrCast(callback);

    return .ok;
}

pub export fn uxn_cpu_set_interrupt_data(
    cpu_: ?*uxn.Cpu,
    data: ?*anyopaque,
) callconv(.c) ResultCode {
    const cpu = cpu_ orelse return .invalid_argument;

    cpu.callback_data = data;

    return .ok;
}

pub export fn uxn_cpu_set_interrupt_masks(
    cpu_: ?*uxn.Cpu,
    mask_input_: ?*[16]u16,
    mask_output_: ?*[16]u16,
) callconv(.c) ResultCode {
    const cpu = cpu_ orelse return .invalid_argument;

    if (mask_input_) |mask| {
        cpu.input_intercepts = mask.*;
    }

    if (mask_output_) |mask| {
        cpu.output_intercepts = mask.*;
    }

    return .ok;
}

pub export fn uxn_cpu_get_interrupt_masks(
    cpu_: ?*uxn.Cpu,
    mask_input_: ?*[16]u16,
    mask_output_: ?*[16]u16,
) callconv(.c) ResultCode {
    const cpu = cpu_ orelse return .invalid_argument;

    if (mask_input_) |mask| {
        mask.* = cpu.input_intercepts;
    }

    if (mask_output_) |mask| {
        mask.* = cpu.output_intercepts;
    }

    return .ok;
}

pub export fn uxn_cpu_get_wst(
    cpu_: ?*uxn.Cpu,
    dst_: ?**uxn.Cpu.Stack,
) callconv(.c) ResultCode {
    const cpu = cpu_ orelse return .invalid_argument;
    const dst = dst_ orelse return .invalid_argument;

    dst.* = &cpu.wst;

    return .ok;
}

pub export fn uxn_cpu_get_rst(
    cpu_: ?*uxn.Cpu,
    dst_: ?**uxn.Cpu.Stack,
) callconv(.c) ResultCode {
    const cpu = cpu_ orelse return .invalid_argument;
    const dst = dst_ orelse return .invalid_argument;

    dst.* = &cpu.rst;

    return .ok;
}

pub export fn uxn_stack_get_top(
    stack_: ?*uxn.Cpu.Stack,
    dst_: ?*u8,
) callconv(.c) ResultCode {
    const stack = stack_ orelse return .invalid_argument;
    const dst = dst_ orelse return .invalid_argument;

    dst.* = stack.sp;

    return .ok;
}

pub export fn uxn_stack_get_ptr(
    stack_: ?*uxn.Cpu.Stack,
    dst_: ?*[*]u8,
) callconv(.c) ResultCode {
    const stack = stack_ orelse return .invalid_argument;
    const dst = dst_ orelse return .invalid_argument;

    dst.* = &stack.data;

    return .ok;
}
