const build_options = @import("build_options");

const std = @import("std");
const posix = std.posix;
const Io = std.Io;

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

fn intercept(
    cpu: *uxn.Cpu,
    addr: u8,
    kind: uxn.Cpu.InterceptKind,
    data: ?*anyopaque,
) !void {
    const varvara_sys: ?*varvara.Varvara = @ptrCast(@alignCast(data));

    if (varvara_sys) |sys|
        try sys.intercept(cpu, addr, kind);
}

pub fn main(init: std.process.Init) !u8 {
    var stdin_buffer: [1024]u8 = undefined;
    var stdin = Io.File.stdin().reader(init.io, &stdin_buffer);

    // Explicitely unbuffered
    var stdout = Io.File.stdout().writer(init.io, &.{});
    var stderr = Io.File.stderr().writer(init.io, &.{});

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

    const res = shared.handleCommonArgs(
        &params,
        init.gpa,
        init.minimal.args,
        &stderr.interface,
    ) orelse return 0;

    defer res.deinit();

    var env = try shared.loadOrAssembleRom(
        init.arena.allocator(),
        init.io,
        res,
        res.positionals[0].?,
        res.args.symbols,
        &stderr.interface,
    );

    defer env.deinit();

    var system = try varvara.Varvara.init(
        init.gpa,
        init.io,
        init.environ_map,
        &stdout.interface,
        &stderr.interface,
    );

    defer system.deinit();

    if (!system.sandboxFiles(Io.Dir.cwd())) {
        logger.debug("File implementation does not support sandboxing", .{});
    }

    if (env.debug_symbols) |*d| {
        system.system_device.debug_callback = &Debug.onDebugHook;
        system.system_device.callback_data = d;
    }

    // Setup CPU and intercepts
    var cpu = uxn.Cpu.init(env.rom);

    logger.debug("Initialized Uxn with {} pages of {} bytes each", .{ cpu.pages.len, uxn.Cpu.page_size });

    cpu.device_intercept = &intercept;
    cpu.callback_data = &system;

    cpu.output_intercepts = varvara.headless_intercepts.output;
    cpu.input_intercepts = varvara.headless_intercepts.input;

    // Run initialization vector and push arguments
    system.console_device.setArgc(&cpu, res.positionals[1]);

    try cpu.evaluateVector(0x0100);
    try system.console_device.pushArguments(&cpu, res.positionals[1]);

    if (system.system_device.exit_code) |c|
        return c;

    var uxn_stdin_buffer: [1024]u8 = undefined;
    var uxn_stdin = system.console_device.stdin(&cpu, &uxn_stdin_buffer);

    var child_stdout_buffer: [1024]u8 = undefined;
    var child_stderr_buffer: [1024]u8 = undefined;

    var last_child_id: ?std.process.Child.Id = null;
    var child_stdout: ?Io.File.Reader = null;
    var child_stderr: ?Io.File.Reader = null;

    const Event = union(enum) {
        stdin_avail: (Io.File.Reader.Error || Io.Reader.Error)!void,
        child_out: (Io.File.Reader.Error || Io.Reader.Error)!void,
        child_err: (Io.File.Reader.Error || Io.Reader.Error)!void,
    };

    // Loop until either exit is requested or EOF reached
    while (system.system_device.exit_code == null) {
        var events: [4]Event = undefined;
        var select = Io.Select(Event).init(init.io, &events);

        defer _ = select.cancel();

        select.async(.stdin_avail, fillBuffer, .{&stdin});

        // Get the active child ID, if any
        const child_id = if (system.console_device.forked_child) |chld|
            chld.id
        else
            null;

        // If the process scope of the open channels has changed, re-open them, otherwise
        // keep them as is so they don’t get reopened after they’re closed and to give the
        // loop a chance to finish reading.
        if (last_child_id != child_id) {
            if (child_stdout == null) {
                child_stdout = system.console_device.childStdout(&child_stdout_buffer);
            }

            if (child_stderr == null) {
                child_stderr = system.console_device.childStderr(&child_stderr_buffer);
            }
        }

        // If channels are open, add them to the set.
        if (child_stdout) |*f|
            select.async(.child_out, fillBuffer, .{f});

        if (child_stderr) |*f|
            select.async(.child_err, fillBuffer, .{f});

        defer {
            stdout.interface.flush() catch {};
            stderr.interface.flush() catch {};
        }

        switch (try select.await()) {
            .stdin_avail => {
                stdin.interface.streamExact(&uxn_stdin.interface, stdin.interface.bufferedLen()) catch |e| {
                    logger.warn("Failed to stream Uxn stdin: {t}", .{e});
                };

                uxn_stdin.interface.flush() catch |e| {
                    logger.warn("Failed to flush Uxn stdin: {t}", .{e});
                };

                // Re-register request
                select.async(.stdin_avail, fillBuffer, .{&stdin});
            },

            inline .child_out, .child_err => |result, t| {
                if (result) {
                    const stream = if (t == .child_out)
                        &child_stdout.?
                    else
                        &child_stderr.?;

                    stream.interface.streamExact(&uxn_stdin.interface, stream.interface.bufferedLen()) catch |e| {
                        logger.warn("Failed to stream Uxn stdin: {t}", .{e});
                    };

                    uxn_stdin.interface.flush() catch |e| {
                        logger.warn("Failed to flush Uxn stdin: {t}", .{e});
                    };

                    // Recreate the request
                    select.async(
                        t,
                        fillBuffer,
                        .{stream},
                    );
                } else |e| {
                    if (e != error.EndOfStream) {
                        logger.warn("{t}: {t}", .{ t, e });
                    }

                    last_child_id = child_id;

                    if (t == .child_out) {
                        child_stdout = null;
                    } else {
                        child_stderr = null;
                    }
                }
            },
        }
    }

    return system.system_device.exit_code orelse 0;
}

fn fillBuffer(reader: *Io.File.Reader) (Io.File.Reader.Error || Io.Reader.Error)!void {
    reader.interface.fill(1) catch |e| {
        return reader.err orelse e;
    };
}
