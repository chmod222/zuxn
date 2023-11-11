const AdsrFlags = @import("../audio.zig").AdsrFlags;

a: f32,
d: f32,
s: f32,
r: f32,

vol: f32,

stage: enum {
    attack,
    decay,
    sustain,
    release,
},

pub fn init(timing: f32, adsr: AdsrFlags) @This() {
    const attack = @as(f32, @floatFromInt(adsr.attack)) * 64;
    const decay = @as(f32, @floatFromInt(adsr.decay)) * 64;
    const sustain = @as(f32, @floatFromInt(adsr.sustain)) / 16;
    const release = @as(f32, @floatFromInt(adsr.release)) * 64;

    var env = @This(){
        .a = 0.0,
        .d = timing / @max(10.0, decay),
        .s = sustain,
        .r = timing / @max(10.0, release),
        .vol = 0.0,
        .stage = .attack,
    };

    if (attack > 0) {
        env.a = timing / attack;
    } else if (env.stage == .attack) {
        env.stage = .decay;
        env.vol = 1.0;
    }

    return env;
}

pub fn off(env: *@This()) void {
    env.stage = .release;
}

pub fn advance(env: *@This()) void {
    switch (env.stage) {
        .attack => {
            env.vol += env.a;

            if (env.vol >= 1.0) {
                env.stage = .decay;
                env.vol = 1.0;
            }
        },

        .decay => {
            env.vol -= env.d;

            if (env.vol <= env.s or env.d <= 0.0) {
                env.stage = .sustain;
                env.vol = env.s;
            }
        },

        .sustain => {
            env.vol = env.s;
        },

        .release => {
            if (env.vol <= 0.0 or env.r <= 0.0) {
                env.vol = 0;
            } else {
                env.vol -= env.r;
            }
        },
    }
}
