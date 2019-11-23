const std = @import("std");
const AdaptiveMutex = @import("./mutex.zig").Mutex;

pub fn main() !void {
    const thread_count = try std.Thread.cpuCount();
    const allocator = std.heap.direct_allocator;
    var threads = try allocator.alloc(*std.Thread, thread_count);
    defer allocator.free(threads);

    const iterations = [_]u128{
        1000,
        10 * 1000,
        100 * 1000,
        1000 * 1000,
        1 * 1000 * 1000,
        10 * 1000 * 1000,
        // 100 * 1000 * 1000,
    };

    while (true) {
    inline for (iterations) |iters| {
        std.debug.warn(("-" ** 20) ++ "\n");
        std.debug.warn("{} Iterations\n", iters);
        std.debug.warn(("-" ** 20) ++ "\n");
        const std_time = try bench(threads, BenchContention(std.Mutex, iters));
        const custom_time = try bench(threads, BenchContention(AdaptiveMutex, iters));
        const improvement = @intToFloat(f64, std_time) / @intToFloat(f64, custom_time);
        std.debug.warn("Relative improvement: {d:.2}x\n", improvement);
    }
    }
}

fn bench(threads: []*std.Thread, comptime BenchCase: type) !u64 {
    var bench_case: BenchCase = undefined;
    bench_case.init();
    defer bench_case.deinit();

    var timer = try std.time.Timer.start();
    for (threads) |*t|
        t.* = try std.Thread.spawn(&bench_case, BenchCase.run);
    for (threads) |t|
        t.wait();
    
    const elapsed_ms = @divFloor(timer.read(), std.time.millisecond);
    std.debug.warn("{} took {} ms\n", BenchCase.name, elapsed_ms);
    return elapsed_ms;
}

fn BenchContention(comptime Mutex: type, comptime limit: comptime_int) type {
    return struct {
        value: u128,
        mutex: Mutex,
        const name = if (Mutex == std.Mutex) "std.Mutex    " else "AdaptiveMutex";

        pub fn init(self: *@This()) void {
            self.value = 0;
            self.mutex = Mutex.init();
        }

        pub fn deinit(self: *@This()) void {
            self.mutex.deinit();
        }

        pub fn run(self: *@This()) void {
            while (true) {
                const held = self.mutex.acquire();
                defer held.release();
                if (self.value == limit)
                    return;
                self.value += 1;
            }
        }
    };
}