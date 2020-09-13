const std = @import("std");
const runBench = @import("./bench.zig").runBenchmark;

pub fn main() !void {
    try runBench(struct {
        fn run(ctx: anytype) !void {
            try ctx.bench(@import("./mutexes/os.zig").Mutex);
            try ctx.bench(@import("./mutexes/showtime/tas.zig").Mutex);
        }
    }.run);
}

