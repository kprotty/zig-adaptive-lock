const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const ResetEvent = @import("./reset_event.zig").ResetEvent;

/// Lock may be held only once. If the same thread
/// tries to acquire the same mutex twice, it deadlocks.
/// This type supports static initialization and is based off of Webkit's WTF Lock (via rust parking_lot)
/// https://github.com/Amanieu/parking_lot/blob/master/core/src/word_lock.rs
/// When an application is built in single threaded release mode, all the functions are
/// no-ops. In single threaded debug mode, there is deadlock detection.
pub const Mutex = if (builtin.single_threaded)
    struct {
        lock: @TypeOf(lock_init),

        const lock_init = if (std.debug.runtime_safety) false else {};

        pub const Held = struct {
            mutex: *Mutex,

            pub fn release(self: Held) void {
                if (std.debug.runtime_safety) {
                    self.mutex.lock = false;
                }
            }
        };
        pub fn init() Mutex {
            return Mutex{ .lock = lock_init };
        }
        pub fn deinit(self: *Mutex) void {}

        pub fn acquire(self: *Mutex) Held {
            if (std.debug.runtime_safety and self.lock) {
                @panic("deadlock detected");
            }
            return Held{ .mutex = self };
        }
    }
else
    struct {
        state: usize,

        const MUTEX_LOCK: usize = 1;
        const QUEUE_LOCK: usize = 2;
        const QUEUE_MASK: usize = ~(MUTEX_LOCK | QUEUE_LOCK);

        fn yield() void {
            if (comptime std.Target.current.isWindows()) {
                std.SpinLock.yield(404);
            } else {
                std.os.sched_yield() catch std.SpinLock.yield(30);
            }
        }

        const Node = struct {
            next: ?*Node,
            event: ResetEvent,
        };

        pub fn init() Mutex {
            return Mutex{
                .state = 0
            };
        }
    
        pub fn deinit(self: *Mutex) void {
            self.* = undefined;
        }
    
        pub fn acquire(self: *Mutex) Held {
            if (@cmpxchgWeak(usize, &self.state, 0, MUTEX_LOCK, .Acquire, .Monotonic)) |current|
                self.acquireSlow(current);
            return Held{ .mutex = self };
        }

        fn acquireSlow(self: *Mutex, current_state: usize) void {
            @setCold(true);
            while (true) {
                var state = current_state;
                var spin_count: usize = 0;
                while (spin_count < 40) : (spin_count += 1) {
                    if ((state & MUTEX_LOCK) == 0) {
                        state = @cmpxchgWeak(usize, &self.state, state, state | MUTEX_LOCK, .Acquire, .Monotonic) orelse return;
                        std.SpinLock.yield(1);
                    } else if ((state & QUEUE_MASK) != 0) {
                        break;
                    } else {
                        yield();
                        state = @atomicLoad(usize, &self.state, .Monotonic);
                    }
                }

                var node: Node = undefined;
                node.event = ResetEvent.init();
                defer node.event.deinit();

                while (true) : (std.SpinLock.yield(1)) {
                    if ((state & MUTEX_LOCK) == 0) {
                        state = @cmpxchgWeak(usize, &self.state, state, state | MUTEX_LOCK, .Acquire, .Monotonic) orelse return;
                    } else {
                        node.next = @intToPtr(?*Node, state & QUEUE_MASK);
                        const new_state = @ptrToInt(&node) | (state & ~QUEUE_MASK);
                        state = @cmpxchgWeak(usize, &self.state, state, new_state, .Release, .Monotonic) orelse {
                            node.event.wait();
                            break;
                        };
                    }
                }
            }
        }
    
        pub const Held = struct {
            mutex: *Mutex,
    
            pub fn release(self: Held) void {
                const state = @atomicRmw(usize, &self.mutex.state, .Sub, MUTEX_LOCK, .Release);
                if ((state & QUEUE_LOCK) == 0 and (state & QUEUE_MASK) != 0)
                    self.mutex.releaseSlow(state);
            }
        };

        fn releaseSlow(self: *Mutex, current_state: usize) void {
            @setCold(true);
            var state = current_state;
            while (true) : (std.SpinLock.yield(1)) {
                if ((state & QUEUE_LOCK) != 0 or (state & QUEUE_MASK) == 0)
                    return;
                state = @cmpxchgWeak(usize, &self.state, state, state | QUEUE_LOCK, .Acquire, .Monotonic) orelse break;
            }

            while (true) : (yield()) {
                if ((state & MUTEX_LOCK) != 0) {
                    state = @cmpxchgWeak(usize, &self.state, state, state & ~QUEUE_LOCK, .Release, .Acquire) orelse return;
                } else {
                    const node = @intToPtr(*Node, state & QUEUE_MASK);
                    const new_state = @ptrToInt(node.next);
                    state = @cmpxchgWeak(usize, &self.state, state, new_state, .Release, .Acquire) orelse {
                        node.event.set();
                        return;
                    };
                }
            }
        }
    };

const TestContext = struct {
    mutex: *Mutex,
    data: i128,

    const incr_count = 10000;
};

test "std.Mutex" {
    var plenty_of_memory = try std.heap.direct_allocator.alloc(u8, 300 * 1024);
    defer std.heap.direct_allocator.free(plenty_of_memory);

    var fixed_buffer_allocator = std.heap.ThreadSafeFixedBufferAllocator.init(plenty_of_memory);
    var a = &fixed_buffer_allocator.allocator;

    var mutex = Mutex.init();
    defer mutex.deinit();

    var context = TestContext{
        .mutex = &mutex,
        .data = 0,
    };

    if (builtin.single_threaded) {
        worker(&context);
        testing.expect(context.data == TestContext.incr_count);
    } else {
        const thread_count = 10;
        var threads: [thread_count]*std.Thread = undefined;
        for (threads) |*t| {
            t.* = try std.Thread.spawn(&context, worker);
        }
        for (threads) |t|
            t.wait();

        testing.expect(context.data == thread_count * TestContext.incr_count);
    }
}

fn worker(ctx: *TestContext) void {
    var i: usize = 0;
    while (i != TestContext.incr_count) : (i += 1) {
        const held = ctx.mutex.acquire();
        defer held.release();

        ctx.data += 1;
    }
}