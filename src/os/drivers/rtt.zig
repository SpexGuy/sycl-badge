const std = @import("std");
const microzig = @import("microzig");
const rtt = microzig.cpu.rtt;

const rtt_instance = rtt.RTT(.{
    .up_channels = &.{
        .{ .name = "Tracy", .buffer_size = 2048, .mode = .NoBlockTrim },
    },
    //.down_channels = &.{},
    .exclusive_access = null,
    .linker_section = ".bss",
});

const tracy_chan = 0;

pub fn init() void {
    rtt_instance.init();
    rtt_initialized();
}

// Debugger can set a breakpoint here to pick up
// as soon as rtt is initialized.
noinline fn rtt_initialized() void {
    asm volatile ("");
}

pub fn write_blocking(text: []const u8) void {
    _ = rtt_instance.write(tracy_chan, text);
}
