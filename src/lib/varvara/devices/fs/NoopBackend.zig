pub const NoopBackend = @This();

pub fn deinit(_: *NoopBackend) void {}

pub fn readFile(_: *NoopBackend, _: []const u8, _: []u8) !u16 {
    return 0;
}

pub fn writeFile(_: *NoopBackend, _: []const u8, _: []const u8, _: bool) !u16 {
    return 0;
}

pub fn deleteFile(_: *NoopBackend, _: []const u8) !void {}
