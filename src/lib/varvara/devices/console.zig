const Cpu = @import("uxn-core").Cpu;

const std = @import("std");
const io = std.io;
const posix = std.posix;
const impl = @import("impl.zig");
const logger = std.log.scoped(.uxn_varvara_console);

pub const ports = struct {
    pub const vector = 0x0;
    pub const read = 0x2;
    pub const typ = 0x7;
    pub const write = 0x8;
    pub const err = 0x9;

    pub const live = 0x5;
    pub const exit = 0x6;
    pub const addr = 0xc;
    pub const mode = 0xe;
    pub const exec = 0xf;
};

pub const Console = struct {
    const ConnectedPipe = struct {
        pipe: [2]posix.fd_t,
        shadowed: posix.fd_t,
    };

    const ForkMode = packed struct(u8) {
        pipe_stdin: bool,
        pipe_stdout: bool,
        pipe_stderr: bool,
        terminate: bool,

        _: u4,
    };

    const ForkedChild = struct {
        mode: ForkMode,
        pid: posix.pid_t,

        /// Input to forked process from main stdout
        // TODO: hook up directly to Console/write, Console/error DEOs
        input: ?ConnectedPipe,

        /// Output from forked process to main stdin
        // TODO: hook up directly(ish) to Console/read, Console/vector
        output: ?ConnectedPipe,
    };

    device: impl.DeviceMixin,

    stderr: *io.Writer,
    stdout: *io.Writer,

    forked_child: ?ForkedChild = null,

    pub fn intercept(
        con: *Console,
        cpu: *Cpu,
        port: u4,
        kind: Cpu.InterceptKind,
    ) !void {
        if (kind == .output) {
            switch (port) {
                ports.write, ports.err => {
                    const octet = con.device.loadPort(u8, cpu, port);

                    if (port == ports.write) {
                        _ = con.stdout.writeByte(octet) catch return;
                    } else if (port == ports.err) {
                        _ = con.stderr.writeByte(octet) catch return;
                    }
                },

                ports.exec => {
                    con.execForked(
                        cpu,
                        con.getAddrSlice(cpu),
                        con.device.loadPort(ForkMode, cpu, ports.mode),
                    ) catch {};
                },

                else => {},
            }
        } else {
            switch (port) {
                ports.live, ports.exit => {
                    con.checkChild(cpu);
                },

                else => {},
            }
        }
    }

    fn getAddrSlice(con: *Console, cpu: *Cpu) []const u8 {
        const ptr: usize = con.device.loadPort(u16, cpu, ports.addr);

        return std.mem.sliceTo(cpu.mem[ptr..], 0x00);
    }

    fn updateProcessState(con: *Console, cpu: *Cpu, live: u8, exit: u8) void {
        con.device.storePort(u8, cpu, ports.live, live);
        con.device.storePort(u8, cpu, ports.exit, exit);
    }

    fn checkChild(con: *Console, cpu: *Cpu) void {
        if (con.forked_child) |*child| {
            const r = posix.waitpid(child.pid, std.c.W.NOHANG);

            if (r.pid > 0) {
                con.updateProcessState(cpu, 0xff, std.c.W.EXITSTATUS(r.status));
                con.cleanupChild(child);
            } else {
                con.updateProcessState(cpu, 0x01, 0x00);
            }
        }
    }

    fn mainChild(
        con: *Console,
        cmd: []const u8,
        mode: ForkMode,
        input: ?[2]posix.fd_t,
        output: ?[2]posix.fd_t,
    ) !noreturn {
        if (input) |pipe| {
            posix.dup2(pipe[0], 0) catch |e|
                logger.warn("Failed connecting pipe to child input: dup2(): {t}", .{e});

            posix.close(pipe[1]);
        }

        if (output) |pipe| {
            if (mode.pipe_stdout) {
                posix.dup2(pipe[1], 1) catch |e|
                    logger.warn("Failed connecting child stdout to output pipe: dup2(): {t}", .{e});
            }

            if (mode.pipe_stderr) {
                posix.dup2(pipe[1], 2) catch |e|
                    logger.warn("Failed connecting child stderr to output pipe: dup2(): {t}", .{e});
            }

            posix.close(pipe[0]);
        }

        con.stdout.flush() catch {};

        const args = &[_:null]?[*:0]const u8{
            "/bin/sh",
            "-c",
            @ptrCast(cmd.ptr),
            null,
        };

        return posix.execvpeZ(args[0].?, args, &.{null});
    }

    fn execForked(con: *Console, cpu: *Cpu, cmd: []const u8, mode: ForkMode) !void {
        if (con.forked_child) |*child| {
            con.killChild(cpu, child);
        }

        if (con.forked_child != null) {
            logger.warn("Child was not properly cleanup up, ignoring exec", .{});

            return;
        }

        if (mode.terminate) {
            con.updateProcessState(cpu, 0x00, 0x00);

            return;
        }

        errdefer con.updateProcessState(cpu, 0xff, 0xff);

        const input_pipe = if (mode.pipe_stdin) p: {
            break :p posix.pipe() catch |e| {
                logger.warn("Failed creating input pipe: pipe(): {t}", .{e});
                return e;
            };
        } else null;

        const output_pipe = if (mode.pipe_stdout or mode.pipe_stderr) p: {
            break :p posix.pipe() catch |e| {
                logger.warn("Failed creating output pipe: pipe(): {t}", .{e});
                return e;
            };
        } else null;

        logger.debug("Executing '{s}'", .{ cmd, mode });

        if (posix.fork()) |p| {
            switch (p) {
                0 => con.mainChild(cmd, mode, input_pipe, output_pipe) catch {
                    posix.exit(1);
                },

                else => |child| {
                    // Main process
                    con.updateProcessState(cpu, 0x00, 0x01);

                    var connected_input: ?ConnectedPipe = null;
                    var connected_output: ?ConnectedPipe = null;

                    if (input_pipe) |pipe| {
                        connected_input = ConnectedPipe{
                            .pipe = pipe,
                            .shadowed = posix.dup(1) catch unreachable,
                        };

                        posix.dup2(pipe[1], 1) catch |e|
                            logger.warn("Failed connecting parent stdout to input pipe: dup2(): {t}", .{e});

                        posix.close(pipe[0]);
                    }

                    if (output_pipe) |pipe| {
                        connected_output = ConnectedPipe{
                            .pipe = pipe,
                            .shadowed = posix.dup(0) catch unreachable,
                        };

                        posix.dup2(pipe[0], 0) catch |e|
                            logger.warn("Failed connecting output pipe to parent stdin: dup2(): {t}", .{e});

                        posix.close(pipe[1]);
                    }

                    con.forked_child = ForkedChild{
                        .mode = mode,
                        .pid = child,

                        .input = connected_input,
                        .output = connected_output,
                    };
                },
            }
        } else |e| {
            logger.warn("Failed forking process: fork(): {t}", .{e});
            return e;
        }
    }

    fn killChild(con: *Console, cpu: *Cpu, child: *ForkedChild) void {
        // Send sigterm
        posix.kill(child.pid, 9) catch |e| {
            logger.warn("Failed killing child process: kill({}): {t}", .{ child.pid, e });
        };

        const r = posix.waitpid(child.pid, std.c.W.NOHANG);

        if (r.pid > 0) {
            con.updateProcessState(cpu, 0xff, std.c.W.EXITSTATUS(r.status));
        }

        con.cleanupChild(child);
    }

    fn cleanupChild(con: *Console, child: *ForkedChild) void {
        con.tryRestoreFiles(child);
        con.forked_child = null;
    }

    fn tryRestoreFiles(_: *Console, child: *ForkedChild) void {
        if (child.input) |connect| {
            // close child stdin and restore saved
            posix.close(connect.pipe[1]);
            posix.dup2(connect.shadowed, 1) catch |e| {
                logger.warn("Failed restoring stdout: dup2(): {t}", .{e});
            };

            child.input = null;
        }

        if (child.output) |connect| {
            // close child stderr/stdout and restore saved
            posix.close(connect.pipe[0]);
            posix.dup2(connect.shadowed, 0) catch |e| {
                logger.warn("Failed restoring stdin: dup2(): {t}", .{e});
            };

            child.output = null;
        }
    }

    pub fn hasProcess(con: *const Console) bool {
        return con.forked_child != null;
    }

    pub fn unpipeProcess(con: *Console) void {
        if (con.forked_child) |*child|
            con.tryRestoreFiles(child);
    }

    pub fn pushArguments(
        con: Console,
        cpu: *Cpu,
        args: [][]const u8,
    ) !void {
        for (0.., args) |i, arg| {
            for (arg) |oct| {
                con.device.storePort(u8, cpu, ports.typ, 0x2);
                con.device.storePort(u8, cpu, ports.read, oct);

                try cpu.evaluateVector(con.device.loadPort(u16, cpu, ports.vector));
            }

            con.device.storePort(u8, cpu, ports.typ, if (i == args.len - 1) 0x4 else 0x3);
            con.device.storePort(u8, cpu, ports.read, 0x10);

            try cpu.evaluateVector(con.device.loadPort(u16, cpu, ports.vector));
        }
    }

    pub fn setArgc(
        con: Console,
        cpu: *Cpu,
        args: [][]const u8,
    ) void {
        con.device.storePort(u8, cpu, ports.typ, @intFromBool(args.len > 0));
    }

    pub fn pushStdinByte(
        con: Console,
        cpu: *Cpu,
        byte: u8,
    ) !void {
        const vector = con.device.loadPort(u16, cpu, ports.vector);

        con.device.storePort(u8, cpu, ports.typ, 0x1);
        con.device.storePort(u8, cpu, ports.read, byte);

        if (vector > 0x0000)
            try cpu.evaluateVector(vector);
    }
};
