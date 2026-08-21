const Cpu = @import("uxn-core").Cpu;

pub const DeviceMixin = struct {
    addr: u4,

    pub fn init(addr: u4) DeviceMixin {
        return .{ .addr = addr };
    }

    pub fn portAddress(dev: *const DeviceMixin, port: u4) u8 {
        return @as(u8, dev.addr) << 4 | port;
    }

    pub inline fn loadPort(
        dev: *const DeviceMixin,
        comptime T: type,
        cpu: *const Cpu,
        port: u4,
    ) T {
        return cpu.loadDeviceMem(T, dev.portAddress(port));
    }

    pub inline fn loadSimdVector2(
        dev: *const DeviceMixin,
        comptime T: type,
        cpu: *const Cpu,
        xport: u4,
        yport: u4,
    ) @Vector(2, T) {
        return .{
            dev.loadPort(T, cpu, xport),
            dev.loadPort(T, cpu, yport),
        };
    }

    pub inline fn loadVector(
        dev: *const DeviceMixin,
        cpu: *const Cpu,
        port: u4,
    ) ?u16 {
        const vector = dev.loadPort(u16, cpu, port);

        return if (vector > 0) vector else null;
    }

    pub inline fn storePort(
        dev: *const DeviceMixin,
        comptime T: type,
        cpu: *Cpu,
        port: u4,
        value: T,
    ) void {
        cpu.storeDeviceMem(T, dev.portAddress(port), value);
    }
};
