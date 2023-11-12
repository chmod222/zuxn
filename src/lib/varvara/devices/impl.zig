const Cpu = @import("uxn-core").Cpu;

pub fn DeviceMixin(comptime Self: type) type {
    return struct {
        pub fn port_address(dev: *const Self, port: u4) u8 {
            return @as(u8, dev.addr) << 4 | port;
        }

        pub inline fn load_port(
            dev: *const Self,
            comptime T: type,
            cpu: *const Cpu,
            port: u4,
        ) T {
            return cpu.load_device_mem(T, dev.port_address(port));
        }

        pub inline fn store_port(
            dev: *const Self,
            comptime T: type,
            cpu: *Cpu,
            port: u4,
            value: T,
        ) void {
            cpu.store_device_mem(T, dev.port_address(port), value);
        }
    };
}
