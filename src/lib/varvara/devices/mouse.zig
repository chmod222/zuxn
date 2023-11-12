const Cpu = @import("uxn-core").Cpu;

const std = @import("std");
const logger = std.log.scoped(.uxn_varvara_mouse);

pub const ButtonFlags = packed struct(u8) {
    left: bool,
    middle: bool,
    right: bool,
    _unused: u5,
};

pub const ports = struct {
    pub const vector = 0x0;
    pub const x = 0x2;
    pub const y = 0x4;
    pub const state = 0x6;
    pub const scroll_x = 0xa;
    pub const scroll_y = 0xc;
};

pub const Mouse = struct {
    addr: u4,

    pub usingnamespace @import("impl.zig").DeviceMixin(@This());

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
        const vector = dev.load_port(u16, cpu, ports.vector);

        if (vector > 0)
            try cpu.evaluate_vector(vector);
    }

    pub fn press_buttons(dev: *@This(), cpu: *Cpu, buttons: ButtonFlags) !void {
        const old_state = dev.load_port(u8, cpu, ports.state);
        const new_state = old_state | @as(u8, @bitCast(buttons));

        logger.debug("Button State: {}", .{@as(ButtonFlags, @bitCast(new_state))});

        dev.store_port(u8, cpu, ports.state, new_state);

        try dev.invoke_vector(cpu);
    }

    pub fn release_buttons(dev: *@This(), cpu: *Cpu, buttons: ButtonFlags) !void {
        const old_state = dev.load_port(u8, cpu, ports.state);
        const new_state = old_state & ~@as(u8, @bitCast(buttons));

        logger.debug("Button State: {}", .{@as(ButtonFlags, @bitCast(new_state))});

        dev.store_port(u8, cpu, ports.state, new_state);

        try dev.invoke_vector(cpu);
    }

    pub fn update_position(dev: *@This(), cpu: *Cpu, x: u16, y: u16) !void {
        logger.debug("Set position: X: {}; Y: {}", .{ x, y });

        dev.store_port(u16, cpu, ports.x, x);
        dev.store_port(u16, cpu, ports.y, y);

        try dev.invoke_vector(cpu);
    }

    pub fn update_scroll(dev: *@This(), cpu: *Cpu, x: i32, y: i32) !void {
        logger.debug("Scrolling: X: {}; Y: {}", .{ x, -y });

        dev.store_port(i16, cpu, ports.scroll_x, @as(i16, @truncate(x)));
        dev.store_port(i16, cpu, ports.scroll_y, @as(i16, @truncate(-y)));

        defer {
            dev.store_port(u16, cpu, ports.scroll_x, 0);
            dev.store_port(u16, cpu, ports.scroll_y, 0);
        }

        try dev.invoke_vector(cpu);
    }
};
