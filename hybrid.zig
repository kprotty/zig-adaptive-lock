const std = @import("std");
const runBench = @import("./bench.zig").runBenchmark;

pub fn main() !void {
    try runBench(struct {
        fn run(ctx: anytype) !void {
            try ctx.bench(@import("./mutexes/os.zig").Mutex);
            try ctx.bench(@import("./mutexes/showtime/tas.zig").Mutex);
            try ctx.bench(@import("./mutexes/showtime/ttas.zig").Mutex);
            try ctx.bench(@import("./mutexes/showtime/ticket.zig").Mutex);
            try ctx.bench(@import("./mutexes/mcs.zig").Mutex);
            try ctx.bench(@import("./mutexes/showtime/hybrid.zig").Mutex);
        }
    }.run);
}

