const Cpu = @import("uxn-core").Cpu;

const std = @import("std");
const impl = @import("impl.zig");
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

fn getFrequency(pitch: PitchFlags) f32 {
    const pitch_exponential: f32 = @floatFromInt(@as(u32, 2) << (pitch.octave() - 1));

    return base_frequencies[pitch.note()] * pitch_exponential;
}

fn getDuration(pitch: PitchFlags, sample: []const u8) f32 {
    const tone_freq = getFrequency(pitch);
    const base_freq = getFrequency(@bitCast(@as(u8, 60)));

    return @as(f32, @floatFromInt(sample.len)) / (tone_freq / base_freq);
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
    device: impl.DeviceMixin,

    vol_left: f32 = 1.0,
    vol_right: f32 = 1.0,

    active_sample: ?Sample = null,
    next_sample: ?Sample = null,

    pitch: PitchFlags = undefined,
    duration: f32 = 0.0,

    pub fn getOutputVU(aud: *@This()) u8 {
        return if (aud.active_sample) |sample|
            @as(u8, @intFromFloat(sample.envelope.vol * 255))
        else
            0x00;
    }

    fn startAudio(aud: *@This(), cpu: *Cpu) void {
        var pitch = aud.device.loadPort(PitchFlags, cpu, ports.pitch);

        const volume = aud.device.loadPort(VolumeFlags, cpu, ports.volume);
        const adsr = aud.device.loadPort(AdsrFlags, cpu, ports.adsr);

        const duration = aud.device.loadPort(u16, cpu, ports.duration);
        const addr = aud.device.loadPort(u16, cpu, ports.addr);
        const len = aud.device.loadPort(u16, cpu, ports.length);

        const sample = cpu.mem[addr..addr +| len];

        if (pitch.midi_note == 0) {
            return aud.stopNote(duration);
        } else if (pitch.midi_note < 20 or len == 0) {
            pitch.midi_note = 20;
        }

        aud.next_sample = aud.startNote(
            pitch,
            duration,
            volume,
            adsr,
            sample,
        );
    }

    pub fn startNote(
        aud: *@This(),
        pitch: PitchFlags,
        duration: u16,
        volume: VolumeFlags,
        adsr: AdsrFlags,
        sample: []const u8,
    ) ?Sample {
        // Adjust the playback speed based on the sample rate and sample length, calculate
        // our frequency exponential for the octave.
        const rate_adjust: f32 = sample_rate / @as(f32, @floatFromInt(sample.len));
        const tone_freq = getFrequency(pitch);

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

        aud.vol_left = @as(f32, @floatFromInt(volume.left)) / 15.0;
        aud.vol_right = @as(f32, @floatFromInt(volume.right)) / 15.0;

        aud.pitch = pitch;
        aud.duration = if (duration == 0)
            getDuration(pitch, sample)
        else
            @floatFromInt(duration);

        logger.debug("[Audio@{x}] Start playing {s} {d} ({x:0>2}); ADSR: {x:0>4}; Volume: {x:0>2}; Duration: {:.3}; SL = {x:0>4}; F = {d:.6}", .{
            aud.device.addr,
            pitch_names[pitch.note()],
            pitch.octave(),
            pitch.midi_note,
            @as(u16, @bitCast(adsr)),
            @as(u8, @bitCast(volume)),
            aud.duration,
            sample.len,
            tone_freq,
        });

        return sample_data;
    }

    pub fn stopNote(
        aud: *@This(),
        duration: u16,
    ) void {
        logger.debug("[Audio@{x}] Stop playing; Duration: {:.3}", .{
            aud.device.addr,
            duration,
        });

        if (aud.active_sample) |*s| {
            aud.duration = if (duration == 0)
                getDuration(@bitCast(@as(u8, 20)), s.data)
            else
                @floatFromInt(duration);

            s.envelope.off();
        }
    }

    pub fn updateDuration(aud: *@This()) void {
        aud.duration -= timer;
    }

    pub fn evaluateFinishVector(aud: *@This(), cpu: *Cpu) !void {
        const vector = aud.device.loadPort(u16, cpu, ports.vector);

        if (vector != 0x0000) {
            return cpu.evaluateVector(vector);
        }
    }

    const crossfade_samples = 100;

    // Divide once at comptime so we only need to multiply below.
    const inv_crossfade: f32 = 1.0 / @as(f32, @floatFromInt(crossfade_samples * 2));

    pub fn renderAudio(aud: *@This(), samples: []i16) void {
        var i: usize = 0;

        if (aud.next_sample) |*next_sample| {
            // Crossfade to next sample
            while (i < crossfade_samples * 2) : (i += 2) {
                // See how far along the cross-fade are we, from 0.0 -> 1.0 and
                // linearly interpolate between old and new.
                const f = @as(f32, @floatFromInt(i)) * inv_crossfade;

                const a = next_sample.getNextSample() orelse 0.0;
                const b = if (aud.active_sample) |*as|
                    as.getNextSample() orelse 0.0
                else
                    0.0;

                const next = (f * a) + ((1.0 - f) * b);

                for (0.., [2]f32{ aud.vol_left, aud.vol_right }) |j, v| {
                    samples[i + j] += @intFromFloat(next * v);
                }
            }

            aud.active_sample = next_sample.*;
            aud.next_sample = null;
        }

        if (aud.active_sample) |*active_sample| {
            while (i < samples.len) : (i += 2) {
                const sample = active_sample.getNextSample() orelse {
                    break;
                };

                for (0.., [2]f32{ aud.vol_left, aud.vol_right }) |j, v| {
                    samples[i + j] += @intFromFloat(sample * v);
                }
            }
        }
    }

    pub fn intercept(
        aud: *@This(),
        cpu: *Cpu,
        port: u4,
        kind: Cpu.InterceptKind,
    ) !void {
        if (kind == .input) {
            if (port == ports.output) {
                aud.device.storePort(u8, cpu, ports.output, aud.getOutputVU());
            } else if (port == ports.position or port == ports.position + 1) {
                aud.device.storePort(
                    u16,
                    cpu,
                    ports.position,
                    if (aud.active_sample) |sample|
                        @intFromFloat(sample.position)
                    else
                        0,
                );
            }
        } else if (kind == .output and port == ports.pitch) {
            aud.startAudio(cpu);
        }
    }
};
