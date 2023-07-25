const std = @import("std");
pub const Cpu = @import("Cpu.zig");

const File = std.fs.File;
const Allocator = std.mem.Allocator;

pub const SDL = @cImport({
    @cInclude("SDL2/SDL.h");
});

var AUDIO_FINISHED: u32 = undefined;
var STDIN_RECEIVED: u32 = undefined;

fn dump_opcodes() void {
    var ins: u8 = 0x00;

    while (true) : (ins += 1) {
        const i = Cpu.Instruction.decode(ins);

        if (ins != 0 and ins & 0xf == 0)
            std.debug.print("\n", .{});

        var color = opcode_color(i);

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

fn load_rom(alloc: Allocator, file: File) !*[0x10000]u8 {
    var ram_pos: u16 = 0x0100;
    var ram = try alloc.alloc(u8, 0x10000);

    while (true) {
        const r = try file.readAll(ram[ram_pos .. ram_pos + 0x1000]);

        ram_pos += @truncate(r);

        if (r < 0x1000)
            break;
    }

    // Zero out the zero-page and everything behind the ROM
    @memset(ram[0..0x100], 0x00);
    @memset(ram[ram_pos..0x10000], 0x00);

    return @ptrCast(ram);
}

fn opcode_color(i: Cpu.Instruction) struct { u8, u8, u8 } {
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

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

const Debug = @import("Debug.zig");

const ConsoleDevice = @import("devices/Console.zig");
const DatetimeDevice = @import("devices/Datetime.zig");
const FileDevice = @import("devices/File.zig");
const SystemDevice = @import("devices/System.zig");
const ScreenDevice = @import("devices/Screen.zig");
const ControllerDevice = @import("devices/Controller.zig");
const MouseDevice = @import("devices/Mouse.zig");
const AudioDevice = @import("devices/Audio.zig");

var system: SystemDevice = .{ .addr = 0x0 };
var console: ConsoleDevice = .{ .addr = 0x1 };
var screen: ScreenDevice = .{ .addr = 0x2, .scale = 2, .alloc = gpa.allocator() };

var audio_id: SDL.SDL_AudioDeviceID = undefined;
var audio: [4]AudioDevice = .{
    .{ .addr = 0x3 },
    .{ .addr = 0x4 },
    .{ .addr = 0x5 },
    .{ .addr = 0x6 },
};

var controller: ControllerDevice = .{ .addr = 0x8 };
var mouse: MouseDevice = .{ .addr = 0x9 };
var datetime: DatetimeDevice = .{ .addr = 0xc };

var files: [2]FileDevice = .{
    .{ .addr = 0xa },
    .{ .addr = 0xb },
};

fn intercept(cpu: *Cpu, addr: u8, kind: Cpu.InterceptKind) !void {
    const port: u4 = @truncate(addr & 0xf);
    const lock_audio = kind == .output and addr >= 0x30 and addr < 0x70;

    if (lock_audio) SDL.SDL_LockAudioDevice(audio_id);
    defer if (lock_audio) SDL.SDL_UnlockAudioDevice(audio_id);

    switch (addr >> 4) {
        0x0 => try system.intercept(cpu, port, kind),
        0x1 => try console.intercept(cpu, port, kind),
        0x2 => try screen.intercept(cpu, port, kind),
        0x3 => try audio[0].intercept(cpu, port, kind),
        0x4 => try audio[1].intercept(cpu, port, kind),
        0x5 => try audio[2].intercept(cpu, port, kind),
        0x6 => try audio[3].intercept(cpu, port, kind),
        0x8 => try controller.intercept(cpu, port, kind),
        0x9 => try mouse.intercept(cpu, port, kind),
        0xa => try files[0].intercept(cpu, port, kind),
        0xb => try files[1].intercept(cpu, port, kind),
        0xc => try datetime.intercept(cpu, port, kind),

        else => {},
    }
}

fn main_cli(cpu: *Cpu, args: [][:0]const u8) !u8 {
    cpu.output_intercepts = .{ 0xc028, 0x0300, 0xc028, 0x8000, 0x8000, 0x8000, 0x8000, 0x0000, 0x0000, 0x0000, 0xa260, 0xa260, 0x0000, 0x0000, 0x0000, 0x0000 };
    cpu.input_intercepts = .{ 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x07ff, 0x0000, 0x0000, 0x0000 };

    console.set_argc(cpu, args);

    const stdin = std.io.getStdIn().reader();

    cpu.evaluate_vector(0x0100) catch |fault|
        try system.handle_fault(cpu, fault);

    console.push_arguments(cpu, args) catch |fault|
        try system.handle_fault(cpu, fault);

    while (system.exit_code == null) {
        const b = stdin.readByte() catch
            break;

        console.push_stdin_byte(cpu, b) catch |fault|
            try system.handle_fault(cpu, fault);
    }

    return system.exit_code orelse 0;
}

fn sdl_panic() noreturn {
    const str = @as(?[*:0]const u8, SDL.SDL_GetError()) orelse "unknown error";

    @panic(std.mem.sliceTo(str, 0));
}

fn audio_callback(u: ?*anyopaque, stream: [*c]u8, len: c_int) callconv(.C) void {
    var samples_ptr = @as([*c]i16, @alignCast(@ptrCast(stream)));
    var samples = samples_ptr[0 .. @as(usize, @intCast(len)) / 2];

    // TODO: 0x00 should ideally be SDL_AudioSpec.silence here
    @memset(stream[0..@as(usize, @intCast(len))], 0x00);

    //var still_playing: usize = 0;
    var event: SDL.SDL_Event = undefined;

    for (0.., &audio) |i, *poly| {
        if (poly.render_audio(samples)) |r| {
            if (r) {
                //still_playing += 1;
            } else {
                event.type = AUDIO_FINISHED + @as(u32, @truncate(i));

                _ = SDL.SDL_PushEvent(&event);
            }
        }
    }

    _ = u;

    //if (still_playing == 0) {
    //    const audio_id: *SDL.SDL_AudioDeviceID = @alignCast(@ptrCast(u.?));
    //
    //    SDL.SDL_PauseAudioDevice(audio_id.*, 1);
    //}
}

fn receive_stdin(p: ?*anyopaque) callconv(.C) c_int {
    _ = p;

    const stdin = std.io.getStdIn().reader();

    var event: SDL.SDL_Event = .{ .type = STDIN_RECEIVED };

    while (system.exit_code == null) {
        const b = stdin.readByte() catch
            break;

        event.cbutton.button = b;

        _ = SDL.SDL_PushEvent(&event);
    }

    return 0;
}

const InputType = union(enum) {
    buttons: ControllerDevice.ButtonFlags,
    key: u8,
};

fn determine_input(event: *SDL.SDL_Event) ?InputType {
    const mods = SDL.SDL_GetModState();
    const sym = event.key.keysym.sym;

    if (sym < 0x20 or sym == SDL.SDLK_DELETE) {
        return .{ .key = @intCast(sym) };
    } else if (mods & SDL.KMOD_CTRL > 0) {
        if (sym < SDL.SDLK_a) {
            return .{ .key = @intCast(sym) };
        } else if (sym <= SDL.SDLK_z) {
            return .{ .key = @truncate(@as(u32, @bitCast(sym)) - @as(u32, @bitCast(mods & SDL.KMOD_SHIFT)) * 0x20) };
        }
    }

    switch (event.key.keysym.sym) {
        SDL.SDLK_LCTRL => return .{ .buttons = .{ .ctrl = true } },
        SDL.SDLK_LALT => return .{ .buttons = .{ .alt = true } },
        SDL.SDLK_LSHIFT => return .{ .buttons = .{ .shift = true } },
        SDL.SDLK_HOME => return .{ .buttons = .{ .start = true } },
        SDL.SDLK_UP => return .{ .buttons = .{ .up = true } },
        SDL.SDLK_DOWN => return .{ .buttons = .{ .down = true } },
        SDL.SDLK_LEFT => return .{ .buttons = .{ .left = true } },
        SDL.SDLK_RIGHT => return .{ .buttons = .{ .right = true } },

        else => {},
    }

    return null;
}

fn main_graphical(cpu: *Cpu, args: [][:0]const u8) !u8 {
    if (SDL.SDL_Init(SDL.SDL_INIT_JOYSTICK | SDL.SDL_INIT_VIDEO | SDL.SDL_INIT_EVENTS | SDL.SDL_INIT_AUDIO) < 0)
        sdl_panic();

    defer SDL.SDL_Quit();

    _ = SDL.SDL_ShowCursor(SDL.SDL_DISABLE);

    screen.initialize_graphics() catch sdl_panic();
    defer screen.cleanup_graphics();

    var audio_spec: SDL.SDL_AudioSpec = .{
        .freq = AudioDevice.sample_rate,
        .format = SDL.AUDIO_S16SYS,
        .channels = 2,
        .callback = &audio_callback,
        .samples = 512,
        .userdata = &audio_id,

        .silence = 0,
        .size = 0,
        .padding = undefined,
    };

    audio_id = SDL.SDL_OpenAudioDevice(null, 0, &audio_spec, null, 0);

    SDL.SDL_PauseAudioDevice(audio_id, 0);

    AUDIO_FINISHED = SDL.SDL_RegisterEvents(4);
    STDIN_RECEIVED = SDL.SDL_RegisterEvents(1);

    var stdin = SDL.SDL_CreateThread(receive_stdin, "stdin", null);

    SDL.SDL_DetachThread(stdin);

    cpu.output_intercepts = .{ 0xff28, 0x0300, 0xc028, 0x8000, 0x8000, 0x8000, 0x8000, 0x0000, 0x0000, 0x0000, 0xa260, 0xa260, 0x0000, 0x0000, 0x0000, 0x0000 };
    cpu.input_intercepts = .{ 0x0000, 0x0000, 0x003c, 0x0014, 0x0014, 0x0014, 0x0014, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x07ff, 0x0000, 0x0000, 0x0000 };

    system.screen = &screen;

    console.set_argc(cpu, args);

    cpu.evaluate_vector(0x0100) catch |fault|
        try system.handle_fault(cpu, fault);

    console.push_arguments(cpu, args) catch |fault|
        try system.handle_fault(cpu, fault);

    main_loop: while (system.exit_code == null) {
        var ev: SDL.SDL_Event = undefined;

        while (SDL.SDL_PollEvent(&ev) != 0) {
            switch (ev.type) {
                SDL.SDL_QUIT => {
                    break :main_loop;
                },

                SDL.SDL_MOUSEMOTION => {
                    mouse.update_position(
                        cpu,
                        @truncate(@as(c_uint, @bitCast(ev.motion.x))),
                        @truncate(@as(c_uint, @bitCast(ev.motion.y))),
                    ) catch |fault|
                        try system.handle_fault(cpu, fault);
                },

                SDL.SDL_MOUSEBUTTONDOWN => {
                    mouse.press_buttons(
                        cpu,
                        @bitCast(@as(u8, 1) << @as(u3, @truncate(ev.button.button - 1))),
                    ) catch |fault|
                        try system.handle_fault(cpu, fault);
                },

                SDL.SDL_MOUSEBUTTONUP => {
                    mouse.release_buttons(
                        cpu,
                        @bitCast(@as(u8, 1) << @as(u3, @truncate(ev.button.button - 1))),
                    ) catch |fault|
                        try system.handle_fault(cpu, fault);
                },

                SDL.SDL_MOUSEWHEEL => {
                    mouse.update_scroll(cpu, ev.wheel.x, ev.wheel.y) catch |fault|
                        try system.handle_fault(cpu, fault);
                },

                SDL.SDL_TEXTINPUT => {
                    controller.press_key(cpu, ev.text.text[0]) catch |fault|
                        try system.handle_fault(cpu, fault);
                },

                SDL.SDL_KEYDOWN => {
                    if (determine_input(&ev)) |input| switch (input) {
                        .buttons => |b| {
                            controller.press_buttons(cpu, b, 0) catch |fault|
                                try system.handle_fault(cpu, fault);
                        },

                        .key => |k| {
                            controller.press_key(cpu, k) catch |fault|
                                try system.handle_fault(cpu, fault);
                        },
                    };
                },

                SDL.SDL_KEYUP => {
                    if (determine_input(&ev)) |input| switch (input) {
                        .buttons => |b| {
                            controller.release_buttons(cpu, b, 0) catch |fault|
                                try system.handle_fault(cpu, fault);
                        },

                        else => {},
                    };
                },

                else => {
                    if (ev.type >= AUDIO_FINISHED and ev.type < AUDIO_FINISHED + 4) {
                        const dev = ev.type - AUDIO_FINISHED;

                        audio[dev].evaluate_finish_vector(cpu) catch |fault|
                            try system.handle_fault(cpu, fault);
                    } else if (ev.type == STDIN_RECEIVED) {
                        console.push_stdin_byte(cpu, ev.cbutton.button) catch |fault|
                            try system.handle_fault(cpu, fault);
                    }
                },
            }
        }

        screen.evaluate_frame(cpu) catch |fault|
            try system.handle_fault(cpu, fault);

        screen.update();
    }

    return system.exit_code orelse 0;
}

pub fn main() !u8 {
    var alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    const rom_file = try std.fs.cwd().openFile(args[1], .{});
    defer rom_file.close();

    const symbol_file_name = try std.fmt.allocPrint(alloc, "{s}.sym", .{args[1]});
    defer alloc.free(symbol_file_name);

    var debug = if (std.fs.cwd().openFile(symbol_file_name, .{})) |symbol_file| d: {
        defer symbol_file.close();

        break :d try Debug.load_symbols(alloc, symbol_file);
    } else |_| null;

    var rom = try load_rom(alloc, rom_file);

    defer if (debug) |d| d.unload();

    //if (debug.locate_symbol(0x0104)) |loc| {
    //    std.debug.print("Entry at {s}{c}{x:0>4}\n", .{
    //        loc.closest.symbol,
    //        if (loc.closest.addr > 0x0104) @as(u8, '-') else '+',
    //        loc.offset,
    //    });
    //}

    var cpu = Cpu.init(rom);

    defer files[0].cleanup();
    defer files[1].cleanup();

    cpu.device_intercept = &intercept;

    return main_graphical(&cpu, args[2..]);
}
