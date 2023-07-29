const std = @import("std");

const clap = @import("clap");

const uxn = @import("uxn-core");
const varvara = @import("uxn-varvara");
const Debug = @import("uxn-shared").Debug;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var system: varvara.VarvaraSystem = undefined;

fn intercept(cpu: *uxn.Cpu, addr: u8, kind: uxn.Cpu.InterceptKind) !void {
    const port: u4 = @truncate(addr & 0xf);

    switch (addr >> 4) {
        0x0 => try system.system_device.intercept(cpu, port, kind),
        0x1 => try system.console_device.intercept(cpu, port, kind),
        0xa => try system.file_devices[0].intercept(cpu, port, kind),
        0xb => try system.file_devices[1].intercept(cpu, port, kind),
        0xc => try system.datetime_device.intercept(cpu, port, kind),

        else => {},
    }
}

pub fn main() !u8 {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help                 Display this help and exit.
        \\<FILE>                     Input ROM
        \\-S, --symbols <FILE>       Load debug symbols
        \\<ARG>...                   Command line arguments for the module
    );

    var diag = clap.Diagnostic{};
    var stderr = std.io.getStdErr().writer();

    const parsers = comptime .{
        .FILE = clap.parsers.string,
        .ARG = clap.parsers.string,
    };

    var res = clap.parse(clap.Help, &params, parsers, .{
        .diagnostic = &diag,
    }) catch |err| {
        // Report useful error and exit
        diag.report(stderr, err) catch {};

        return err;
    };

    var alloc = gpa.allocator();

    // Initialize system devices
    system = try varvara.VarvaraSystem.init(gpa.allocator());
    defer system.deinit();

    // Setup the breakpoint hook if requested
    var debug = if (res.args.symbols) |debug_symbols| b: {
        var symbols_file = try std.fs.cwd().openFile(debug_symbols, .{});
        defer symbols_file.close();

        break :b try Debug.load_symbols(alloc, symbols_file.reader());
    } else null;

    system.system_device.debug_callback = &Debug.on_debug_hook;

    if (debug) |*s|
        system.system_device.debug_callback_data = s;

    // Load input ROM
    const rom_file = try std.fs.cwd().openFile(res.positionals[0], .{});
    defer rom_file.close();

    var rom = try uxn.load_rom(alloc, rom_file);
    defer alloc.free(rom);

    // Setup CPU and intercepts
    var cpu = uxn.Cpu.init(rom);

    cpu.device_intercept = &intercept;

    cpu.output_intercepts = varvara.headless_intercepts.output;
    cpu.input_intercepts = varvara.headless_intercepts.input;

    // Run initialization vector and push arguments
    const args: [][]const u8 = @constCast(res.positionals[1..]);

    system.console_device.set_argc(&cpu, args);

    const stdin = std.io.getStdIn().reader();

    cpu.evaluate_vector(0x0100) catch |fault|
        try system.system_device.handle_fault(&cpu, fault);

    system.console_device.push_arguments(&cpu, args) catch |fault|
        try system.system_device.handle_fault(&cpu, fault);

    if (system.system_device.exit_code) |c|
        return c;

    // Loop until either exit is requested or EOF reached
    while (stdin.readByte() catch null) |b| {
        system.console_device.push_stdin_byte(&cpu, b) catch |fault|
            try system.system_device.handle_fault(&cpu, fault);

        if (system.system_device.exit_code) |c|
            return c;
    }

    return 0;
}
