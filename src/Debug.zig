const Debug = @This();

const std = @import("std");

const uxn = @import("uxn-core");

const Allocator = std.mem.Allocator;
const File = std.fs.File;

const Symbol = struct {
    addr: u16,
    symbol: [0x40:0]u8,
};

const Location = struct {
    closest: *const Symbol,
    offset: u16,
};

symbols: std.ArrayList(Symbol),

fn cmp_addr(ctx: void, a: Symbol, b: Symbol) bool {
    _ = ctx;

    return a.addr < b.addr;
}

pub fn load_symbols(alloc: Allocator, reader: anytype) !Debug {
    var symbol_list = std.ArrayList(Symbol).init(alloc);

    errdefer symbol_list.deinit();

    return while (true) {
        var temp: Symbol = undefined;
        var fbs = std.io.FixedBufferStream([]u8){
            .buffer = &temp.symbol,
            .pos = 0,
        };

        temp.addr = reader.readInt(u16, .big) catch {
            std.mem.sort(Symbol, symbol_list.items, {}, cmp_addr);

            return .{
                .symbols = symbol_list,
            };
        };

        try reader.streamUntilDelimiter(fbs.writer(), 0x00, null);

        @memset(temp.symbol[@truncate(fbs.getPos() catch unreachable)..], 0x00);

        try symbol_list.append(temp);
    } else unreachable;
}

pub fn unload(debug: Debug) void {
    debug.symbols.deinit();
}

pub fn locate_symbol(debug: *const Debug, addr: u16, allow_negative: bool) ?Location {
    var left: usize = 0;
    var right: usize = debug.symbols.items.len;
    var nearest_smaller: usize = 0;
    var nearest_bigger: usize = 0;

    const pos: ?usize = while (left < right) {
        const mid = left + (right - left) / 2;

        switch (std.math.order(addr, debug.symbols.items[mid].addr)) {
            .eq => break mid,
            .gt => {
                left = mid + 1;
                nearest_smaller = mid;
            },
            .lt => {
                right = mid;
                nearest_bigger = mid;
            },
        }
    } else null;

    if (pos) |direct_match| {
        return .{
            .closest = &debug.symbols.items[direct_match],
            .offset = 0,
        };
    } else {
        const b = &debug.symbols.items[nearest_bigger];
        const s = &debug.symbols.items[nearest_smaller];

        return if (allow_negative)
            if ((b.addr - addr) > (addr - s.addr)) .{
                .closest = s,
                .offset = addr - s.addr,
            } else .{
                .closest = b,
                .offset = b.addr - addr,
            }
        else
            .{
                .closest = s,
                .offset = addr - s.addr,
            };
    }
}

fn dump_opcodes() void {
    var ins: u8 = 0x00;

    while (true) : (ins += 1) {
        const i = uxn.Cpu.Instruction.decode(ins);

        if (ins != 0 and ins & 0xf == 0)
            std.debug.print("\n", .{});

        const color = opcode_color(i);

        std.debug.print("{x:0>2}: \x1b[38;2;{d};{d};{d}m{s: <8}\x1b[0m", .{
            ins,
            color[0],
            color[1],
            color[2],
            i.mnemonic(),
        });

        if (ins == 0xff)
            break;
    }

    std.debug.print("\n", .{});
}

fn opcode_color(i: uxn.Cpu.Instruction) struct { u8, u8, u8 } {
    return switch (i.opcode) {
        .LIT => .{ 66, 135, 245 },
        .BRK => .{ 0xff, 0x00, 0x00 },
        .JCI, .JMI, .JSI => .{ 105, 66, 245 },
        .JMP, .JCN, .JSR => .{ 66, 245, 170 },
        .POP, .NIP, .SWP, .ROT, .DUP, .OVR, .STH => .{ 245, 111, 66 },
        .DEI, .DEO => .{ 245, 209, 66 },
        .LDZ, .LDR, .LDA => .{ 66, 245, 90 },
        .STZ, .STR, .STA => .{ 66, 203, 245 },
        .INC, .ADD, .SUB, .MUL, .DIV => .{ 245, 66, 90 },
        .EQU, .NEQ, .GTH, .LTH, .AND, .ORA, .EOR, .SFT => .{ 242, 17, 47 },
    };
}

fn dump_stack(stack: *const uxn.Cpu.Stack) void {
    const offset: u8 = 8;

    var i: u8 = stack.sp -% offset;

    while (i != stack.sp +% offset + 1) : (i +%= 1) {
        if (i == stack.sp) {
            std.debug.print("\x1b[1;31m[{x:0>2}]\x1b[0m ", .{i});
        } else {
            std.debug.print("{x:0>2} ", .{i});
        }
    }

    std.debug.print("\n", .{});

    i = stack.sp -% offset;

    while (i != stack.sp +% offset + 1) : (i +%= 1) {
        if (i == stack.sp) {
            std.debug.print("\x1b[1;31m[{x:0>2}]\x1b[0m ", .{stack.data[i]});
        } else {
            std.debug.print("{x:0>2} ", .{stack.data[i]});
        }
    }

    std.debug.print("\n", .{});
}

pub fn on_debug_hook(cpu: *uxn.Cpu, data: ?*anyopaque) void {
    const debug_data: ?*const Debug = @alignCast(@ptrCast(data));

    std.debug.print("Breakpoint triggered\n", .{});

    const color = opcode_color(uxn.Cpu.Instruction.decode(cpu.mem[cpu.pc]));

    var fallback = true;

    if (debug_data) |debug| {
        if (debug.locate_symbol(cpu.pc, false)) |stop_location| {
            fallback = false;
            std.debug.print("PC = {x:0>4} ({s}{c}#{x}): \x1b[38;2;{d};{d};{d}m{s}\x1b[0m\n", .{
                cpu.pc,
                stop_location.closest.symbol,
                @as(u8, if (stop_location.closest.addr > cpu.pc) '-' else '+'),
                stop_location.offset,
                color[0],
                color[1],
                color[2],
                uxn.Cpu.mnemonics[cpu.mem[cpu.pc]],
            });
        }
    }

    if (fallback) {
        std.debug.print("PC = {x:0>4}: \x1b[38;2;{d};{d};{d}m{s}\x1b[0m\n", .{
            cpu.pc,
            color[0],
            color[1],
            color[2],
            uxn.Cpu.mnemonics[cpu.mem[cpu.pc]],
        });
    }

    std.debug.print("\n", .{});

    std.debug.print("Working Stack: \n", .{});
    dump_stack(&cpu.wst);

    std.debug.print("\n", .{});

    std.debug.print("Return Stack: \n", .{});
    dump_stack(&cpu.rst);

    std.debug.print("\n", .{});
}
