const build_options = @import("build_options");

const std = @import("std");
const os = std.os;
const fs = std.fs;

const clap = @import("clap");

const uxn_asm = @import("uxn-asm");
const uxn = @import("uxn-core");
const varvara = @import("uxn-varvara");
const shared = @import("uxn-shared");

const Debug = shared.Debug;

const logger = std.log.scoped(.uxn_cli);

pub const std_options = .{
    .log_scope_levels = &[_]std.log.ScopeLevel{
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
    },
};

const VarvaraDefault = varvara.VarvaraSystem(std.fs.File.Writer, std.fs.File.Writer);

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

fn intercept(
    cpu: *uxn.Cpu,
    addr: u8,
    kind: uxn.Cpu.InterceptKind,
    data: ?*anyopaque,
) !void {
    const varvara_sys: ?*VarvaraDefault = @alignCast(@ptrCast(data));

    if (varvara_sys) |sys|
        try sys.intercept(cpu, addr, kind);
}

pub fn main() !u8 {
    const alloc = gpa.allocator();

    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help                 Display this help and exit.
        \\
    ++ (if (build_options.enable_jit_assembly)
        \\-S, --symbols <FILE>       Load debug symbols (argument ignored if self-assembling)
        \\<FILE>                     Input ROM or Tal
        \\
    else
        \\-S, --symbols <FILE>       Load debug symbols
        \\<FILE>                     Input ROM
        \\
    ) ++
        \\
        \\<ARG>...                   Command line arguments for the module
    );

    var diag = clap.Diagnostic{};

    const clap_args = .{
        .diagnostic = &diag,
        .allocator = alloc,
    };

    const res = clap.parse(clap.Help, &params, shared.parsers, clap_args) catch |err| {
        // Report useful error and exit
        diag.report(stderr, err) catch {};

        return err;
    };

    defer res.deinit();

    if (shared.handle_common_args(res, params)) |exit| {
        return exit;
    }

    var env = try shared.load_or_assemble_rom(
        alloc,
        res.positionals[0],
        res.args.symbols,
    );

    defer env.deinit();

    var system = try VarvaraDefault.init(gpa.allocator(), stdout, stderr);
    defer system.deinit();

    if (!system.sandbox_files(fs.cwd())) {
        logger.debug("File implementation does not suport sandboxing", .{});
    }

    if (env.debug_symbols) |*d| {
        system.system_device.debug_callback = &Debug.on_debug_hook;
        system.system_device.callback_data = d;
    }

    // Setup CPU and intercepts
    var cpu = uxn.Cpu.init(env.rom);

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
