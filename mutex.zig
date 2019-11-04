const std = @import("std");
const builtin = @import("builtin");
const parker = @import("./parker.zig");
const testing = std.testing;

fn RawMutex(comptime Parker: type) type {
    if (builtin.single_threaded) {
        return struct {
            const lock_init = if (std.debug.runtime_safety) false else {};
            lock: @typeOf(lock_init),

            const ThisMutex = @This();
            pub const Held = struct {
                mutex: *ThisMutex,

                pub fn release(self: Held) void {
                    if (std.debug.runtime_safety)
                        self.mutex.lock = false;
                }
            };

            pub fn deinit(self: *@This()) void {}
            pub fn init() @This() {
                return @This(){ .lock = lock_init };
            }

            pub fn acquire(self: *@This()) Held {
                if (std.debug.runtime_safety and self.lock)
                    @panic("deadlock detected");
                return Held{ .mutex = self };
            }
        };
    }

    return struct {
        state: u32, // TODO: make this an enum
        parker: Parker,

        const Unlocked = 0;
        const Sleeping = 1;
        const Locked = 2;

        /// number of iterations to spin yielding to the cpu
        const SpinCpu = 4;

        /// number of iterations to spin yielding the thread
        const SpinThread = 1;

        /// number of iterations in the cpu yield loop
        const SpinCpuCount = 30;

        pub fn init() @This() {
            return @This(){
                .state = Unlocked,
                .parker = Parker.init(),
            };
        }

        pub fn deinit(self: *@This()) void {
            self.parker.deinit();
        }

        const ThisMutex = @This();
        pub const Held = struct {
            mutex: *ThisMutex,

            pub fn release(self: Held) void {
                switch (@atomicRmw(u32, &self.mutex.state, .Xchg, Unlocked, .Release)) {
                    Locked => {},
                    Sleeping => self.mutex.parker.wake(&self.mutex.state),
                    Unlocked => unreachable, // unlocking an unlocked mutex
                    else => unreachable, // should never be anything else
                }
            }
        };

        pub fn acquire(self: *@This()) Held {
            // Try and speculatively grab the lock.
            // If it fails, the state is either Locked or Sleeping
            // depending on if theres a thread stuck sleeping below.
            var state = @atomicRmw(u32, &self.state, .Xchg, Locked, .Acquire);
            if (state == Unlocked)
                return Held{ .mutex = self };

            while (true) {
                // try and acquire the lock using cpu spinning on failure
                for (([SpinCpu]void)(undefined)) |_| {
                    var value = @atomicLoad(u32, &self.state, .Monotonic);
                    while (value == Unlocked)
                        value = @cmpxchgWeak(u32, &self.state, Unlocked, state, .Acquire, .Monotonic) orelse return Held{ .mutex = self };
                    for (([SpinCpuCount]void)(undefined)) |_|
                        parker.Spin.yieldCpu();
                }

                // try and acquire the lock using thread rescheduling on failure
                for (([SpinThread]void)(undefined)) |_| {
                    var value = @atomicLoad(u32, &self.state, .Monotonic);
                    while (value == Unlocked)
                        value = @cmpxchgWeak(u32, &self.state, Unlocked, state, .Acquire, .Monotonic) orelse return Held{ .mutex = self };
                    parker.Spin.yieldThread();
                }

                // failed to acquire the lock, go to sleep until woken up by `Held.release()`
                if (@atomicRmw(u32, &self.state, .Xchg, Sleeping, .Acquire) == Unlocked)
                    return Held{ .mutex = self };
                state = Sleeping;
                self.parker.park(&self.state, Sleeping);
            }
        }
    };
}

/// Mutual exclusion lock where only one thread can hold it at a time.
/// If the same thread tries to acquire the same mutex without releasing, it deadlocks.
/// This type supports static initialization and the implementation is from
/// https://github.com/golang/go/blob/master/src/runtime/lock_futex.go
/// When an application is built in single threaded release mode, all mutex functions are no-ops.
/// When an application is built in single threaded debug/safe mode, there is deadlock detection.
pub const Mutex = RawMutex(parker.ThreadParker);

const TestContext = struct {
    mutex: Mutex,
    value: i128,
    
    pub const incr_count = 10000;

    pub fn run(self: *@This()) void {
        var i: usize = 0;
        while (i != incr_count) : (i += 1) {
            const held = self.mutex.acquire();
            defer held.release();

            self.value += 1;
        }
    }
};

test "std.Mutex" {
    // test the mutex implicitely in other data structures
    var plenty_of_memory = try std.heap.direct_allocator.alloc(u8, 300 * 1024);
    defer std.heap.direct_allocator.free(plenty_of_memory);
    var fixed_buffer_allocator = std.heap.ThreadSafeFixedBufferAllocator.init(plenty_of_memory);
    var a = &fixed_buffer_allocator.allocator;

    var context = TestContext{
        .mutex = Mutex.init(),
        .value = 0,
    };
    defer context.mutex.deinit();

    if (builtin.single_threaded) {
        context.run();
        testing.expect(context.value == TestContext.incr_count);
    } else {
        const thread_count = 10;
        var threads: [thread_count]*std.Thread = undefined;
        for (threads) |*t|
            t.* = try std.Thread.spawn(&context, TestContext.run);
        for (threads) |t|
            t.wait();
        testing.expect(context.value == thread_count * TestContext.incr_count);
    }
}
