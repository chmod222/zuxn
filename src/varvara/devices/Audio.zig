const Cpu = @import("uxn-core").Cpu;
const std = @import("std");

const AudioImpl = @import("audio/DefaultImpl.zig");

pub const sample_rate = 44100;

addr: u4,

pitch: ?PitchFlags = null,
volume: VolumeFlags = undefined,
adsr: AdsrFlags = undefined,

sample: []u8 = undefined,
age: u32 = 0,

audio_impl: AudioImpl = .{},

pub const ports = struct {
    pub const vector = 0x0;
    pub const position = 0x2;
    pub const output = 0x4;
    pub const adsr = 0x8;
    pub const length = 0xa;
    pub const addr = 0xc;
    pub const volume = 0xe;
    pub const pitch = 0xf;
};

pub const AdsrFlags = packed struct(u16) {
    release: u4,
    sustain: u4,
    decay: u4,
    attack: u4,
};

pub const PitchFlags = packed struct(u8) {
    note: u7,
    dont_loop: bool,
};

pub const VolumeFlags = packed struct(u8) {
    right: u4,
    left: u4,
};

pub fn envelope(dev: *@This(), age: u32) u32 {
    // One step is one fifteenth of the frequency (or: second of time)
    // x * step = x * (44100 Hz / 15) = x * (2940 Hz)
    //
    // therefore (i.e): 0x4 * step = 11760 Hz
    // therefore 11760 Hz / 44100 Hz = 0.2666... s
    //
    // So an ADSR step of 0x0 is zero-length, a step of 0xf is a second.
    const step: u16 = sample_rate / 0xf;

    const attack = step * @as(u32, dev.adsr.attack);
    const decay = (step * @as(u32, dev.adsr.decay)) + attack;
    const sustain = (step * @as(u32, dev.adsr.sustain)) + decay;
    const release = (step * @as(u32, dev.adsr.release)) + sustain;

    // Released?
    if (release == 0)
        return 0x0888;

    // Attacking?
    if (age < attack)
        return (0x0888 * age) / attack;

    // Decaying?
    if (age < decay)
        return (0x0444 * (2 * decay - attack - age)) / (decay - attack);

    // Sustaining?
    if (age < sustain)
        return 0x0444;

    // Releasing?
    if (age < release)
        return (0x0444 * (release - age)) / (release - sustain);

    return 0x0000;
}

pub fn get_output_vu(dev: *@This()) u8 {
    var sums: [2]u32 = .{ 0, 0 };

    if (dev.pitch == null)
        return 0;

    const volumes: [2]u4 = .{ dev.volume.left, dev.volume.right };

    for (volumes, &sums) |volume, *sum| {
        if (volume == 0)
            continue;

        sum.* = 1 + (dev.envelope(dev.age) * volume) / 0x800;

        if (sum.* > 0xf)
            sum.* = 0xf;
    }

    return @bitCast(@as(u8, @truncate(sums[1] << 4)) | @as(u8, @truncate(sums[0])));
}

fn get_playback_position(dev: *@This()) u16 {
    return dev.audio_impl.get_playback_position(dev);
}

fn get_vu(dev: *@This()) u8 {
    return dev.get_output_vu();
}

fn start_audio(dev: *@This(), cpu: *Cpu) void {
    const base = @as(u8, dev.addr) << 4;

    const pitch: PitchFlags = @bitCast(cpu.load_device_mem(u8, base | ports.pitch));

    dev.volume = @bitCast(cpu.load_device_mem(u8, base | ports.volume));
    dev.adsr = @bitCast(cpu.load_device_mem(u16, base | ports.adsr));
    dev.pitch = pitch;

    const addr: u16 = cpu.load_device_mem(u16, base | ports.addr);
    const len: u16 = cpu.load_device_mem(u16, base | ports.length);

    dev.sample = cpu.mem[addr..addr +| len];

    // only play up to (excluding) C-8
    if (pitch.note >= 108 or len == 0) {
        dev.pitch = null;

        return;
    }

    dev.age = 0;
    dev.audio_impl.setup_sound(dev);
}

pub fn evaluate_finish_vector(dev: *@This(), cpu: *Cpu) !void {
    const vector = cpu.load_device_mem(u16, @as(u8, dev.addr) << 4 | ports.vector);

    if (vector != 0x0000)
        return cpu.evaluate_vector(vector);
}

pub fn render_audio(dev: *@This(), samples: []i16) ?bool {
    if (dev.pitch == null)
        return null;

    var i: usize = 0;

    while (i < samples.len) : (i += 2) {
        const pos = dev.get_playback_position();
        const sample: i8 = @bitCast(dev.sample[pos] +% 0x80);
        const sample_envelope: i32 = @as(i32, sample) * @as(i32, @bitCast(dev.envelope(dev.age)));

        dev.age += 1;
        dev.audio_impl.advance_position(dev);

        if (dev.get_playback_position() < pos and dev.pitch.?.dont_loop) {
            dev.pitch = null;

            break;
        }

        for (0.., [2]u4{ dev.volume.left, dev.volume.right }) |j, v|
            samples[i + j] += @intCast(@divFloor(sample_envelope * v, 0x180));
    }

    // envelope may have changed it
    if (dev.pitch == null) {
        return false;
    }

    return true;
}

pub fn intercept(
    dev: *@This(),
    cpu: *Cpu,
    port: u4,
    kind: Cpu.InterceptKind,
) !void {
    const base = @as(u8, dev.addr) << 4;

    if (kind == .input) {
        if (port == ports.output) {
            cpu.store_device_mem(u8, base | ports.output, dev.get_vu());
        } else if (port == ports.position or port == ports.position + 1) {
            cpu.store_device_mem(u16, base | ports.position, dev.get_playback_position());
        }
    } else if (kind == .output and port == ports.pitch) {
        dev.start_audio(cpu);

        //SDL.SDL_PauseAudioDevice(dev.audio_id, 0);
    }
}
