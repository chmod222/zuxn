const std = @import("std");
const uxn = @import("uxn-core");

const builtin = @import("builtin");

pub const is_wasm = builtin.target.cpu.arch == .wasm32;
pub const alloc = if (is_wasm)
    std.heap.wasm_allocator
else
    std.heap.c_allocator;

const vv = @import("varvara.zig");

comptime {
    std.testing.refAllDecls(vv);
}

pub const std_options = std.Options{
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .uxn_cpu, .level = .info },
        .{ .scope = .uxn_wasm, .level = .info },
        .{ .scope = .uxn_wasm_varvara, .level = .info },

        .{ .scope = .uxn_varvara, .level = .info },
        .{ .scope = .uxn_varvara_system, .level = .info },
        .{ .scope = .uxn_varvara_console, .level = .info },
        .{ .scope = .uxn_varvara_screen, .level = .info },
        .{ .scope = .uxn_varvara_audio, .level = .info },
        .{ .scope = .uxn_varvara_controller, .level = .info },
        .{ .scope = .uxn_varvara_mouse, .level = .info },
        .{ .scope = .uxn_varvara_file, .level = .info },
        .{ .scope = .uxn_varvara_datetime, .level = .info },
    },

    .logFn = log,
};

pub fn panic(msg: []const u8, trace: ?*std.builtin.StackTrace, ra: ?usize) noreturn {
    _ = ra; // autofix

    logger.err("PANIC: {s}", .{msg});

    if (trace) |t|
        std.debug.writeErrorReturnTrace(t, .{
            .writer = &vv.stderrWriter.interface,
            .mode = .no_color,
        }) catch {}
    else
        logger.warn("No stack trace available", .{});

    @trap();
}

fn log(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime fmt: []const u8, args: anytype) void {
    var buffer: [1024]u8 = undefined;

    if (std.fmt.bufPrint(&buffer, "[{t}:{t}] " ++ fmt, .{ scope, level } ++ args)) |buf| {
        consoleLog(buf.ptr, buf.len);
    } else |_| {}
}

const logger = std.log.scoped(.uxn_wasm);

// Thin wrapper around console.log taking a pointer to UTF-8 + a length.
extern fn consoleLog([*]const u8, usize) void;
extern fn intercept(*uxn.Cpu, addr: u8, kind: u8) callconv(.c) void;

pub export fn cpuCreate(rom_ptr: [*]u8) ?*uxn.Cpu {
    if (alloc.create(uxn.Cpu)) |cpu| {
        const base = rom_ptr - @sizeOf(usize);
        const len = std.mem.readInt(usize, @ptrCast(base), .little);
        const rom = rom_ptr[0..len];

        if (rom.len % uxn.Cpu.page_size != 0) {
            logger.err("ROM size must be a multiple of 0x10000.", .{});

            return null;
        }

        logger.debug("Created a new CPU instance @ {*}", .{cpu});

        cpu.* = .init(rom);
        cpu.callback_data = null;
        cpu.device_intercept = interceptTrampoline;

        return cpu;
    } else |e| {
        logger.debug("Failed to create a new CPU: {t}", .{e});

        return null;
    }
}

pub export fn cpuSetInterceptEnabled(opt_cpu: ?*uxn.Cpu, addr: u8, kind: u8, enabled: bool) void {
    const cpu = opt_cpu orelse @panic("cpu == null");

    const device: u4 = @truncate(addr >> 4);
    const port: u4 = @truncate(addr & 0x0f);
    const port_mask = @as(u16, 1) << port;

    const mask: *u16 = if (kind == @intFromEnum(uxn.Cpu.InterceptKind.input))
        &cpu.input_intercepts[device]
    else
        &cpu.output_intercepts[device];

    if (enabled) {
        mask.* = mask.* | port_mask;
    } else {
        mask.* = mask.* & ~port_mask;
    }
}

pub export fn cpuFree(opt_cpu: ?*uxn.Cpu) void {
    const cpu = opt_cpu orelse @panic("cpu == null");

    alloc.destroy(cpu);
}

pub export fn cpuPeekByte(opt_cpu: ?*uxn.Cpu, addr: u16, section: u8) u8 {
    const cpu = opt_cpu orelse @panic("cpu == null");

    return switch (section) {
        0 => cpu.loadMem(u8, addr),
        1 => cpu.loadZero(u8, @truncate(addr % 0x100)),
        2 => cpu.loadDeviceMem(u8, @truncate(addr % 0x100)),
        else => 0,
    };
}

pub export fn cpuPokeByte(opt_cpu: ?*uxn.Cpu, addr: u16, value: u8, section: u8) void {
    const cpu = opt_cpu orelse @panic("cpu == null");

    switch (section) {
        0 => cpu.storeMem(u8, addr, value),
        1 => cpu.storeZero(u8, @truncate(addr % 0x100), value),
        2 => cpu.storeDeviceMem(u8, @truncate(addr % 0x100), value),
        else => {},
    }
}

pub export fn cpuPeekShort(opt_cpu: ?*uxn.Cpu, addr: u16, section: u8) u16 {
    const cpu = opt_cpu orelse @panic("cpu == null");

    return switch (section) {
        0 => cpu.loadMem(u16, addr),
        1 => cpu.loadZero(u16, @truncate(addr % 0x100)),
        2 => cpu.loadDeviceMem(u16, @truncate(addr % 0x100)),
        else => 0,
    };
}

pub export fn cpuPokeShort(opt_cpu: ?*uxn.Cpu, addr: u16, value: u16, section: u8) void {
    const cpu = opt_cpu orelse @panic("cpu == null");

    switch (section) {
        0 => cpu.storeMem(u16, addr, value),
        1 => cpu.storeZero(u16, @truncate(addr % 0x100), value),
        2 => cpu.storeDeviceMem(u16, @truncate(addr % 0x100), value),
        else => {},
    }
}

pub export fn cpuMemoryPtr(opt_cpu: ?*uxn.Cpu) [*]u8 {
    const cpu = opt_cpu orelse @panic("cpu == null");

    return cpu.mem.ptr;
}

pub export fn cpuDeviceMemoryPtr(opt_cpu: ?*uxn.Cpu) [*]u8 {
    const cpu = opt_cpu orelse @panic("cpu == null");

    return &cpu.device_mem;
}

pub export fn cpuEval(opt_cpu: ?*uxn.Cpu, vector: u16) void {
    const cpu = opt_cpu orelse @panic("cpu == null");

    cpu.evaluateVector(vector) catch return;
}

fn interceptTrampoline(cpu: *uxn.Cpu, addr: u8, kind: uxn.Cpu.InterceptKind, data: ?*anyopaque) !void {
    _ = data;

    intercept(cpu, addr, @intFromEnum(kind));
}

/// Get pointer to the working stack
pub export fn cpuWstPtr(opt_cpu: ?*uxn.Cpu) *uxn.Cpu.Stack {
    const cpu = opt_cpu orelse @panic("cpu == null");

    return &cpu.wst;
}

/// Get pointer to the return stack
pub export fn cpuRstPtr(opt_cpu: ?*uxn.Cpu) *uxn.Cpu.Stack {
    const cpu = opt_cpu orelse @panic("cpu == null");

    return &cpu.rst;
}

/// Get the current height of the stack
pub export fn stackTop(opt_stack: ?*uxn.Cpu.Stack) u8 {
    const stack = opt_stack orelse @panic("stack == null");

    return stack.sp;
}

/// Get pointer to the base of the stack
pub export fn stackDataPtr(opt_stack: ?*uxn.Cpu.Stack) [*]u8 {
    const stack = opt_stack orelse @panic("stack == null");

    return &stack.data;
}

pub export fn romCreate(size: usize) ?[*]u8 {
    if (alloc.alloc(u8, @sizeOf(usize) + size)) |buf| {
        @memset(buf, 0);

        logger.debug("Creating ROM of size {}", .{size});

        std.mem.writeInt(usize, @ptrCast(buf[0..@sizeOf(usize)]), size, .little);

        return buf.ptr + @sizeOf(usize);
    } else |_| {
        return null;
    }
}

pub export fn romFree(opt_rom: ?[*]u8) void {
    const rom = opt_rom orelse @panic("rom == null");

    const base = rom - @sizeOf(usize);
    const size = std.mem.readInt(usize, @ptrCast(base[0..@sizeOf(usize)]), .little);

    logger.debug("Destroying ROM of size {}", .{size});

    alloc.free(base[0 .. size + @sizeOf(usize)]);
}
