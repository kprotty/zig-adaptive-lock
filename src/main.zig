const std = @import("std");
const Standard = StdMutex;
const CustomMutex = @import("./linux.zig").Mutex; // @import("./mutex.zig").Mutex;

const StdMutex = struct {
    lock: u32,

    pub fn init() @This() {
        return @This(){ .lock = 0 };
    }

    pub fn deinit(self: *@This()) void {
        self.* = undefined;
    }

    pub fn acquire(self: *@This()) Held {
        while (@atomicRmw(u32, &self.lock, .Xchg, 1, .Acquire) != 0) {
            std.os.sched_yield() catch unreachable;
        }
        return Held{ .mutex = self };
    }

    pub const Held = struct {
        mutex: *StdMutex,

        pub fn release(self: Held) void {
            @atomicStore(u32, &self.mutex.lock, 0, .Release);
        }
    };
};

pub fn main() !void {
    const allocator = std.heap.direct_allocator;
    const thread_count = try std.Thread.cpuCount();
    var threads = try allocator.alloc(*std.Thread, thread_count);
    defer allocator.free(threads);

    inline for ([_]u128{
        1000,
        10 * 1000,
        100 * 1000,
        1000 * 1000,
        1 * 1000 * 1000,
        10 * 1000 * 1000,
        //100 * 1000 * 1000,
    }) |iters| {
        std.debug.warn(("-" ** 20) ++ "\n", .{});
        std.debug.warn("{} Iterations\n", .{iters});
        std.debug.warn(("-" ** 20) ++ "\n", .{});
        const std_time = try bench(threads, iters, Standard);
        const custom_time = try bench(threads, iters, CustomMutex);
        const improvement = @intToFloat(f64, std_time) / @intToFloat(f64, custom_time);
        std.debug.warn("Relative improvement: {d:.2}x\n", .{improvement});
    }
}

fn bench(threads: []*std.Thread, comptime iters: u128, comptime Mutex: type) !u64 {
    const Context = struct {
        mutex: Mutex,
        value: u128,
        timer: std.time.Timer,
        elapsed_ns: u64,

        fn run(self: *@This()) void {
            var signal_event = false;
            while (true) {
                var held = self.mutex.acquire();
                defer held.release();
                if (self.value == iters)
                    return;
                //var x: usize = undefined; for (@as([10]u8, undefined)) |_| _ = @atomicRmw(usize, &x, .Xchg, 1, .SeqCst);
                const is_done = self.value == iters - 1;
                self.value += 1;
                if (is_done) {
                    self.elapsed_ns = self.timer.read();
                }
            }
            
        }
    };

    var context = Context{
        .mutex = Mutex.init(),
        .value = 0,
        .timer = undefined,
        .elapsed_ns = 0,
    };
    defer context.mutex.deinit();

    var held = context.mutex.acquire();
    for (threads) |*t|
        t.* = try std.Thread.spawn(&context, Context.run);
    context.timer = try std.time.Timer.start();
    held.release();
    for (threads) |t|
        t.wait();

    const name = if (Mutex == Standard) "Standard" else "Custom  ";
    const elapsed_ms = @divFloor(context.elapsed_ns, std.time.millisecond);
    std.debug.warn("{} took {} ms\n", .{name, elapsed_ms});
    return elapsed_ms;
}
