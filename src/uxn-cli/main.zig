const std = @import("std");

const clap = @import("clap");

const uxn = @import("uxn-core");
const varvara = @import("uxn-varvara");
const Debug = @import("uxn-shared").Debug;

pub const std_options = struct {
    pub const log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .uxn_cpu, .level = .info },

        .{ .scope = .uxn_varvara, .level = .info },
        .{ .scope = .uxn_varvara_system, .level = .info },
        .{ .scope = .uxn_varvara_console, .level = .info },
        .{ .scope = .uxn_varvara_screen, .level = .info },
        .{ .scope = .uxn_varvara_audio, .level = .info },
        .{ .scope = .uxn_varvara_controller, .level = .info },
        .{ .scope = .uxn_varvara_mouse, .level = .info },
        .{ .scope = .uxn_varvara_file, .level = .info },
        .{ .scope = .uxn_varvara_datetime, .level = .info },
    };
};

const VarvaraDefault = varvara.VarvaraSystem(std.fs.File.Writer, std.fs.File.Writer);

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

fn intercept(
    cpu: *uxn.Cpu,
    addr: u8,
    kind: uxn.Cpu.InterceptKind,
    data: ?*anyopaque,
) !void {
    var varvara_sys: ?*VarvaraDefault = @alignCast(@ptrCast(data));

    if (varvara_sys) |sys|
        try sys.intercept(cpu, addr, kind);
}

pub fn main() !u8 {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help                 Display this help and exit.
        \\<FILE>                     Input ROM
        \\-S, --symbols <FILE>       Load debug symbols
        \\<ARG>...                   Command line arguments for the module
    );

    var diag = clap.Diagnostic{};

    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

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
    var system = try VarvaraDefault.init(gpa.allocator(), stdout, stderr);
    defer system.deinit();

    // Setup the breakpoint hook if requested
    var debug = if (res.args.symbols) |debug_symbols| b: {
        var symbols_file = try std.fs.cwd().openFile(debug_symbols, .{});
        defer symbols_file.close();

        break :b try Debug.load_symbols(alloc, symbols_file.reader());
    } else null;

    system.system_device.debug_callback = &Debug.on_debug_hook;

    if (debug) |*s|
        system.system_device.callback_data = s;

    // Load input ROM
    const rom_file = try std.fs.cwd().openFile(res.positionals[0], .{});
    defer rom_file.close();

    var rom = try uxn.load_rom(alloc, rom_file);
    defer alloc.free(rom);

    // Setup CPU and intercepts
    var cpu = uxn.Cpu.init(rom);

    cpu.device_intercept = &intercept;
    cpu.callback_data = &system;

    cpu.output_intercepts = varvara.headless_intercepts.output;
    cpu.input_intercepts = varvara.headless_intercepts.input;

    // Run initialization vector and push arguments
    const args: [][]const u8 = @constCast(res.positionals[1..]);

    system.console_device.set_argc(&cpu, args);

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
