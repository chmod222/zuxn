const std = @import("std");

const Envelope = @import("Envelope.zig");

data: []const u8,

position: f32,
increment: f32,
loop_len: f32,

envelope: Envelope,

pub fn getNextSample(sample: *@This()) ?f32 {
    if (sample.position >= @as(f32, @floatFromInt(sample.data.len))) {
        if (sample.loop_len == 0) {
            return null;
        }

        while (sample.position >= @as(f32, @floatFromInt(sample.data.len))) {
            sample.position -= sample.loop_len;
        }
    }

    defer sample.advance();

    const p1: usize = @intFromFloat(sample.position);
    const raw: f32 = @floatFromInt(@as(i8, @bitCast(sample.data[p1] ^ 0x80)));

    return raw * std.math.clamp(sample.envelope.vol, 0.0, 1.0);
}

fn advance(sample: *@This()) void {
    sample.position += sample.increment;
    sample.envelope.advance();
}
