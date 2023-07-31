pub fn DeviceMixin(comptime Self: type) type {
    return struct {
        pub fn port_address(dev: *const Self, port: u4) u8 {
            return @as(u8, dev.addr) << 4 | port;
        }
    };
}
