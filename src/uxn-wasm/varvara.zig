const std = @import("std");
const Io = std.Io;

const varvara = @import("uxn-varvara");
const uxn = @import("uxn-core");
const root = @import("root");

const logger = std.log.scoped(.uxn_wasm_varvara);

const WasmWriter = struct {
    interface: Io.Writer,
    kind: enum { stderr, stdout },

    const vtable = Io.Writer.VTable{
        .drain = wasmDrain,
    };

    fn wasmDrain(writer: *Io.Writer, bufs: []const []const u8, splat: usize) !usize {
        const wasm_writer: *const WasmWriter = @fieldParentPtr("interface", writer);

        const pattern = bufs[bufs.len - 1];
        const buffers = bufs[0 .. bufs.len - 1];

        var len = pattern.len * splat + writer.end;

        for (writer.buffered()) |oct| {
            varvaraConsoleWrite(@intFromEnum(wasm_writer.kind), oct);
        }

        for (buffers) |buf| {
            len += buf.len;

            for (buf) |oct| {
                varvaraConsoleWrite(@intFromEnum(wasm_writer.kind), oct);
            }
        }

        for (0..splat) |_| {
            for (pattern) |oct| {
                varvaraConsoleWrite(@intFromEnum(wasm_writer.kind), oct);
            }
        }

        return len;
    }

    pub fn stderr() WasmWriter {
        return WasmWriter{
            .interface = .{
                .buffer = &.{},
                .vtable = &vtable,
            },
            .kind = .stderr,
        };
    }

    pub fn stdout() WasmWriter {
        return WasmWriter{
            .interface = .{
                .buffer = &.{},
                .vtable = &vtable,
            },
            .kind = .stdout,
        };
    }
};

pub var stderrWriter: WasmWriter = .stderr();
pub var stdoutWriter: WasmWriter = .stdout();

const Varvara = struct {
    system_device: varvara.system.System,
    console_device: varvara.console.Console,
    screen_device: varvara.screen.Screen,
    audio_devices: [4]varvara.audio.Audio,
    controller_device: varvara.controller.Controller,
    mouse_device: varvara.mouse.Mouse,
    file_devices: [2]varvara.file.File,
    datetime_device: varvara.datetime.Datetime(wasmDatetime),
};

pub export fn varvaraCreate() ?*Varvara {
    if (root.alloc.create(Varvara)) |sys| {
        sys.system_device = .init(0x0, null);
        sys.console_device = .init(0x1, Io.failing, &stdoutWriter.interface, &stderrWriter.interface);
        sys.screen_device = .init(0x2, root.alloc);
        sys.audio_devices[0] = .init(0x3);
        sys.audio_devices[1] = .init(0x4);
        sys.audio_devices[2] = .init(0x5);
        sys.audio_devices[3] = .init(0x6);
        sys.controller_device = .init(0x8);
        sys.mouse_device = .init(0x9);
        sys.file_devices[0] = .init(0xa, Io.failing);
        sys.file_devices[0] = .init(0xb, Io.failing);
        sys.datetime_device = .init(0xc);

        sys.screen_device.initializeGraphics() catch |e| {
            logger.err("Failed to initialize graphics framebuffer: {t}", .{e});
            return null;
        };

        return sys;
    } else |e| {
        logger.err("Varvara failed to initialize: {t}", .{e});

        return null;
    }
}

pub export fn varvaraFree(opt_vv: ?*Varvara) void {
    const vv = opt_vv orelse @panic("varvara == null");

    vv.screen_device.cleanupGraphics();
    vv.file_devices[0].cleanup();
    vv.file_devices[1].cleanup();

    root.alloc.destroy(vv);

    // For good measure
    if (screenImage) |img|
        @memset(img, 0);
}

pub export fn varvaraSetupInterceptMasks(opt_cpu: ?*uxn.Cpu, headless: bool) void {
    const cpu = opt_cpu orelse @panic("cpu == null");

    const set = if (headless) &varvara.headless_intercepts else &varvara.full_intercepts;

    cpu.input_intercepts = set.input;
    cpu.output_intercepts = set.output;
}

pub export fn varvaraIntercept(opt_vv: ?*Varvara, opt_cpu: ?*uxn.Cpu, addr: u8, kind_raw: u8) void {
    const cpu = opt_cpu orelse @panic("cpu == null");
    const vv = opt_vv orelse @panic("varvara == null");

    const port: u4 = @truncate(addr & 0xf);
    const kind = switch (kind_raw) {
        0 => uxn.Cpu.InterceptKind.input,
        1 => uxn.Cpu.InterceptKind.output,
        else => return,
    };

    while (!audioMutex.tryLock()) {
        //
    }

    audioMutex.unlock();

    const r = switch (addr >> 4) {
        0x0 => {
            vv.system_device.intercept(cpu, port, kind);

            if (addr & 0xf >= varvara.system.ports.red and
                addr & 0xf < varvara.system.ports.debug)
            {
                vv.screen_device.forceRedraw();
            }
        },
        0x1 => vv.console_device.intercept(cpu, port, kind),
        0x2 => vv.screen_device.intercept(cpu, port, kind),
        0x3 => vv.audio_devices[0].intercept(cpu, port, kind),
        0x4 => vv.audio_devices[1].intercept(cpu, port, kind),
        0x5 => vv.audio_devices[2].intercept(cpu, port, kind),
        0x6 => vv.audio_devices[3].intercept(cpu, port, kind),
        0x8 => vv.controller_device.intercept(cpu, port, kind),
        0x9 => vv.mouse_device.intercept(cpu, port, kind),
        0xa => vv.file_devices[0].intercept(cpu, port, kind),
        0xb => vv.file_devices[1].intercept(cpu, port, kind),
        0xc => vv.datetime_device.intercept(cpu, port, kind),

        else => {},
    };

    if (r) |_| {
        //
    } else |e| {
        logger.warn("Varvara intercept failed for {}: {t}", .{ addr, e });
    }
}

// System implementation
pub export fn varvaraSystemColor(opt_vv: ?*Varvara, col: usize) u32 {
    const vv = opt_vv orelse @panic("varvara == null");

    if (col > 3) {
        @panic("color out of bounds");
    }

    const color = vv.system_device.colors[col];

    return @as(u32, color.r) << 16 | @as(u32, color.g) << 8 | @as(u32, color.b);
}

pub export fn varvaraExitCode(opt_vv: ?*Varvara) i32 {
    const vv = opt_vv orelse @panic("varvara == null");

    return if (vv.system_device.exit_code) |c| c else -1;
}

// Console implementation
extern fn varvaraConsoleWrite(kind: u8, oct: u8) void;

pub export fn varvaraConsoleStdin(opt_vv: ?*Varvara, opt_cpu: ?*uxn.Cpu, oct: u8) void {
    const cpu = opt_cpu orelse @panic("cpu == null");
    const vv = opt_vv orelse @panic("varvara == null");

    vv.console_device.pushStdinByte(cpu, oct) catch unreachable;
}

pub export fn varvaraConsoleSetArgc(opt_vv: ?*Varvara, opt_cpu: ?*uxn.Cpu, argc: u8) void {
    const cpu = opt_cpu orelse @panic("cpu == null");
    const vv = opt_vv orelse @panic("varvara == null");

    vv.console_device.setArgc(cpu, argc);
}

pub export fn varvaraConsolePushArg(
    opt_vv: ?*Varvara,
    opt_cpu: ?*uxn.Cpu,
    opt_arg: ?[*:0]const u8,
    last: bool,
) void {
    const cpu = opt_cpu orelse @panic("cpu == null");
    const vv = opt_vv orelse @panic("varvara == null");
    const arg = opt_arg orelse @panic("arg == null");

    vv.console_device.pushArgument(cpu, std.mem.sliceTo(arg, 0), last) catch unreachable;
}

pub export fn varvaraConsolePushStdin(
    opt_vv: ?*Varvara,
    opt_cpu: ?*uxn.Cpu,
    opt_input: ?[*:0]const u8,
) void {
    const cpu = opt_cpu orelse @panic("cpu == null");
    const vv = opt_vv orelse @panic("varvara == null");
    const input = opt_input orelse @panic("input == null");

    for (std.mem.sliceTo(input, 0)) |oct| {
        vv.console_device.pushStdinByte(cpu, oct) catch unreachable;
    }
}

// Screen implementation
pub export fn varvaraScreenWidth(opt_vv: ?*Varvara) u32 {
    const vv = opt_vv orelse @panic("varvara == null");

    return vv.screen_device.size[0];
}

pub export fn varvaraScreenHeight(opt_vv: ?*Varvara) u32 {
    const vv = opt_vv orelse @panic("varvara == null");

    return vv.screen_device.size[1];
}

var screenImage: ?[]u32 = null;

pub export fn varvaraScreenRender(opt_vv: ?*Varvara) [*]u8 {
    const vv = opt_vv orelse @panic("varvara == null");
    const req = @as(usize, vv.screen_device.size[0]) * vv.screen_device.size[1];

    const image = if (screenImage) |img| b: {
        break :b if (img.len >= req)
            img
        else
            root.alloc.realloc(img, req) catch unreachable;
    } else root.alloc.alloc(u32, req) catch unreachable;

    screenImage = image;

    if (vv.screen_device.dirty_region) |dirty| {
        const tl, const br = dirty;

        for (tl[1]..br[1]) |y| {
            for (tl[0]..br[0]) |x| {
                const coords = @Vector(2, u16){ @truncate(x), @truncate(y) };
                const idx = varvara.screen.indexOf(vv.screen_device.size, coords);
                const scr_idx = vv.screen_device.index(coords);
                const pal = (@as(u4, vv.screen_device.foreground[scr_idx]) << 2) | vv.screen_device.background[scr_idx];

                const color = &vv.system_device.colors[if ((pal >> 2) > 0) (pal >> 2) else (pal & 0x3)];

                std.mem.writeInt(
                    u32,
                    @ptrCast(&image[idx]),
                    @as(u32, color.r) << 24 | @as(u32, color.g) << 16 | @as(u32, color.b) << 8 | 0xff,
                    .big,
                );
            }
        }

        vv.screen_device.dirty_region = null;
    }

    return @ptrCast(image.ptr);
}

pub export fn varvaraScreenEvaluateVector(opt_vv: ?*Varvara, opt_cpu: ?*uxn.Cpu) void {
    const vv = opt_vv orelse @panic("varvara == null");
    const cpu = opt_cpu orelse @panic("cpu == null");

    vv.screen_device.evaluateFrame(cpu) catch unreachable;
}

// Controller Device
fn mapControllerButton(button: u32) ?varvara.controller.ButtonFlags {
    return switch (button) {
        // SHIFT / B,
        16 => .{ .shift = true },

        // CTRL / A
        17 => .{ .ctrl = true },

        // ALT, / Select
        18 => .{ .alt = true },

        // HOME / Start
        36 => .{ .start = true },

        // Arrow Keys
        38 => .{ .up = true },
        40 => .{ .down = true },
        37 => .{ .left = true },
        39 => .{ .right = true },

        else => null,
    };
}

// Audio
var audioBuffer: [4096]f32 = undefined;
var audioMutex: std.atomic.Mutex = .unlocked;

pub export fn varvaraAudioBufferSize() usize {
    return audioBuffer.len;
}

pub export fn varvaraAudioRender(opt_vv: ?*Varvara, opt_cpu: ?*uxn.Cpu) [*]f32 {
    while (!audioMutex.tryLock()) {
        //
    }
    defer audioMutex.unlock();

    const vv = opt_vv orelse @panic("varvara == null");
    const cpu = opt_cpu orelse @panic("cpu == null");

    var samples: [audioBuffer.len]i16 = undefined;

    for (&vv.audio_devices) |*poly| {
        poly.renderAudio(&samples);

        if (poly.active_sample) |s| {
            if (s.envelope.isFinished()) {
                poly.evaluateFinishVector(cpu) catch {
                    // Cannot really report errors in the audio renderer.
                };
            }
        }
    }

    for (0.., samples) |i, s| {
        audioBuffer[i] = @as(f32, @floatFromInt(s << 4)) / std.math.maxInt(i16);
    }

    return &audioBuffer;
}

pub export fn varvaraControllerKeyDown(opt_vv: ?*Varvara, opt_cpu: ?*uxn.Cpu, button: u32) void {
    const vv = opt_vv orelse @panic("varvara == null");
    const cpu = opt_cpu orelse @panic("cpu == null");

    if (mapControllerButton(button)) |btn| {
        vv.controller_device.pressButtons(cpu, btn, 0) catch unreachable;
    } else if (button < 256) {
        vv.controller_device.pressKey(cpu, @truncate(button)) catch unreachable;
    }
}

pub export fn varvaraControllerKeyUp(opt_vv: ?*Varvara, opt_cpu: ?*uxn.Cpu, button: u32) void {
    const vv = opt_vv orelse @panic("varvara == null");
    const cpu = opt_cpu orelse @panic("cpu == null");

    if (mapControllerButton(button)) |btn| {
        vv.controller_device.releaseButtons(cpu, btn, 0) catch unreachable;
    }
}

// Mouse implementation
fn mapMouseButtons(raw: u8) varvara.mouse.ButtonFlags {
    return .{
        .left = (raw & 0x01) > 0,
        .right = (raw & 0x02) > 0,
        .middle = (raw & 0x04) > 0,
        ._unused = 0,
    };
}

pub export fn varvaraMouseMove(opt_vv: ?*Varvara, opt_cpu: ?*uxn.Cpu, x: u16, y: u16) void {
    const vv = opt_vv orelse @panic("varvara == null");
    const cpu = opt_cpu orelse @panic("cpu == null");

    vv.mouse_device.updatePosition(cpu, x, y) catch unreachable;
}

pub export fn varvaraMouseSetButtons(opt_vv: ?*Varvara, opt_cpu: ?*uxn.Cpu, buttons: u8) void {
    const vv = opt_vv orelse @panic("varvara == null");
    const cpu = opt_cpu orelse @panic("cpu == null");

    vv.mouse_device.setButtons(cpu, mapMouseButtons(buttons)) catch unreachable;
}

pub export fn varvaraMouseScroll(opt_vv: ?*Varvara, opt_cpu: ?*uxn.Cpu, x: i16, y: i16) void {
    const vv = opt_vv orelse @panic("varvara == null");
    const cpu = opt_cpu orelse @panic("cpu == null");

    vv.mouse_device.updateScroll(cpu, x, y) catch unreachable;
}

// Datetime
const CTimestamp = extern struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    dotw: u8,
    doty: u16,
    isdst: bool,
};

extern fn varvaraDatetimeFetch(*CTimestamp) callconv(.c) void;

fn wasmDatetime() varvara.datetime.Timestamp {
    var extern_ts: CTimestamp = undefined;

    varvaraDatetimeFetch(&extern_ts);

    return varvara.datetime.Timestamp{
        .year = extern_ts.year,
        .month = extern_ts.month,
        .day = extern_ts.day,
        .hour = extern_ts.hour,
        .minute = extern_ts.minute,
        .second = extern_ts.second,
        .dotw = extern_ts.dotw,
        .doty = extern_ts.doty,
        .isdst = extern_ts.isdst,
    };
}
