const Cpu = @import("uxn-core").Cpu;

const std = @import("std");
const logger = std.log.scoped(.uxn_varvara_mouse);

addr: u4,

pub const ports = struct {
    pub const vector = 0x0;
    pub const x = 0x2;
    pub const y = 0x4;
    pub const state = 0x6;
    pub const scroll_x = 0xa;
    pub const scroll_y = 0xc;
};

pub usingnamespace @import("impl.zig").DeviceMixin(@This());

pub const ButtonFlags = packed struct(u8) {
    left: bool,
    middle: bool,
    right: bool,
    _unused: u5,
};

pub fn intercept(
    dev: @This(),
    cpu: *Cpu,
    port: u4,
    kind: Cpu.InterceptKind,
) !void {
    _ = dev;
    _ = cpu;
    _ = port;
    _ = kind;
}

fn invoke_vector(dev: *@This(), cpu: *Cpu) !void {
    const vector = cpu.load_device_mem(u16, dev.port_address(ports.vector));

    if (vector > 0)
        try cpu.evaluate_vector(vector);
}

pub fn press_buttons(dev: *@This(), cpu: *Cpu, buttons: ButtonFlags) !void {
    const old_state = cpu.load_device_mem(u8, dev.port_address(ports.state));
    const new_state = old_state | @as(u8, @bitCast(buttons));

    logger.debug("Button State: {}", .{@as(ButtonFlags, @bitCast(new_state))});

    cpu.store_device_mem(u8, dev.port_address(ports.state), new_state);

    try dev.invoke_vector(cpu);
}

pub fn release_buttons(dev: *@This(), cpu: *Cpu, buttons: ButtonFlags) !void {
    const old_state = cpu.load_device_mem(u8, dev.port_address(ports.state));
    const new_state = old_state & ~@as(u8, @bitCast(buttons));

    logger.debug("Button State: {}", .{@as(ButtonFlags, @bitCast(new_state))});

    cpu.store_device_mem(u8, dev.port_address(ports.state), new_state);

    try dev.invoke_vector(cpu);
}

pub fn update_position(dev: *@This(), cpu: *Cpu, x: u16, y: u16) !void {
    logger.debug("Set position: X: {}; Y: {}", .{ x, y });

    cpu.store_device_mem(u16, dev.port_address(ports.x), x);
    cpu.store_device_mem(u16, dev.port_address(ports.y), y);

    try dev.invoke_vector(cpu);
}

pub fn update_scroll(dev: *@This(), cpu: *Cpu, x: i32, y: i32) !void {
    logger.debug("Scrolling: X: {}; Y: {}", .{ x, -y });

    cpu.store_device_mem(i16, dev.port_address(ports.scroll_x), @as(i16, @truncate(x)));
    cpu.store_device_mem(i16, dev.port_address(ports.scroll_y), @as(i16, @truncate(-y)));

    defer {
        cpu.store_device_mem(i16, dev.port_address(ports.scroll_x), 0);
        cpu.store_device_mem(i16, dev.port_address(ports.scroll_y), 0);
    }

    try dev.invoke_vector(cpu);
}
