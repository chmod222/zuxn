const Debug = @This();

const std = @import("std");
const io = std.io;

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

allocator: Allocator,
symbols: std.ArrayListUnmanaged(Symbol),

fn cmpAddr(ctx: void, a: Symbol, b: Symbol) bool {
    _ = ctx;

    return a.addr < b.addr;
}

pub fn loadSymbols(alloc: Allocator, reader: *io.Reader) !Debug {
    var symbol_list = std.ArrayListUnmanaged(Symbol).empty;

    errdefer symbol_list.deinit(alloc);

    return while (true) {
        var temp: Symbol = undefined;
        var symbol_writer = std.io.Writer.fixed(&temp.symbol);

        temp.addr = reader.takeInt(u16, .big) catch {
            std.mem.sort(Symbol, symbol_list.items, {}, cmpAddr);

            return .{
                .allocator = alloc,
                .symbols = symbol_list,
            };
        };

        const n = try reader.streamDelimiter(&symbol_writer, 0x00);
        reader.toss(1);

        @memset(temp.symbol[n..], 0x00);

        try symbol_list.append(alloc, temp);
    } else unreachable;
}

pub fn unload(debug: *Debug) void {
    debug.symbols.deinit(debug.allocator);
}

pub fn locateSymbol(debug: *const Debug, addr: u16, allow_negative: bool) ?Location {
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

fn opcodeColor(i: uxn.Cpu.Opcode) struct { u8, u8, u8 } {
    return switch (i.baseOpcode()) {
        .BRK => switch (i) {
            .BRK => .{ 0xff, 0x00, 0x00 },
            .LIT, .LIT2, .LITr, .LIT2r => .{ 66, 135, 245 },
            .JCI, .JMI, .JSI => .{ 105, 66, 245 },
            else => unreachable,
        },
        .JMP, .JCN, .JSR => .{ 66, 245, 170 },
        .POP, .NIP, .SWP, .ROT, .DUP, .OVR, .STH => .{ 245, 111, 66 },
        .DEI, .DEO => .{ 245, 209, 66 },
        .LDZ, .LDR, .LDA => .{ 66, 245, 90 },
        .STZ, .STR, .STA => .{ 66, 203, 245 },
        .INC, .ADD, .SUB, .MUL, .DIV => .{ 245, 66, 90 },
        .EQU, .NEQ, .GTH, .LTH, .AND, .ORA, .EOR, .SFT => .{ 242, 17, 47 },
    };
}

fn dumpStack(stack: *const uxn.Cpu.Stack) void {
    const offset: u8 = 8;

    var i: u8 = stack.sp -% offset;

    // Print index row
    while (i != stack.sp +% offset + 1) : (i +%= 1) {
        if (i == stack.sp) {
            std.debug.print("\x1b[1;30m[{x:0>2}]\x1b[0m ", .{i});
        } else {
            std.debug.print("\x1b[1;30m{x:0>2}\x1b[0m ", .{i});
        }
    }

    std.debug.print("\n", .{});

    i = stack.sp -% offset;

    // Print value row
    while (i != stack.sp +% offset + 1) : (i +%= 1) {
        if (i == stack.sp) {
            std.debug.print("\x1b[1;31m[{x:0>2}]\x1b[0m ", .{stack.data[i]});
        } else {
            std.debug.print("{x:0>2} ", .{stack.data[i]});
        }
    }

    std.debug.print("\n", .{});
}

pub fn onDebugHook(cpu: *uxn.Cpu, data: ?*anyopaque) void {
    const debug_data: ?*const Debug = @ptrCast(@alignCast(data));

    std.debug.print("Breakpoint triggered\n", .{});

    var fallback = true;

    // Point at PC+1 because PC will always be the DEO and the next instruction
    // is more interesting.
    const pc = cpu.pc + 1;

    const color = opcodeColor(.fromByte(cpu.mem[pc]));
    const instr: uxn.Cpu.Opcode = .fromByte(cpu.mem[pc]);

    if (debug_data) |debug| {
        if (debug.locateSymbol(pc, false)) |stop_location| {
            fallback = false;
            std.debug.print("Next PC = {x:0>4} ({s}{c}#{x}): \x1b[38;2;{d};{d};{d}m{s}\x1b[0m\n", .{
                pc,
                stop_location.closest.symbol,
                @as(u8, if (stop_location.closest.addr > pc) '-' else '+'),
                stop_location.offset,
                color[0],
                color[1],
                color[2],
                instr.mnemonic(),
            });
        }
    }

    if (fallback) {
        std.debug.print("PC = {x:0>4}: \x1b[38;2;{d};{d};{d}m{s}\x1b[0m\n", .{
            pc,
            color[0],
            color[1],
            color[2],
            instr.mnemonic(),
        });
    }

    std.debug.print("\n", .{});

    std.debug.print("Working Stack: \n", .{});
    dumpStack(&cpu.wst);

    std.debug.print("\n", .{});

    std.debug.print("Return Stack: \n", .{});
    dumpStack(&cpu.rst);

    std.debug.print("\n", .{});

    // How many locations should be displayed in one line
    const w: usize = 16;

    // Which "line" in a hexdump of the memory this PC is on
    const memory_line = pc / w;

    // How many lines of context should be displayed above and below
    const context = 4;

    // Print column offset header
    std.debug.print("         ", .{});

    for (0..w) |coff| {
        if (pc % w == coff) {
            std.debug.print("{x:<2} v    ", .{coff});
        } else {
            std.debug.print("{x:<8}", .{coff});
        }
    }

    std.debug.print("\n", .{});

    var print_lits: usize = 0;

    // Print memory dump
    for (memory_line -| context..memory_line +| context) |page| {
        if (page == memory_line)
            std.debug.print("> ", .{})
        else
            std.debug.print("  ", .{});

        std.debug.print("{x:0>4} | ", .{page * w});

        for (page * w..page * w + w) |addr| {
            if (print_lits > 0) {
                std.debug.print("{x:0>2}      ", .{
                    cpu.mem[addr],
                });

                print_lits -= 1;
            } else {
                const opcode = uxn.Cpu.Opcode.fromByte(cpu.mem[addr]);
                const r, const g, const b = opcodeColor(opcode);

                std.debug.print("\x1b[38;2;{d};{d};{d}m{s:<8}\x1b[0m", .{
                    r,
                    g,
                    b,
                    opcode.mnemonic(),
                });

                switch (opcode) {
                    .LIT, .LITr => {
                        print_lits = 1;
                    },

                    .LIT2, .LIT2r, .JCI, .JMI, .JSI => {
                        print_lits = 2;
                    },

                    else => {},
                }
            }
        }

        std.debug.print("\n", .{});
    }
}
