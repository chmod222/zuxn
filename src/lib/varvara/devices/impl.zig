const Cpu = @import("uxn-core").Cpu;

pub fn DeviceMixin(comptime Self: type) type {
    return struct {
        pub fn portAddress(dev: *const Self, port: u4) u8 {
            return @as(u8, dev.addr) << 4 | port;
        }

        pub inline fn loadPort(
            dev: *const Self,
            comptime T: type,
            cpu: *const Cpu,
            port: u4,
        ) T {
            return cpu.loadDeviceMem(T, dev.portAddress(port));
        }

        pub inline fn storePort(
            dev: *const Self,
            comptime T: type,
            cpu: *Cpu,
            port: u4,
            value: T,
        ) void {
            cpu.storeDeviceMem(T, dev.portAddress(port), value);
        }
    };
}
