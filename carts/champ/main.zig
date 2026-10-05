const cart = @import("cart-api");
const std = @import("std");
const music = @import("music.zig");

comptime {
    cart.export_start_code();
}

const DisplayColor = cart.DisplayColor;

const W = cart.screen_width;
const H = cart.screen_height;
const HW = W / 2;
const HH = H / 2;

const white = DisplayColor{ .b = 31, .g = 63, .r = 31 };
const black = DisplayColor{ .b = 0, .g = 0, .r = 0 };
const gray = DisplayColor{ .b = 2, .g = 4, .r = 2 };
const lt_blue = DisplayColor{ .b = 31, .g = 15, .r = 7 };
const yellow = DisplayColor{ .b = 0, .g = 63, .r = 31 };
const orange: DisplayColor = .rgb(0xFF3F00);

// Compute equal temperment frequency from midi note number
// Compatible with fractional note numbers for microtonal adjustment
fn freqFromMidi(midi: f32) f32 {
    return 440.0 * @exp2((midi - 69.0) / 12.0);
}

fn midiFromFreq(freq: f32) f32 {
    return @mulAdd(f32, @log2(freq / 440.0), 12.0, 69.0);
}

const major = [_]u32{
    0,
    2,
    4,
    5,
    7,
    9,
    11,
    12,
};
const note_names_sharps: [12][]const u8 = .{
    "C",
    "C#",
    "D",
    "D#",
    "E",
    "F",
    "F#",
    "G",
    "G#",
    "A",
    "A#",
    "B",
};
const note_names_flats: [12][]const u8 = .{
    "C",
    "Db",
    "D",
    "Eb",
    "E",
    "F",
    "Gb",
    "G",
    "Ab",
    "A",
    "Bb",
    "B",
};
const major_scale_uses_sharps: [12]bool = .{
    true, // Techincally C major has neither sharps nor flats
    false, // Db major, though sometimes C# major
    true, // D major
    false, // Eb major
    true, // E major
    false, // F major
    false, // Can be either, F# major (#) or Gb major (b)
    true, // G major
    false, // Ab major
    true, // A major
    false, // Bb major
    true, // B major
};

const WaveShape = enum {
    square,
    triangle,
    sawtooth,
    sine,

    pub const num = @typeInfo(@This()).@"enum".field_names.len;
};

var active_wave_shape: WaveShape = .sawtooth;

var fundamental: u32 = 48;

const micros_per_note: u64 = 500_000; // 0.5 second per note
var change_time: u64 = 0;
var last_abs_time: u64 = 0;

var slider: f32 = 0.5;
var wait_for_initial_release_a = true;

// Buffer two frames of audio
var audio_sample_buf: [2 * cart.audio_sample_rate / 60]u8 align(8) = undefined;
var trombone_active: bool = false;
var audio_phase: u32 = 0;
var delta_phase: u32 = 0;

var samples_left_in_tick: u32 = 0;

fn update_audio() void {
    while (cart.audio_get_buffer(u8)) |buf| {
        mix_audio(buf);
        cart.audio_submit_samples(buf.len);
    }
}

fn mix_audio(buf: []u8) void {
    var buf_left = buf;
    while (buf_left.len > 0) {
        if (samples_left_in_tick == 0) {
            audio_tick();
            samples_left_in_tick = 44100/60;
        }

        const samples_to_mix = @min(buf_left.len, samples_left_in_tick);
        mix_audio_in_tick(buf_left[0..samples_to_mix]);
        samples_left_in_tick -= samples_to_mix;
        buf_left = buf_left[samples_to_mix..];
    }
}

fn mix_audio_in_tick(buf: []u8) void {
    for (buf) |*sample| {
        bass.phase +%= bass.delta_phase;
        if (bass.delta_freq != 0) {
            bass.freq += bass.delta_freq;
            bass.calc_delta_phase();
        }

        audio_phase +%= delta_phase;

        var result: u8 = 0;

        if (trombone_active) {
            result += @intCast((audio_phase >> 25) + (audio_phase >> 26));
        } else {
            result += 0x7F;
        }

        if (bass.freq != 0) {
            result += @intCast((bass.phase & 0x8000_0000) >> 25);
        } else {
            result += 0x20;
        }

        sample.* = result;
    }

}

const MultiTone = struct {
    loops: u32,
    // index of the tone to jump back to when a looping multitone ends
    loop_tone: usize = 0,
    outro_tone: usize = 0,
    tones: []const music.Tone,
    current_tone: usize = 0,
    current_tone_frame: u32 = 0,

    phase: u32 = 0,
    delta_phase: u32 = 0,
    freq: f32 = 0,
    delta_freq: f32 = 0,

    fn calc_delta_phase(f: *@This()) void {
        // phase_per_sample = phase_per_period * periods_per_second / samples_per_second
        f.delta_phase = @intFromFloat(@as(f64, 0x1_0000_0000) * @as(f64, f.freq) / @as(f64, cart.audio_sample_rate) + 0.5);
    }

    pub fn tick(mt: *MultiTone) void {
        if (mt.current_tone >= mt.tones.len) return;

        mt.current_tone_frame += 1;
        if (mt.current_tone_frame > mt.tones[mt.current_tone].duration) {
            mt.current_tone += 1;
            mt.current_tone_frame = 1;
            if (mt.current_tone >= mt.tones.len) {
                if (mt.loops > 0) {
                    mt.loops -= 1;
                    mt.current_tone = mt.loop_tone;
                } else if (mt.outro_tone != 0) {
                    mt.current_tone = mt.outro_tone;
                    mt.outro_tone = 0;
                } else {
                    mt.freq = 0;
                    mt.delta_freq = 0;
                    mt.phase = 0;
                    mt.delta_phase = 0;
                    return;
                }
            }
        }

        if (mt.current_tone_frame == 1) {
            const t = &mt.tones[mt.current_tone];
            if (t.frequency != 0) {
                const samples_per_tick = 44100/60;

                const has_sweep = (t.frequency & 0xFFFF_0000) != 0;

                const start_freq_hz: f32 = @floatFromInt(t.frequency & 0xFFFF);

                const end_freq_hz: f32 = if (!has_sweep)
                    start_freq_hz
                else
                    @floatFromInt(t.frequency >> 16);

                const freq_delta: f32 = if (has_sweep) blk: {
                    const duration_samples = t.duration * samples_per_tick;
                    break :blk (end_freq_hz - start_freq_hz) / @as(f32, @floatFromInt(duration_samples));
                } else 0;

                mt.freq = start_freq_hz;
                mt.delta_freq = freq_delta;
                mt.calc_delta_phase();
            } else {
                mt.freq = 0;
                mt.delta_freq = 0;
                mt.phase = 0;
                mt.delta_phase = 0;
            }
        }
    }
};

fn toneIndexAt(comptime tones: []const music.Tone, comptime ticks: u32) usize {
    var t: u32 = 0;
    for (tones, 0..) |tone, i| {
        if (t == ticks) return i;
        if (t > ticks) break;
        t += tone.duration;
    }
    @compileError(std.fmt.comptimePrint("tick {} is not the start of a tone", .{ticks}));
}

// loop back to where the melody comes in, skipping the intro
const start_menu_music_loop_tick = 480;
const outro_tick = 1200;

var bass: MultiTone = .{
    .loops = 1,
    .loop_tone = toneIndexAt(&music.bass, start_menu_music_loop_tick),
    .outro_tone = toneIndexAt(&music.bass, outro_tick),
    .tones = &music.bass,
};

var melody: MultiTone = .{
    .loops = 1,
    .loop_tone = toneIndexAt(&music.melody, start_menu_music_loop_tick),
    .outro_tone = toneIndexAt(&music.melody, outro_tick),
    .tones = &music.melody,
};

fn audio_tick() void {
    bass.tick();
    melody.freq += melody.delta_freq * (44100/60);
    melody.tick();
}

// Approximated fixed-point sinewave, modified
// from https://www.coranac.com/2009/07/sines/
// Input is 0x00000000 - 0xFFFFFFFF representing
// one full rotation. Output is 0x00000000 for -1
// to 0xFFFFFFFF for 1
fn fast_sin(val: u32) u32 {
    // S(x) = x * ( (3<<p) - (x*x>>r) ) >> s
    // n : Q-pos for quarter circle             13
    // A : Q-pos for output                     12
    // p : Q-pos for parentheses intermediate   15
    // r = 2n-p                                 11
    // s = A-1-p-n                              17

    const qN = 13;
    const qP = 16;
    const qR = 2 * qN - qP;

    var x: i32 = @bitCast(val);

    if ((x ^ (x << 1)) < 0) // test for quadrant 1 or 2
        x = @as(i32, @bitCast(@as(u32, 1 << 31))) -% x;

    x = x >> 17;

    const sin_val = (x << 1) * ((3 << qP) - 1 - (x * x >> qR));
    return @as(u32, @bitCast(sin_val)) ^ 0x8000_0000;
}

pub fn start() void {
    change_time = cart.micros_since_boot() + micros_per_note;

    // Set Vsync for 60 FPS
    cart.set_vsync_enabled(1000.0 / 60.0);

    // Don't copy changes from one buffer to the next,
    // we will overwrite everything important every frame.
    // "everything important" is smaller than the whole
    // frame, so we also track a dirty rect.
    cart.set_double_buffer_mode(.{ .clear_full_frame = gray });

    cart.audio_set_buffer(u8, &audio_sample_buf);
}

var was_b = false;

const piano_min_note = 21;
const piano_max_note = 108;
const piano_max_fundamental = piano_max_note - 12;

const min_note = 54.0;
const max_note = min_note + 24;

const speed_unpressed_mul: f32 = 1.5;
const speed_brake_off: f32 = 1.0;
const speed_brake_full = 0.2;
const brake_delta = 2.0;
var brake_pct: f32 = 1.0;

pub fn update() void {
    const abs_time = cart.micros_since_boot();
    defer last_abs_time = abs_time;

    const delta_sec: f32 = @as(f32, @floatFromInt(abs_time - last_abs_time)) * 0.000_001;

    const controls = cart.controls;

    var selected_param: enum {
        octave,
        shape,
    } = .octave;

    if (controls.start) {
        selected_param = .shape;
    }

    if (!controls.a and wait_for_initial_release_a) {
        wait_for_initial_release_a = false;
    }

    if (trombone_active != controls.a and !wait_for_initial_release_a) {
        trombone_active = controls.a;
        brake_pct = if (controls.a) 1.0 else 0.0;
    }

    if (controls.b) {
        brake_pct = @max(0.0, brake_pct - delta_sec * brake_delta);
    } else {
        brake_pct = @min(1.0, brake_pct + delta_sec * brake_delta);
    }

    var speed = std.math.lerp(speed_brake_off, speed_brake_full, brake_pct);
    if (!controls.a) speed *= speed_unpressed_mul;

    if (controls.down) {
        slider = @max(0.0, slider - delta_sec * speed);
    }
    if (controls.up) {
        slider = @min(1.0, slider + delta_sec * speed);
    }

    const midi_note = std.math.lerp(min_note, max_note, slider);
    const frequency = freqFromMidi(midi_note);
    delta_phase = @intFromFloat(@as(f64, 0x1_0000_0000) * @as(f64, frequency) / @as(f64, cart.audio_sample_rate));

    draw_music_track();

    draw_slider(midi_note);

    update_audio();
}

fn draw_slider(midi_note: f32) void {
    cart.rect(.{
        .x = 8,
        .y = 10,
        .width = 2,
        .height = cart.screen_height - 20,
        .fill_color = orange,
    });

    const slider_y = screen_y_for_midi(midi_note);

    cart.oval(.{
        .x = 8 - 3,
        .y = slider_y - 4,
        .width = 8,
        .height = 8,
        .fill_color = if (trombone_active) lt_blue else orange,
        .stroke_color = white,
    });
}

fn draw_music_track() void {
    var mel = melody;

    for (10..cart.screen_width) |x| {
        mel.tick();

        if (mel.freq != 0) {
            const midi = midiFromFreq(mel.freq);
            const y = screen_y_for_midi(midi);
            if (y >= 2 and y < cart.screen_height - 2) {
                cart.framebuffer[x][@intCast(y-2)] = white;
                cart.framebuffer[x][@intCast(y-1)] = lt_blue;
                cart.framebuffer[x][@intCast(y+0)] = lt_blue;
                cart.framebuffer[x][@intCast(y+1)] = lt_blue;
                cart.framebuffer[x][@intCast(y+2)] = white;
            }
            mel.freq += mel.delta_freq * (44100/60);
        }
    }
}

fn screen_y_for_midi(midi: f32) i32 {
    const raw_pct = (midi - min_note) / @as(f32, max_note - min_note);
    const pct = std.math.clamp(raw_pct, 0.0, 1.0);
    const y_flt = std.math.lerp(@as(f32, cart.screen_height - 10), 10.0, pct);
    const y: i32 = @intFromFloat(@round(y_flt));
    return y;
}
