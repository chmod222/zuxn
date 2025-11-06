const build_options = @import("build_options");

const std = @import("std");
const os = std.os;
const fs = std.fs;
const posix = std.posix;

const clap = @import("clap");

const uxn_asm = @import("uxn-asm");
const uxn = @import("uxn-core");
const varvara = @import("uxn-varvara");
const shared = @import("uxn-shared");

const Debug = shared.Debug;

const logger = std.log.scoped(.uxn_cli);

pub const std_options = std.Options{
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .uxn_cpu, .level = .info },
        .{ .scope = .uxn_cli, .level = .info },

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

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

fn intercept(
    cpu: *uxn.Cpu,
    addr: u8,
    kind: uxn.Cpu.InterceptKind,
    data: ?*anyopaque,
) !void {
    const varvara_sys: ?*varvara.VarvaraDefault = @ptrCast(@alignCast(data));

    if (varvara_sys) |sys|
        try sys.intercept(cpu, addr, kind);
}

pub fn main() !u8 {
    const alloc = gpa.allocator();

    var stdin_buffer: [1024]u8 = undefined;
    var stdin = std.fs.File.stdin().reader(&stdin_buffer);

    // Explicitely unbuffered
    var stdout = std.fs.File.stdout().writer(&.{});
    var stderr = std.fs.File.stderr().writer(&.{});

    const params = comptime clap.parseParamsComptime(
        \\-h, --help                 Display this help and exit.
        \\
    ++ (if (build_options.enable_jit_assembly)
        (shared.jit_assembly_args ++
            \\
            \\-S, --symbols <FILE>       Load debug symbols (argument ignored if self-assembling)
            \\<FILE>                     Input ROM or Tal
            \\
        )
    else
        \\-S, --symbols <FILE>       Load debug symbols
        \\<FILE>                     Input ROM
        \\
    ) ++
        \\<ARG>...                   Command line arguments for the module
    );

    var diag = clap.Diagnostic{};

    const clap_args = clap.ParseOptions{
        .diagnostic = &diag,
        .allocator = alloc,
    };

    const res = clap.parse(clap.Help, &params, shared.parsers, clap_args) catch |err| {
        // Report useful error and exit
        diag.report(&stderr.interface, err) catch {};

        return err;
    };

    defer res.deinit();

    if (shared.handleCommonArgs(res, params)) |exit| {
        return exit;
    }

    var env = try shared.loadOrAssembleRom(
        alloc,
        res,
        res.positionals[0].?,
        res.args.symbols,
    );

    defer env.deinit();

    var system = try varvara.VarvaraDefault.init(
        gpa.allocator(),
        &stdout.interface,
        &stderr.interface,
    );
    defer system.deinit();

    if (!system.sandboxFiles(fs.cwd())) {
        logger.debug("File implementation does not support sandboxing", .{});
    }

    if (env.debug_symbols) |*d| {
        system.system_device.debug_callback = &Debug.onDebugHook;
        system.system_device.callback_data = d;
    }

    // Setup CPU and intercepts
    var cpu = uxn.Cpu.init(env.rom);

    cpu.device_intercept = &intercept;
    cpu.callback_data = &system;

    cpu.output_intercepts = varvara.headless_intercepts.output;
    cpu.input_intercepts = varvara.headless_intercepts.input;

    // Run initialization vector and push arguments
    const args: [][]const u8 = @constCast(res.positionals[1]);

    system.console_device.setArgc(&cpu, args);

    cpu.evaluateVector(0x0100) catch |fault|
        try system.system_device.handleFault(&cpu, fault);

    system.console_device.pushArguments(&cpu, args) catch |fault|
        try system.system_device.handleFault(&cpu, fault);

    if (system.system_device.exit_code) |c|
        return c;

    var fds: [1]posix.pollfd = [_]posix.pollfd{
        .{ .fd = 0, .events = posix.system.POLL.IN, .revents = 0 },
    };

    // Loop until either exit is requested or EOF reached
    while (system.system_device.exit_code == null) {
        const ready = posix.poll(&fds, 100) catch |e| {
            logger.warn("poll() failed: {t}", .{e});

            continue;
        };

        if (ready > 0) {
            stdin.interface.fillMore() catch |e| {
                if (e == error.EndOfStream and !system.console_device.unpipeProcess()) {
                    // EOF and EOF cannot be restored
                    break;
                } else if (e != error.EndOfStream) {
                    logger.warn("read(): {t}", .{e});

                    break;
                }

                continue;
            };

            logger.debug("Pushing {} bytes from stdin", .{stdin.interface.bufferedLen()});

            while (stdin.interface.bufferedLen() > 0) {
                const b = stdin.interface.takeByte() catch unreachable;

                system.console_device.pushStdinByte(&cpu, b) catch |fault|
                    try system.system_device.handleFault(&cpu, fault);
            }
        }
    }

    return system.system_device.exit_code orelse 0;
}
