const std = @import("std");

pub fn main() void {
    //std.debug.warn("{:>4}|{:>4}|\n", .{"hi", "world"});
    var timer = std.time.Timer.start() catch unreachable;

    const s = timer.read();
    _ = timer.read();
    const e = timer.read();
    std.debug.warn("read(): {}ns\n", .{e - s});

    const LOADS = 1000;
    var thing: usize = undefined;
    const start = timer.read();
    for (@as([LOADS]void, undefined)) |_|
        _ = @ptrCast(*volatile usize, &thing).*;
    const stop = timer.read();
    std.debug.warn("{} loads: {}ns\n", .{LOADS, stop - start});

    const loads = (stop - start) - (e - s);
    std.debug.warn("{} loads / ns\n", .{
        @floatToInt(u64, @ceil(@intToFloat(f64, loads) / LOADS))
    });

    std.debug.warn("{}", .{switch (std.builtin.os.tag) {
        .windows => "is_windows",
        else => "aint_windows",
    }});
}