// The "faithful" audio implementation is based on a ziggyfied but mostly
// 1:1 port of audio.c from the reference uxnemu implementation. It sounds
// the same, as it is based on on the same code, but I don't really understand
// the way it works and I like to use code I understand a bit more even if it's
// not a perfect replication.
const Impl = @This();
const Dev = @import("../Audio.zig");

const std = @import("std");

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

const note_period = Dev.sample_rate * 0x4000 / 11025;

pub fn setup_sound(
    impl: *Impl,
    dev: *Dev,
) void {
    const pitch = dev.pitch.?;

    const octave: u5 = @truncate(pitch.note / 12);
    const note = pitch.note % 12;

    impl.advance = advances[note] >> (8 - octave);
    impl.position = 0;
    impl.count = 0;

    if (dev.sample.len <= 0x100)
        impl.period = note_period * 337 / 2 / dev.sample.len
    else
        impl.period = note_period;
}

pub fn get_playback_position(impl: *Impl, dev: *Dev) u16 {
    _ = dev;

    return @truncate(impl.position);
}

pub fn advance_position(impl: *Impl, dev: *Dev) void {
    impl.position += (impl.count + impl.advance) / impl.period;
    impl.position %= dev.sample.len;

    impl.count = (impl.count + impl.advance) % impl.period;
}
