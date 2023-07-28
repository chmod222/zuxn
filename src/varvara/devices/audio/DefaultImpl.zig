// The default audio implementation uses floating point arithmetic to precisely
// move the playhead within the sample based on the relative frequency of the selected
// pitch in regards to the assumed default sample pitch.
const Impl = @This();
const Dev = @import("../Audio.zig");

const std = @import("std");
const pow = std.math.pow;

factor: f32 = 0.0,

const base_frequencies: [12]f32 = .{
    8.1757989156, // C -1
    8.6619572180, // C# -1
    9.1770239974, // D -1
    9.7227182413, // D# -1
    10.3008611535, // E -1
    10.9133822323, // F -1
    11.5623257097, // F# -1
    12.2498573744, // G -1
    12.9782717994, // G# -1
    13.7500000000, // A -1
    14.5676175474, // A# -1
    15.4338531643, // B# -1
};

// Default *should* be C 4 (base_frequencies[0] * 2^5) but uxnemu sounds more like
// F 4 (base_frequencies[5] * 2^5)
const base_freq = base_frequencies[5] * pow(f32, 2, 5);

pub fn setup_sound(
    impl: *Impl,
    dev: *Dev,
) void {
    const pitch = dev.pitch.?;

    const octave: u5 = @truncate(pitch.note / 12);
    const note = pitch.note % 12;

    const tone_freq = base_frequencies[note] * pow(f32, 2, @as(f32, @floatFromInt(octave + 1)));

    impl.factor = tone_freq / base_freq;
}

pub fn get_playback_position(impl: *Impl, dev: *Dev) u16 {
    const exact_position: f32 = @as(f32, @floatFromInt(dev.age)) * impl.factor;

    return @truncate(@as(usize, @intFromFloat(exact_position)) % dev.sample.len);
}

pub fn advance_position(impl: *Impl, dev: *Dev) void {
    _ = impl;
    _ = dev;
}
