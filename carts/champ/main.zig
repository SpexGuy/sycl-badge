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

var slider: f32 = 0.0;

// Buffer two frames of audio
var audio_sample_buf: [2 * cart.audio_sample_rate / 60]u8 align(8) = undefined;
var audio_active: bool = false;
var audio_phase: u32 = 0;
var delta_phase: u32 = 0;

var audio_time: u32 = 0;

fn update_audio() void {
    while (cart.audio_get_buffer(u8)) |buf| {
        mix_audio(buf);
        cart.audio_submit_samples(buf.len);
        audio_time +%= @intCast(buf.len);
    }
}

fn mix_audio(buf: []u8) void {
    if (!audio_active) {
        @memset(buf, 0x7F);
        return;
    }

    switch (active_wave_shape) {
        .square => for (buf) |*sample| {
            sample.* = if (audio_phase & 0x8000_0000 != 0) 0xFF else 0x00;
            audio_phase +%= delta_phase;
        },
        .sawtooth => for (buf) |*sample| {
            sample.* = @intCast(audio_phase >> 24);
            audio_phase +%= delta_phase;
        },
        .triangle => for (buf) |*sample| {
            // Similar to abs, but negative values are also shifted by 1, giving a more even
            // triangle that avoids 0x8000_0000 as a possible value
            const tri_val = if (audio_phase & 0x8000_0000 != 0) ~audio_phase else audio_phase;
            sample.* = @intCast(tri_val >> 23);
            audio_phase +%= delta_phase;
        },
        .sine => for (buf) |*sample| {
            sample.* = @intCast(fast_sin(audio_phase) >> 24);
            audio_phase +%= delta_phase;
        },
    }
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

    if (audio_active != controls.a) {
        audio_active = controls.a;
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
        .fill_color = if (audio_active) lt_blue else orange,
        .stroke_color = white,
    });
}

fn draw_music_track() void {
    const tune = &music.melody;
    var audio_frame = audio_time / (44100/60);
    var tune_i: u32 = 0;
    while (tune_i < tune.len and tune[tune_i].duration <= audio_frame) {
        audio_frame -= tune[tune_i].duration;
        tune_i += 1;
    }
    if (tune_i >= tune.len) return;

    for (10..cart.screen_width) |x| {
        const note = tune[tune_i];

        if (note.frequency != 0) {
            const start_freq: f32 = @floatFromInt(note.frequency & 0xFFFF);
            var end_freq: f32 = @floatFromInt(note.frequency >> 16);
            if (end_freq == 0) end_freq = start_freq;

            const note_pct = @as(f32, @floatFromInt(audio_frame)) / @as(f32, @floatFromInt(note.duration));
            const freq = std.math.lerp(start_freq, end_freq, note_pct);

            const midi = midiFromFreq(freq);
            const y = screen_y_for_midi(midi);
            if (y >= 2 and y < cart.screen_height - 2) {
                cart.framebuffer[x][@intCast(y-2)] = white;
                cart.framebuffer[x][@intCast(y-1)] = lt_blue;
                cart.framebuffer[x][@intCast(y+0)] = lt_blue;
                cart.framebuffer[x][@intCast(y+1)] = lt_blue;
                cart.framebuffer[x][@intCast(y+2)] = white;
            }
        }

        audio_frame += 1;
        while (audio_frame >= tune[tune_i].duration) {
            audio_frame -= tune[tune_i].duration;
            tune_i += 1;
            if (tune_i >= tune.len) return;
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
