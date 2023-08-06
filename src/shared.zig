const build_options = @import("build_options");

const std = @import("std");
const clap = @import("clap");

const os = std.os;

const uxn = @import("uxn-core");
const uxn_asm = @import("uxn-asm");

pub const Debug = @import("Debug.zig");

pub const optargs = struct {
    const OptionData = union(enum) {
        long: []const u8,
        short: u8,
    };

    pub const OptionResult = struct {
        opt: *const Option,
        optarg: ?[]const u8,
    };

    pub const Option = struct {
        name: ?[]const u8,
        flag: ?u8,
        has_arg: bool,
    };

    pub const ArgvOptionsIterator = struct {
        known_options: []const Option,

        argv: [][*:0]u8,
        last_option: usize = 1,
        last_option_idx: usize = 0,

        pub fn next(iter: *ArgvOptionsIterator) !?OptionResult {
            if (iter.last_option >= iter.argv.len)
                return null;

            const opt = std.mem.sliceTo(iter.argv[iter.last_option], 0);

            const res: OptionData = if (std.mem.eql(u8, "--", opt)) {
                // "--" on its own ends parsing option flags
                return null;
            } else if (iter.last_option_idx == 0 and opt.len > 2 and std.mem.eql(u8, "--", opt[0..2])) l: {
                // "--" starts a long option that encompasses the entire arg
                const optname = opt[2..];

                iter.last_option += 1;
                iter.last_option_idx = 0;

                break :l .{ .long = optname };
            } else if (iter.last_option_idx > 0 or (opt.len > 1 and std.mem.eql(u8, "-", opt[0..1]))) s: {
                // "-" preceeds one or more short flags.
                iter.last_option_idx += 1;

                break :s .{ .short = opt[iter.last_option_idx] };
            } else {
                // No prefix and not processing an argument, so we hit the positionals.
                return null;
            };

            const target_opt: *const Option = r: for (iter.known_options) |*kopt| {
                switch (res) {
                    .short => |flag| if (kopt.flag == flag)
                        break :r kopt,

                    .long => |name| if (kopt.name) |n| {
                        if (std.mem.eql(u8, name, n))
                            break :r kopt;
                    },
                }
            } else return error.UnknownOption;

            const retval = if (target_opt.has_arg) r: {
                const optarg = if (iter.last_option_idx == 0) a: {
                    if (iter.last_option < iter.argv.len) {
                        break :a iter.argv[iter.last_option];
                    } else {
                        return error.ArgumentExpected;
                    }
                } else if (iter.last_option_idx == opt.len - 1) a: {
                    // Short option argument may only be specified if the flag is the last
                    // in any particular "-abc" segment.
                    if (iter.last_option < iter.argv.len - 1) {
                        break :a iter.argv[iter.last_option + 1];
                    } else {
                        return error.ArgumentExpected;
                    }
                } else {
                    return error.InvalidOption;
                };

                iter.last_option += 1;

                break :r OptionResult{
                    .opt = target_opt,
                    .optarg = std.mem.sliceTo(optarg, 0),
                };
            } else OptionResult{
                .opt = target_opt,
                .optarg = null,
            };

            if (iter.last_option_idx > 0 and iter.last_option_idx == opt.len - 1) {
                iter.last_option += 1;
                iter.last_option_idx = 0;
            }

            return retval;
        }
    };

    pub fn long_option(name: []const u8, short_alias: ?u8, has_arg: bool) Option {
        return .{
            .name = name,
            .flag = short_alias,
            .has_arg = has_arg,
        };
    }

    pub fn short_option(flag: u8, has_arg: bool) Option {
        return .{
            .name = null,
            .flag = flag,
            .has_arg = has_arg,
        };
    }

    pub fn getopt(args: [][*:0]u8, opts: []const Option) ArgvOptionsIterator {
        return .{
            .known_options = opts,
            .argv = args,
        };
    }
};

pub const parsers = .{
    .FILE = clap.parsers.string,
    .ARG = clap.parsers.string,
    .INT = clap.parsers.int(u8, 10),
};

fn ResultType(comptime params: anytype) type {
    return clap.Result(clap.Help, &params, &parsers);
}

pub const LoadResult = struct {
    alloc: std.mem.Allocator,

    rom: *[uxn.Cpu.page_size]u8,
    debug_symbols: ?Debug,

    pub fn deinit(res: *LoadResult) void {
        res.alloc.free(res.rom);

        if (res.debug_symbols) |debug|
            debug.unload();
    }
};

pub fn handle_common_args(
    clap_res: anytype,
    params: anytype,
) ?u8 {
    const stderr = std.io.getStdErr().writer();

    if (clap_res.args.help != 0) {
        clap.help(stderr, clap.Help, &params, .{}) catch {};

        return 0;
    }

    if (clap_res.positionals.len < 1) {
        stderr.print("Usage: {s} ", .{os.argv[0]}) catch {};
        clap.usage(stderr, clap.Help, &params) catch {};
        stderr.print("\n", .{}) catch {};

        return 0;
    }

    return null;
}

pub fn load_or_assemble_rom(
    alloc: std.mem.Allocator,
    input_source: []const u8,
    debug_source: ?[]const u8,
) !LoadResult {
    const cwd = std.fs.cwd();
    const input_file = try cwd.openFile(input_source, .{});

    defer input_file.close();

    if (build_options.enable_jit_assembly and
        std.ascii.endsWithIgnoreCase(input_source, ".tal"))
    {
        var assembler = uxn_asm.Assembler(.{}).init(alloc, cwd);
        defer assembler.deinit();

        var rom_data = try alloc.create([uxn.Cpu.page_size]u8);
        var rom_writer = std.io.fixedBufferStream(rom_data);

        @memset(rom_data[0..], 0x00);

        assembler.include_follow = false;
        assembler.default_input_filename = input_source;

        assembler.assemble(
            input_file.reader(),
            rom_writer.writer(),
            rom_writer.seekableStream(),
        ) catch |err| {
            assembler.issue_diagnostic(err, std.io.getStdErr().writer()) catch {};

            alloc.free(rom_data);

            return error.AssemblyFailed;
        };

        return .{
            .alloc = alloc,

            .rom = rom_data,

            .debug_symbols = if (debug_source) |_| r: {
                var fifo = std.fifo.LinearFifo(u8, .Dynamic).init(alloc);
                defer fifo.deinit();

                try assembler.generate_symbols(fifo.writer());

                break :r try Debug.load_symbols(alloc, fifo.reader());
            } else null,
        };
    } else {
        return .{
            .alloc = alloc,

            .rom = try uxn.load_rom(alloc, input_file),

            .debug_symbols = if (debug_source) |debug_symbols| r: {
                const symbols_file = try cwd.openFile(debug_symbols, .{});
                defer symbols_file.close();

                break :r try Debug.load_symbols(alloc, symbols_file.reader());
            } else null,
        };
    }
}
