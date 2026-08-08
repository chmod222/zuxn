const Cpu = @import("uxn-core").Cpu;

const std = @import("std");
const process = std.process;
const c = std.c;
const Io = std.Io;
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

fn catchErrno(res: c_int) !c_int {
    return switch (std.c.errno(res)) {
        .SUCCESS => res,
        else => return error.Errno,
    };
}

fn writerDrain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
    const cw: *Writer = @fieldParentPtr("interface", w);

    const additional = data[0 .. data.len - 1];
    const splat_elem = data[additional.len];

    for (w.buffer[0..w.end]) |oct|
        cw.con.pushStdinByte(cw.cpu, oct) catch return error.WriteFailed;

    for (additional) |buf| {
        for (buf) |oct|
            cw.con.pushStdinByte(cw.cpu, oct) catch return error.WriteFailed;
    }

    for (0..splat) |_|
        for (splat_elem) |oct|
            cw.con.pushStdinByte(cw.cpu, oct) catch return error.WriteFailed;

    return w.consume(Io.Writer.countSplat(data, splat) + w.end);
}

const writer_vtable: Io.Writer.VTable = .{
    .drain = &writerDrain,
};

pub const Writer = struct {
    cpu: *Cpu,
    con: *Console,
    interface: Io.Writer,
};

fn kill(proc: *process.Child) !void {
    const rc = c.kill(proc.id orelse return, .KILL);

    if (rc < 0) {
        logger.warn("kill({}): {t}", .{ proc.id.?, c.errno(rc) });

        return error.Errno;
    }
}

fn status(proc: *const process.Child) !?u8 {
    var raw_status: c_int = 0;

    if (c.waitpid(proc.id orelse return null, &raw_status, std.c.W.NOHANG) >= 0) {
        if (c.W.IFEXITED(@intCast(raw_status))) {
            return c.W.EXITSTATUS(@intCast(raw_status));
        } else {
            return null;
        }
    } else {
        return error.Errno;
    }
}

pub const Console = struct {
    const ForkMode = packed struct(u8) {
        pipe_stdin: bool,
        pipe_stdout: bool,
        pipe_stderr: bool,
        terminate: bool,

        _: u4,
    };

    device: impl.DeviceMixin,
    io: Io,

    stderr: *Io.Writer,
    stdout: *Io.Writer,

    forked_child: ?process.Child = null,

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
                        // stdout may write to a child if requested.
                        var child_stdin = con.childStdin(&.{});

                        if (child_stdin) |*child| {
                            child.interface.writeByte(octet) catch {};
                        } else {
                            con.stdout.writeByte(octet) catch {};
                        }
                    } else if (port == ports.err) {
                        // stderr always writes to stderr.
                        _ = con.stderr.writeByte(octet) catch {};
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

    pub fn stdin(con: *Console, cpu: *Cpu, buffer: []u8) Writer {
        return Writer{
            .cpu = cpu,
            .con = con,
            .interface = Io.Writer{
                .vtable = &writer_vtable,
                .buffer = buffer,
            },
        };
    }

    fn getAddrSlice(con: *Console, cpu: *Cpu) []const u8 {
        const ptr: usize = con.device.loadPort(u16, cpu, ports.addr);

        return std.mem.sliceTo(cpu.mem[ptr..], 0x00);
    }

    fn execForked(con: *Console, cpu: *Cpu, cmd: []const u8, mode: ForkMode) !void {
        if (con.forked_child) |*child| {
            con.killChild(cpu, child);
        }

        if (mode.terminate) {
            return con.updateProcessState(cpu, 0x00, 0x00);
        }

        errdefer con.updateProcessState(cpu, 0xff, 0xff);

        con.forked_child = try process.spawn(con.io, .{
            .argv = &.{ "/bin/sh", "-c", cmd },
            .stdin = if (mode.pipe_stdin) .pipe else .close,
            .stdout = if (mode.pipe_stdout) .pipe else .close,
            .stderr = if (mode.pipe_stderr) .pipe else .close,
        });

        logger.debug("Spawned: {s}", .{cmd});
    }

    fn childStream(con: *Console, buffer: []u8, comptime field: []const u8) ?Io.File.Reader {
        if (con.forked_child) |child| {
            if (@field(child, field)) |f| {
                return f.readerStreaming(con.io, buffer);
            }
        }

        return null;
    }

    pub fn childStdin(con: *Console, buffer: []u8) ?Io.File.Writer {
        if (con.forked_child) |child| {
            if (child.stdin) |f| {
                return f.writerStreaming(con.io, buffer);
            }
        }

        return null;
    }
    pub fn childStdout(con: *Console, buffer: []u8) ?Io.File.Reader {
        return con.childStream(buffer, "stdout");
    }

    pub fn childStderr(con: *Console, buffer: []u8) ?Io.File.Reader {
        return con.childStream(buffer, "stderr");
    }

    fn updateProcessState(con: *Console, cpu: *Cpu, live: u8, exit: u8) void {
        con.device.storePort(u8, cpu, ports.live, live);
        con.device.storePort(u8, cpu, ports.exit, exit);
    }

    pub fn checkChild(con: *Console, cpu: *Cpu) void {
        if (con.forked_child) |*child| {
            if (status(child) catch null) |exit_code| {
                con.updateProcessState(cpu, 0xff, exit_code);
                con.cleanupChild(child);
            } else {
                con.updateProcessState(cpu, 0x01, 0x00);
            }
        }
    }

    fn killChild(con: *Console, cpu: *Cpu, child: *process.Child) void {
        // Send sigterm
        kill(child) catch |e| {
            logger.warn("Failed killing child process: kill(): {t}", .{e});
        };

        if (status(child) catch null) |exit_code| {
            con.updateProcessState(cpu, 0xff, exit_code);
        }

        con.cleanupChild(child);
        con.forked_child = null;
    }

    fn cleanupChild(con: *Console, child: *process.Child) void {
        if (child.stdin) |f|
            f.close(con.io);

        if (child.stdout) |f|
            f.close(con.io);

        if (child.stderr) |f|
            f.close(con.io);
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
