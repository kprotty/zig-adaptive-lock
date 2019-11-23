const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const testing = std.testing;
const SpinLock = std.SpinLock;
const c = std.c;
const linux = std.os.linux;
const windows = std.os.windows;

pub const Event = switch (builtin.os) {
    .windows => WindowsEvent,
    .linux => if (builtin.link_libc) PosixEvent else LinuxEvent,
    else => if (builtin.link_libc) PosixEvent else SpinEvent,
};

const SpinEvent = struct {
    key: u8,

    pub fn init() SpinEvent {
        return SpinEvent{ .key = 0 };
    }

    pub fn deinit(self: *SpinEvent) void {
        self.* = undefined;
    }

    pub fn wait(self: *SpinEvent) void {
        var spin = SpinLock.Backoff.init();
        if (@atomicRmw(u8, &self.key, .Xchg, 1, .Acquire) != 2) {
            while (@atomicLoad(u8, &self.key, .Monotonic) == 1)
                spin.yield();
        }
    }

    pub fn set(self: *SpinEvent) void {
        @atomicStore(u8, &self.key, 2, .Release);
    }
};

const LinuxEvent = struct {
    key: i32,

    pub fn init() LinuxEvent {
        return LinuxEvent{ .key = 0 };
    }

    pub fn deinit(self: *LinuxEvent) void {
        self.* = undefined;
    }

    pub fn wait(self: *LinuxEvent) void {
        if (@atomicRmw(i32, &self.key, .Xchg, 1, .Acquire) == 2)
            return;
        while (@atomicLoad(i32, &self.key, .Monotonic) == 1) {
            const rc = linux.futex_wait(&self.key, linux.FUTEX_WAIT | linux.FUTEX_PRIVATE_FLAG, 1, null);
            switch (linux.getErrno(rc)) {
                0, linux.EAGAIN => return,
                linux.EINTR => continue,
                linux.EINVAL => unreachable,
                linux.ETIMEDOUT => unreachable,
                else => unreachable,
            }
        }
    }

    pub fn set(self: *LinuxEvent) void {
        if (@atomicRmw(i32, &self.key, .Xchg, 2, .Release) == 1) {
            const rc = linux.futex_wake(&self.key, linux.FUTEX_WAKE | linux.FUTEX_PRIVATE_FLAG, 1);
            assert(linux.getErrno(rc) == 0);
        }
    }
};

const PosixEvent = struct {
    is_set: bool,
    cond: c.pthread_cond_t,
    mutex: c.pthread_mutex_t,

    pub fn init() PosixEvent {
        return PosixEvent{
            .is_set = false,
            .cond = c.PTHREAD_COND_INITIALIZER,
            .mutex = c.PTHREAD_MUTEX_INITIALIZER,
        };
    }

    pub fn deinit(self: *PosixEvent) void {
        // On dragonfly, the destroy functions return EINVAL if they were initialized statically.
        const retm = c.pthread_mutex_destroy(&self.mutex);
        assert(retm == 0 or retm == (if (builtin.os == .dragonfly) os.EINVAL else 0));
        const retc = c.pthread_cond_destroy(&self.cond);
        assert(retc == 0 or retc == (if (builtin.os == .dragonfly) os.EINVAL else 0));
    }

    pub fn wait(self: *PosixEvent) void {
        assert(c.pthread_mutex_lock(&self.mutex) == 0);
        defer assert(c.pthread_mutex_unlock(&self.mutex) == 0);
        while (!self.is_set)
            assert(c.pthread_cond_wait(&self.cond, &self.mutex) == 0);        
    }

    pub fn set(self: *PosixEvent) void {
        assert(c.pthread_mutex_lock(&self.mutex) == 0);
        defer assert(c.pthread_mutex_unlock(&self.mutex) == 0);
        self.is_set = true;
        assert(c.pthread_cond_signal(&self.cond) == 0);
    }
};

const WindowsEvent = struct {
    key: u32,

    pub fn init() WindowsEvent {
        return WindowsEvent{ .key = 0 };
    }

    pub fn deinit(self: *WindowsEvent) void {
        self.* = undefined;
    }

    pub fn wait(self: *WindowsEvent) void {
        if (@atomicRmw(u32, &self.key, .Xchg, 1, .Acquire) == 2)
            return;
        if (getEventHandle()) |handle| {
            const key = @ptrCast(*const c_void, &self.key);
            const rc = windows.ntdll.NtWaitForKeyedEvent(handle, key, windows.FALSE, null);
            assert(rc == 0);
        } else {
            var spin = SpinLock.Backoff.init();
            while (@atomicLoad(u32, &self.key, .Monotonic) == 1)
                spin.yield();
        }
    }

    pub fn set(self: *WindowsEvent) void {
        if (@atomicRmw(u32, &self.key, .Xchg, 2, .Acquire) == 1) {
            if (getEventHandle()) |handle| {
                const key = @ptrCast(*const c_void, &self.key);
                const rc = windows.ntdll.NtReleaseKeyedEvent(handle, key, windows.FALSE, null);
                assert(rc == 0);
            }
        }
    }

    var event_state = EventState.Uninitialized;
    var event_handle: windows.HANDLE = undefined;

    const EventState = enum(u32) {
        Uninitialized,
        Initializing,
        Initialized,
    };

    fn getEventHandle() ?windows.HANDLE {
        while (true) {
            var state = @atomicLoad(EventState, &event_state, .Monotonic);
            if (state == .Initialized) {
                return if (event_handle == windows.INVALID_HANDLE_VALUE) null else event_handle;
            }
            
            if (state == .Uninitialized) {
                state = @cmpxchgWeak(EventState, &event_state, .Uninitialized, .Initializing, .Acquire, .Monotonic) orelse {
                    const access_mask = windows.GENERIC_READ | windows.GENERIC_WRITE;
                    if (windows.ntdll.NtCreateKeyedEvent(&event_handle, access_mask, null, 0) != 0)
                        event_handle = windows.INVALID_HANDLE_VALUE;
                    @atomicStore(EventState, &event_state, .Initialized, .Release);
                    continue;
                };
            }

            var spin = SpinLock.Backoff.init();
            while (state == .Initializing) {
                spin.yield();
                state = @atomicLoad(EventState, &event_state, .Monotonic);
            }
        }
    }
};

pub const Mutex = struct {
    state: usize,

    const MUTEX_LOCK: usize = 1 << 0;
    const QUEUE_LOCK: usize = 1 << 1;
    const QUEUE_MASK: usize = ~(MUTEX_LOCK | QUEUE_LOCK);

    const QueueNode = struct {
        next: ?*QueueNode,
        event: Event,
    };

    pub fn init() Mutex {
        return Mutex{ .state = 0 };
    }

    pub fn deinit(self: *Mutex) void {
        self.* = undefined;
    }

    pub const Held = struct {
        mutex: *Mutex,

        pub fn release(self: Held) void {
            const state = @atomicRmw(usize, &self.mutex.state, .Sub, MUTEX_LOCK, .Release);
            if ((state & QUEUE_MASK) != 0 and (state & QUEUE_LOCK) == 0)
                self.mutex.releaseSlow(state);
        }
    };

    pub fn acquire(self: *Mutex) Held {
        if (@cmpxchgWeak(usize, &self.state, 0, MUTEX_LOCK, .Acquire, .Monotonic)) |current_state|
            self.acquireSlow(current_state);
        return Held{ .mutex = self };
    }

    fn acquireSlow(self: *Mutex, current_state: usize) void {
        var spin: usize = 0;
        var state = current_state;
        while (true) {

            if ((state & MUTEX_LOCK) == 0) {
                state = @cmpxchgWeak(usize, &self.state, state, state | MUTEX_LOCK, .Acquire, .Monotonic) orelse return;
                continue;
            }

            if ((state & QUEUE_MASK) == 0 and spin < 5) {
                if (spin < 4) {
                    SpinLock.yield(30);
                } else {
                    std.os.sched_yield() catch std.time.sleep(0);
                }
                state = @atomicLoad(usize, &self.state, .Monotonic);
                continue;
            }

            var node = QueueNode{
                .next = @intToPtr(?*QueueNode, state & QUEUE_MASK),
                .event = Event.init(),
            };
            defer node.event.deinit();
            const new_state = @ptrToInt(&node) | (state & ~QUEUE_MASK);
            state = @cmpxchgWeak(usize, &self.state, state, new_state, .Release, .Monotonic) orelse {
                node.event.wait();
                spin = 0;
                state = @atomicLoad(usize, &self.state, .Monotonic);
                continue;
            };
        }
    }

    fn releaseSlow(self: *Mutex, current_state: usize) void {
        var state = current_state;
        while (true) {
            if ((state & QUEUE_LOCK) != 0 or (state & QUEUE_MASK) == 0)
                return;
            state = @cmpxchgWeak(usize, &self.state, state, state | QUEUE_LOCK, .Acquire, .Monotonic) orelse break;
        }

        while (true) {
            if ((state & MUTEX_LOCK) != 0) {
                state = @cmpxchgWeak(usize, &self.state, state, state & ~QUEUE_LOCK, .Release, .Monotonic) orelse return;
                @fence(.Acquire);
                continue;
            }

            const node = @intToPtr(*QueueNode, state & QUEUE_MASK);
            const new_state = @ptrToInt(node.next) | (state & MUTEX_LOCK);
            state = @cmpxchgWeak(usize, &self.state, state, new_state, .Release, .Monotonic) orelse {
                node.event.set();
                return;
            };
            @fence(.Acquire);
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

    // MODIFIED
    const thread_count = 10;
    var threads: [thread_count]*std.Thread = undefined;
    for (threads) |*t| {
        t.* = try std.Thread.spawn(&context, worker);
    }
    for (threads) |t|
        t.wait();

    testing.expect(context.data == thread_count * TestContext.incr_count);
}

fn worker(ctx: *TestContext) void {
    var i: usize = 0;
    while (i != TestContext.incr_count) : (i += 1) {
        const held = ctx.mutex.acquire();
        defer held.release();

        ctx.data += 1;
    }
}
