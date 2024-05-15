const std = @import("std");
const cart = @import("cart-api");
const Lcd = @import("microzig").board.Lcd;
const rect = cart.rect;

const DisplayColor = cart.DisplayColor;

const bg_gray: DisplayColor = .{ .r = 6, .g = 12, .b = 6 };
const red: DisplayColor = .{ .r = 31, .g = 0, .b = 0 };
const green: DisplayColor = .{ .r = 0, .g = 63, .b = 0 };
const blue: DisplayColor = .{ .r = 0, .g = 0, .b = 31 };
const purple: DisplayColor = .{ .r = 16, .g = 0, .b = 31 };
const hot_pink: DisplayColor = .{ .r = 31, .g = 0, .b = 16 };
const sea_foam: DisplayColor = .{ .r = 0, .g = 63, .b = 16 };
const cyan: DisplayColor = .{ .r = 0, .g = 32, .b = 31 };
const key_lime: DisplayColor = .{ .r = 16, .g = 63, .b = 0 };
const orange: DisplayColor = .{ .r = 31, .g = 32, .b = 0 };
const white: DisplayColor = .{ .r = 31, .g = 63, .b = 31 };
const black: DisplayColor = .{ .r = 0, .g = 0, .b = 0 };

const num_states = 12;

const tile_colors = [num_states]DisplayColor{
    black,

    hot_pink,
    red,
    orange,
    key_lime,
    // 32
    green,
    sea_foam,
    cyan,
    blue,
    // 512
    purple,
    black,
    white,
};

const strings = [num_states][]const u8 {
    "",
    "3",
    "5",
    "9",
    "17",
    "33",
    "65",
    "129",
    "257",
    "513",
    "1025",
    "2049",
};

const font_colors = [num_states]DisplayColor{
    black,
    black,
    black,
    black,
    black,
    black,
    black,
    black,
    white,
    white,
    white,
    black,
};

var dirty = [_]u8{ 0 } ** 16;

var ticks: u32 = 0;

export fn start() void {}

const Scene = enum { none, intro, game };
var scene: Scene = .none;
var next_scene: Scene = .intro;

fn switchScene(new_scene: Scene) void {
    next_scene = new_scene;
}

export fn update() void {
    ticks +%= 1;
    first_frame = false;
    if (next_scene == .none) {
        next_scene = .intro;
    }
    if (next_scene != scene) {
        scene = next_scene;
        first_frame = true;
    }
    switch (scene) {
        .none => unreachable,
        .intro => scene_intro(),
        .game => scene_game(),
    }
}

const lines = &[_][]const u8{
    "Martin Wickham",
    "@Spex_guy",
    "",
    "SYCL24",
    "Press START",
};
const spacing = (cart.font_height * 4 / 3);

fn scene_intro() void {
    if (first_frame) {
        set_background();

        @memset(cart.neopixels, .{
            .r = 0,
            .g = 0,
            .b = 0,
        });

        // if (ticks / 128 == 0) {
        //     // Make the neopixel 24-bit color LEDs a nice Zig orange
        //     @memset(cart.neopixels, .{
        //         .r = 247,
        //         .g = 164,
        //         .b = 29,
        //     });
        // }

        const y_start = (cart.screen_height - (cart.font_height + spacing * (lines.len - 1))) / 2;

        // Write it out!
        for (lines, 0..) |line, i| {
            cart.text(.{
                .text_color = white,
                .str = line,
                .x = @intCast((cart.screen_width - cart.font_width * line.len) / 2),
                .y = @intCast(y_start + spacing * i),
            });
        }
    }

    // if (ticks == 0) cart.red_led.* = !cart.red_led.*;
    if (cart.controls.start) switchScene(.game);
}

var grid = [_]u32{0} ** 16;

var scene_changed: bool = false;
var first_frame = true;
var control_cooldown = false;
var dir: u8 = 0;
var num_moves: u8 = 0;

const State = enum { not_started, animating, idle };
var state: State = .not_started;

var rng: std.Random.DefaultPrng = undefined;

fn spawnTile() bool {
    var num: u32 = 0;
    for (&grid) |tile| {
        if (tile == 0) {
            num += 1;
        }
    }
    if (num == 0) return false;
    const selected = rng.next() % num;
    num = 0;
    for (&grid, 0..) |*tile, i| {
        if (tile.* == 0) {
            if (num == selected) {
                tile.* = 1;
                dirty[i] = 1;
                return true;
            }
            num += 1;
        }
    }
    unreachable;
}

fn processRow(base: usize, offsets: []const usize) bool {
    var i: usize = 0;
    var modified = false;
    while (i+1 < offsets.len) : (i += 1) {
        const left = &grid[base + offsets[i]];
        const right = &grid[base + offsets[i+1]];
        if (left.* == right.* and left.* != 0) {
            left.* += 1;
            right.* = 0;
            modified = true;
            dirty[base + offsets[i]] = 1;
            dirty[base + offsets[i+1]] = 1;
        } else if (left.* == 0 and right.* != 0) {
            left.* = right.*;
            right.* = 0;
            dirty[base + offsets[i]] = 1;
            dirty[base + offsets[i+1]] = 1;
            modified = true;
        }
    }
    return modified;
}

fn scene_game() void {
    // 160 x 128
    const tile_size = 20;
    const tile_stride = tile_size + 1;
    const top = cart.screen_height / 2 - 2 * tile_size - 2;
    const left = cart.screen_width / 2 - 2 * tile_size - 2;
    const grid_size = tile_stride * 4 - 1;

    if (first_frame) {
        set_background();

        const title = "2048++";
        cart.text(.{
            .text_color = .{ .r = 31, .g = 63, .b = 31 },
            .str = title,
            .x = @intCast((cart.screen_width - cart.font_width * title.len) / 2),
            .y = 10,
        });

        const instructions = "D-PAD";
        cart.text(.{
            .text_color = .{ .r = 31, .g = 63, .b = 31 },
            .str = instructions,
            .x = @intCast((cart.screen_width - cart.font_width * instructions.len) / 2),
            .y = cart.screen_height - cart.font_height - 10,
        });

        rect(.{
            .fill_color = sea_foam,
            .width = grid_size + 4,
            .height = grid_size + 4,
            .x = left - 2,
            .y = top - 2,
        });

        @memset(&grid, 0);
        @memset(&dirty, 1);
        rng = std.Random.DefaultPrng.init(ticks);
        _ = spawnTile();
        state = .idle;
    }

    if (state == .idle and !control_cooldown) {
        var num_controls: u8 = 0;
        if (cart.controls.right) { dir = 0; num_controls += 1; }
        if (cart.controls.down ) { dir = 1; num_controls += 1; }
        if (cart.controls.left ) { dir = 2; num_controls += 1; }
        if (cart.controls.up   ) { dir = 3; num_controls += 1; }
        if (num_controls == 1) {
            control_cooldown = true;
            state = .animating;
            num_moves = 0;
        }
    }

    control_cooldown = false;
    if (cart.controls.left or cart.controls.right or cart.controls.up or cart.controls.down or cart.controls.select) control_cooldown = true;

    if (state == .animating) {
        const offsets = [_][4]usize{
            [4]usize{ 3, 2, 1, 0 },
            [4]usize{12, 8, 4, 0 },
            [4]usize{ 0, 1, 2, 3 },
            [4]usize{ 0, 4, 8, 12},
        };
        var changed = false;
        for (&offsets[(dir + 1) & 3]) |base| {
            changed = processRow(base, &offsets[dir]) or changed;
        }
        if (!changed) {
            if (num_moves != 0 and !spawnTile()) {
                switchScene(.intro);
            }
            state = .idle;
        } else {
            num_moves += 1;
        }
    }
    
    var idx: usize = 0;
    for (0..4) |y| {
        for (0..4) |x| {
            if (dirty[idx] != 0) {
                dirty[idx] = 0;
                const cell = grid[idx];
                const tile_left = left + x * tile_stride;
                const tile_top = top + y * tile_stride;
                rect(.{
                    .fill_color = tile_colors[cell],
                    .x = @intCast(tile_left),
                    .y = @intCast(tile_top),
                    .width = tile_size,
                    .height = tile_size,
                });

                if (cell != 0) {
                    const str = strings[cell];
                    if (str.len == 4) {
                        cart.text(.{
                            .text_color = font_colors[cell],
                            .str = str[0..2],
                            .x = @intCast(tile_left + tile_size / 2 - cart.font_width),
                            .y = @intCast(tile_top + tile_size / 2 - cart.font_height),
                        });
                        cart.text(.{
                            .text_color = font_colors[cell],
                            .str = str[2..4],
                            .x = @intCast(tile_left + tile_size / 2 - cart.font_width),
                            .y = @intCast(tile_top + tile_size / 2),
                        });
                    } else {
                        cart.text(.{
                            .text_color = font_colors[cell],
                            .str = str,
                            .x = @intCast(tile_left + tile_size / 2 - str.len * cart.font_width / 2),
                            .y = @intCast(tile_top + tile_size / 2 - cart.font_height / 2),
                        });
                    }
                }
            }
            idx += 1;
        }
    }
}

fn set_background() void {
    @memset(cart.framebuffer, bg_gray);
}
