const std = @import("std");

pub fn Impl(comptime Self: type) type {
    return struct {
        pub const Wrapper = NoopWrapper;

        pub fn open_readable(dev: *Self, path: []const u8) !Wrapper {
            _ = dev;
            _ = path;

            return error.NotImplemented;
        }

        pub fn open_writable(dev: *Self, path: []const u8, truncate: bool) !Wrapper {
            _ = dev;
            _ = path;
            _ = truncate;

            return error.NotImplemented;
        }

        pub fn delete_file(dev: *Self, path: []const u8) !void {
            _ = dev;
            _ = path;

            return error.NotImplemented;
        }
    };
}

const NoopWrapper = struct {
    pub fn read(self: *@This(), buf: []u8) !u16 {
        _ = self;
        _ = buf;

        unreachable;
    }

    pub fn write(self: *@This(), buf: []const u8) !u16 {
        _ = self;
        _ = buf;

        unreachable;
    }

    pub fn close(self: *@This()) void {
        _ = self;

        unreachable;
    }
};
