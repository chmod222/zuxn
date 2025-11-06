const audio = @import("../audio.zig");
const AdsrFlags = audio.AdsrFlags;
const std = @import("std");

const step = 1.0 / 15.0;
const sample_rate = audio.sample_rate;

a: f32,
d: f32,
s: f32,
r: f32,

age: f32,

pub fn init(adsr: AdsrFlags) @This() {
    const attack = @as(f32, @floatFromInt(adsr.attack)) * step;
    const decay = @as(f32, @floatFromInt(adsr.decay)) * step;
    const sustain = @as(f32, @floatFromInt(adsr.sustain)) * step;
    const release = @as(f32, @floatFromInt(adsr.release)) * step;

    return @This(){
        .a = attack,
        .d = attack + decay,
        .s = attack + decay + sustain,
        .r = attack + decay + sustain + release,
        .age = 0.0,
    };
}

pub fn volume(env: *const @This()) f32 {
    return if (env.a == 0.0 and
        env.d == 0.0 and
        env.s == 0.0 and
        env.r == 0.0)
        1.0
    else if (env.age < env.a)
        env.age / env.a
    else if (env.age < env.d)
        0.5 * (2 * env.d - env.a - env.age) / (env.d - env.a)
    else if (env.age < env.s)
        0.5
    else if (env.age < env.r)
        0.5 * (env.r - env.age) / (env.r - env.s)
    else
        0.0;
}

pub fn isFinished(env: *const @This()) bool {
    return env.age >= env.r;
}

pub fn off(env: *@This()) void {
    env.age = env.r;
}

pub fn advance(env: *@This()) void {
    env.age += 1.0 / @as(f32, @floatFromInt(sample_rate));
}
