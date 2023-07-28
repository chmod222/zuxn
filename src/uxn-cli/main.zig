const std = @import("std");

const uxn = @import("uxn-core");
const varvara = @import("uxn-varvara");

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
    var alloc = gpa.allocator();

    system = try varvara.VarvaraSystem.init(gpa.allocator());
    defer system.deinit();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    const rom_file = try std.fs.cwd().openFile(args[1], .{});
    defer rom_file.close();

    var rom = try uxn.load_rom(alloc, rom_file);
    var cpu = uxn.Cpu.init(rom);

    cpu.device_intercept = &intercept;

    cpu.output_intercepts = varvara.headless_intercepts.output;
    cpu.input_intercepts = varvara.headless_intercepts.input;

    system.console_device.set_argc(&cpu, args);

    const stdin = std.io.getStdIn().reader();

    cpu.evaluate_vector(0x0100) catch |fault|
        try system.system_device.handle_fault(&cpu, fault);

    system.console_device.push_arguments(&cpu, args) catch |fault|
        try system.system_device.handle_fault(&cpu, fault);

    if (system.system_device.exit_code) |c|
        return c;

    while (stdin.readByte() catch null) |b| {
        system.console_device.push_stdin_byte(&cpu, b) catch |fault|
            try system.system_device.handle_fault(&cpu, fault);

        if (system.system_device.exit_code) |c|
            return c;
    }

    return 0;
}
