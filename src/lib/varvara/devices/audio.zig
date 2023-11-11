const Cpu = @import("uxn-core").Cpu;

const std = @import("std");
const logger = std.log.scoped(.uxn_varvara_audio);

pub const sample_rate = 44100;
pub const sample_count = 256;

const timer: f32 = (@as(f32, @floatFromInt(sample_count)) / @as(f32, @floatFromInt(sample_rate))) * 1000.0;

pub const AdsrFlags = packed struct(u16) {
    release: u4,
    sustain: u4,
    decay: u4,
    attack: u4,
};

pub const PitchFlags = packed struct(u8) {
    midi_note: u7,
    dont_loop: bool,

    pub fn note(pitch: PitchFlags) u4 {
        return @truncate(pitch.midi_note % 12);
    }

    pub fn octave(pitch: PitchFlags) u4 {
        return @truncate(pitch.midi_note / 12);
    }
};

pub const VolumeFlags = packed struct(u8) {
    right: u4,
    left: u4,
};

pub const ports = struct {
    pub const vector = 0x0;
    pub const position = 0x2;
    pub const output = 0x4;
    pub const duration = 0x5;
    pub const adsr = 0x8;
    pub const length = 0xa;
    pub const addr = 0xc;
    pub const volume = 0xe;
    pub const pitch = 0xf;
};

const Sample = @import("audio/Sample.zig");
const Envelope = @import("audio/Envelope.zig");

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
    15.4338531643, // B -1
};

fn get_frequency(pitch: PitchFlags) f32 {
    const pitch_exponential: f32 = @floatFromInt(@as(u32, 2) << (pitch.octave() - 1));

    return base_frequencies[pitch.note()] * pitch_exponential;
}

fn get_duration(pitch: PitchFlags, sample: []const u8) f32 {
    const tone_freq = get_frequency(pitch);
    const base_freq = get_frequency(@bitCast(@as(u8, 60)));

    return @as(f32, @floatFromInt(sample.len)) / ((tone_freq / base_freq));
}

const pitch_names: [12][:0]const u8 = .{
    "C",
    "C♯ / D♭",
    "D",
    "D♯ / E♭",
    "E",
    "F",
    "F♯ / G♭",
    "G",
    "G♯ / A♭",
    "A",
    "A♯ / B♭",
    "B",
};

pub const Audio = struct {
    addr: u4,

    vol_left: f32 = 1.0,
    vol_right: f32 = 1.0,

    active_sample: ?Sample = null,
    next_sample: ?Sample = null,

    pitch: PitchFlags = undefined,
    duration: f32 = 0.0,

    pub usingnamespace @import("impl.zig").DeviceMixin(@This());

    pub fn get_output_vu(dev: *@This()) u8 {
        return if (dev.active_sample) |sample|
            @as(u8, @intFromFloat(sample.envelope.vol * 255))
        else
            0x00;
    }

    fn start_audio(dev: *@This(), cpu: *Cpu) void {
        var pitch: PitchFlags = @bitCast(cpu.load_device_mem(u8, dev.port_address(ports.pitch)));
        const duration: u16 = cpu.load_device_mem(u16, dev.port_address(ports.duration));

        const volume: VolumeFlags = @bitCast(cpu.load_device_mem(u8, dev.port_address(ports.volume)));
        const adsr: AdsrFlags = @bitCast(cpu.load_device_mem(u16, dev.port_address(ports.adsr)));

        const addr: u16 = cpu.load_device_mem(u16, dev.port_address(ports.addr));
        const len: u16 = cpu.load_device_mem(u16, dev.port_address(ports.length));

        const sample = cpu.mem[addr..addr +| len];

        if (pitch.midi_note == 0) {
            return dev.stop_note(duration);
        } else if (pitch.midi_note < 20 or len == 0) {
            pitch.midi_note = 20;
        }

        dev.next_sample = dev.start_note(
            pitch,
            duration,
            volume,
            adsr,
            sample,
        );
    }

    pub fn start_note(
        dev: *@This(),
        pitch: PitchFlags,
        duration: u16,
        volume: VolumeFlags,
        adsr: AdsrFlags,
        sample: []const u8,
    ) ?Sample {
        // Adjust the playback speed based on the sample rate and sample length, calculate
        // our frequency exponential for the octave.
        const rate_adjust: f32 = sample_rate / @as(f32, @floatFromInt(sample.len));

        // Select our pitch, scale it by octave and apply the detune factor.
        const tone_freq = get_frequency(pitch);

        const sample_data = Sample{
            .data = sample,
            .position = 0,
            .loop_len = @floatFromInt(if (pitch.dont_loop) 0 else sample.len),

            .increment = if (sample.len <= sample_count)
                tone_freq / rate_adjust
            else
                tone_freq / rate_adjust / (sample_rate / 1000),

            .envelope = Envelope.init(timer / sample_count, adsr),
        };

        dev.vol_left = @as(f32, @floatFromInt(volume.left)) / 15.0;
        dev.vol_right = @as(f32, @floatFromInt(volume.right)) / 15.0;

        dev.pitch = pitch;
        dev.duration = if (duration == 0)
            get_duration(pitch, sample)
        else
            @floatFromInt(duration);

        logger.debug("[Audio@{x}] Start playing {s} {d} ({x:0>2}); ADSR: {x:0>4}; Volume: {x:0>2}; Duration: {:.3}; SL = {x:0>4}; F = {d:.6}", .{
            dev.addr,
            pitch_names[pitch.note()],
            pitch.octave(),
            pitch.midi_note,
            @as(u16, @bitCast(adsr)),
            @as(u8, @bitCast(volume)),
            dev.duration,
            sample.len,
            tone_freq,
        });

        return sample_data;
    }

    pub fn stop_note(
        dev: *@This(),
        duration: u16,
    ) void {
        logger.debug("[Audio@{x}] Stop playing; Duration: {:.3}", .{
            dev.addr,
            duration,
        });

        if (dev.active_sample) |*s| {
            dev.duration = if (duration == 0)
                get_duration(@bitCast(@as(u8, 20)), s.data)
            else
                @floatFromInt(duration);

            s.envelope.off();
        }
    }

    pub fn update_duration(dev: *@This()) void {
        dev.duration -= timer;
    }

    pub fn evaluate_finish_vector(dev: *@This(), cpu: *Cpu) !void {
        const vector = cpu.load_device_mem(u16, dev.port_address(ports.vector));

        if (vector != 0x0000) {
            return cpu.evaluate_vector(vector);
        }
    }

    const crossfade_samples = 100;

    // Divide once at comptime so we only need to multiply below.
    const inv_crossfade: f32 = 1.0 / @as(f32, @floatFromInt(crossfade_samples * 2));

    pub fn render_audio(dev: *@This(), samples: []i16) void {
        var i: usize = 0;

        if (dev.next_sample) |*next_sample| {
            // Crossfade to next sample
            while (i < crossfade_samples * 2) : (i += 2) {
                // See how far along the cross-fade are we, from 0.0 -> 1.0 and
                // linearly interpolate between old and new.
                const f = @as(f32, @floatFromInt(i)) * inv_crossfade;

                const a = next_sample.get_next_sample() orelse 0.0;
                const b = if (dev.active_sample) |*as|
                    as.get_next_sample() orelse 0.0
                else
                    0.0;

                const next = (f * a) + ((1.0 - f) * b);

                for (0.., [2]f32{ dev.vol_left, dev.vol_right }) |j, v| {
                    samples[i + j] += @intFromFloat(next * v);
                }
            }

            dev.active_sample = next_sample.*;
            dev.next_sample = null;
        }

        if (dev.active_sample) |*active_sample| {
            while (i < samples.len) : (i += 2) {
                const sample = active_sample.get_next_sample() orelse {
                    break;
                };

                for (0.., [2]f32{ dev.vol_left, dev.vol_right }) |j, v| {
                    samples[i + j] += @intFromFloat(sample * v);
                }
            }
        }
    }

    pub fn intercept(
        dev: *@This(),
        cpu: *Cpu,
        port: u4,
        kind: Cpu.InterceptKind,
    ) !void {
        if (kind == .input) {
            if (port == ports.output) {
                cpu.store_device_mem(u8, dev.port_address(ports.output), dev.get_output_vu());
            } else if (port == ports.position or port == ports.position + 1) {
                if (dev.active_sample) |sample| {
                    cpu.store_device_mem(u16, dev.port_address(ports.position), @intFromFloat(sample.position));
                } else {
                    cpu.store_device_mem(u16, dev.port_address(ports.position), 0);
                }
            }
        } else if (kind == .output and port == ports.pitch) {
            dev.start_audio(cpu);

            //SDL.SDL_PauseAudioDevice(dev.audio_id, 0);
        }
    }
};
