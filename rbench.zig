const std = @import("std");
const Mutex = @import("mutex.zig").Mutex; //std.Mutex;

const MAX = 10 * 1000 * 1000;
const State = struct {
    mutex: Mutex,
    value: u128,

    fn run(self: *@This()) void {
        while (true) {
            const held = self.mutex.acquire();
            defer held.release();
            if (self.value >= MAX)
                return;
            self.value += 1;
        }
    }
};

pub fn main() !void {
    const num_threads = try std.Thread.cpuCount();
    var state = State{
        .mutex = Mutex.init(),
        .value = 0,
    };
    defer state.mutex.deinit();

    const allocator = std.heap.direct_allocator;
    const threads = try allocator.alloc(*std.Thread, num_threads);
    defer allocator.free(threads);

    for (threads) |*t|
        t.* = try std.Thread.spawn(&state, State.run);
    for (threads) |t|
        t.wait();
}