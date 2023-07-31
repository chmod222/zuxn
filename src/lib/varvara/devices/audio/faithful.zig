// The "faithful" audio implementation is based on a ziggyfied but mostly
// 1:1 port of audio.c from the reference uxnemu implementation. It sounds
// the same, as it is based on on the same code, but I don't really understand
// the way it works and I like to use code I understand a bit more even if it's
// not a perfect replication.
const std = @import("std");

pub fn Impl(comptime Self: type) type {
    return struct {
        position: usize = 0,

        count: usize = 0,
        advance: usize = 0,
        period: usize = 0,

        const advances: [12]u32 = .{
            0x80000,
            0x879c8,
            0x8facd,
            0x9837f,
            0xa1451,
            0xaadc1,
            0xb504f,
            0xbfc88,
            0xcb2ff,
            0xd7450,
            0xe411f,
            0xf1a1c,
        };

        const note_period = Self.sample_rate * 0x4000 / 11025;

        pub fn setup_sound(dev: *Self) void {
            const pitch = dev.pitch.?;

            const octave: u5 = @truncate(pitch.note / 12);
            const note = pitch.note % 12;

            dev.impl.advance = advances[note] >> (8 - octave);
            dev.impl.position = 0;
            dev.impl.count = 0;

            if (dev.sample.len <= 0x100)
                dev.impl.period = note_period * 337 / 2 / dev.sample.len
            else
                dev.impl.period = note_period;
        }

        pub fn get_playback_position(dev: *Self) u16 {
            return @truncate(dev.impl.position);
        }

        pub fn advance_position(dev: *Self) void {
            dev.impl.position += (dev.impl.count + dev.impl.advance) / dev.impl.period;
            dev.impl.position %= dev.sample.len;

            dev.impl.count = (dev.impl.count + dev.impl.advance) % dev.impl.period;
        }
    };
}
