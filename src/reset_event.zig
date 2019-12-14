const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const assert = std.debug.assert;
const SpinLock = std.SpinLock;
const c = std.c;
const os = std.os;
const linux = os.linux;
const windows = os.windows;

pub const ResetEvent = switch (builtin.os) {
    .windows => AtomicEvent,
    else => if (builtin.link_libc) PosixEvent else AtomicEvent,
};

const PosixEvent = struct {
    is_set: bool,
    cond: c.pthread_cond_t,
    mutex: c.pthread_mutex_t,

    pub fn init() ResetEvent {
        return ResetEvent{
            .is_set = false,
            .cond = c.PTHREAD_COND_INITIALIZER,
            .mutex = c.PTHREAD_MUTEX_INITIALIZER,
        };
    }

    pub fn deinit(self: *ResetEvent) void {
        const valid_error = if (builtin.os == .dragonfly) os.EINVAL else 0;

        const retm = c.pthread_mutex_destroy(&self.mutex);
        assert(retm == 0 or retm == valid_error);
        const retc = c.pthread_cond_destroy(&self.cond);
        assert(retc == 0 or retc == valid_error);
    }

    pub fn isSet(self: *ResetEvent) bool {
        assert(c.pthread_mutex_lock(&self.mutex) == 0);
        defer assert(c.pthread_mutex_unlock(&self.mutex) == 0);

        return self.is_set;
    }

    pub fn reset(self: *ResetEvent) void {
        assert(c.pthread_mutex_lock(&self.mutex) == 0);
        defer assert(c.pthread_mutex_unlock(&self.mutex) == 0);

        self.is_set = false;
    }

    pub fn set(self: *ResetEvent) void {
        assert(c.pthread_mutex_lock(&self.mutex) == 0);
        defer assert(c.pthread_mutex_unlock(&self.mutex) == 0);

        if (!self.is_set) {
            self.is_set = true;
            assert(c.pthread_cond_signal(&self.cond) == 0);
        }
    }

    pub fn wait(self: *ResetEvent) void {
        assert(c.pthread_mutex_lock(&self.mutex) == 0);
        defer assert(c.pthread_mutex_unlock(&self.mutex) == 0);

        while (!self.is_set) {
            assert(c.pthread_cond_wait(&self.cond, &self.mutex) == 0);
        }
    }
};

const AtomicEvent = struct {
    state: State,

    const State = enum(i32) {
        Empty,
        Waiting,
        Signaled,
    };

    pub fn init() AtomicEvent{
        return AtomicEvent{ .state = .Empty };
    }

    pub fn deinit(self: *AtomicEvent) void {
        self.* = undefined;
    }

    pub fn isSet(self: *const AtomicEvent) bool {
        return @atomicLoad(State, &self.state, .Acquire) == .Signaled;
    }

    pub fn reset(self: *AtomicEvent) void {
        @atomicStore(State, &self.state, .Empty, .Monotonic);
    }

    pub fn set(self: *AtomicEvent) void {
        if (@atomicRmw(State, &self.state, .Xchg, .Signaled, .Release) == .Waiting)
            Futex.wake(@ptrCast(*const i32, &self.state));
    }

    pub fn wait(self: *AtomicEvent) void {
        var state = @atomicLoad(State, &self.state, .Acquire);
        while (state == .Empty) {
            state = @cmpxchgWeak(State, &self.state, .Empty, .Waiting, .Acquire, .Acquire) orelse {
                return Futex.wait(@ptrCast(*const i32, &self.state), @as(i32, @enumToInt(State.Waiting)));
            };
        }
    }

    const Futex = switch (builtin.os) {
        .windows => WindowsFutex,
        .linux => LinuxFutex,
        else => SpinFutex,
    };

    const SpinFutex = struct {
        fn wake(ptr: *const i32) void {}

        fn wait(ptr: *const i32, expected: i32) void {
            while (@atomicLoad(i32, ptr, .Acquire) == expected) {
                os.sched_yield() catch SpinLock.yield(1);
            }
        }
    };

    const LinuxFutex = struct {
        fn wake(ptr: *const i32) void {
            const rc = linux.futex_wake(ptr, linux.FUTEX_WAKE | linux.FUTEX_PRIVATE_FLAG, 1);
            assert(os.errno(rc) == 0);
        }

        fn wait(ptr: *const i32, expected: i32) void {
            while (@atomicLoad(i32, ptr, .Acquire) == expected) {
                const rc = linux.futex_wait(ptr, linux.FUTEX_WAIT | linux.FUTEX_PRIVATE_FLAG, expected, null);
                switch (os.errno(rc)) {
                    0 => return,
                    os.EAGAIN => return,
                    os.EINTR => continue,
                    else => unreachable,
                }
            }
        }
    };

    const WindowsFutex = struct {
        fn wake(ptr: *const i32) void {
            const handle = getEventHandle() orelse return SpinFutex.wake(ptr);
            const key = @ptrCast(*const c_void, ptr);
            const rc = windows.ntdll.NtReleaseKeyedEvent(handle, key, windows.FALSE, null);
            assert(rc == 0);
        }

        fn wait(ptr: *const i32, expected: i32) void {
            const handle = getEventHandle() orelse return SpinFutex.wait(ptr, expected);
            const key = @ptrCast(*const c_void, ptr);
            const rc = windows.ntdll.NtWaitForKeyedEvent(handle, key, windows.FALSE, null);
            assert(rc == 0);
        }

        var event_state: State = .Empty;
        var event_handle: ?windows.HANDLE = null;

        fn getEventHandle() ?windows.HANDLE {
            var state = @atomicLoad(State, &event_state, .Monotonic);
            while (true) {
                switch (state) {
                    .Empty => state = @cmpxchgWeak(State, &event_state, .Empty, .Waiting, .Acquire, .Monotonic) orelse {
                        const handle_ptr = @ptrCast(*windows.HANDLE, &event_handle);
                        const access_mask = windows.GENERIC_READ | windows.GENERIC_WRITE;
                        if (windows.ntdll.NtCreateKeyedEvent(handle_ptr, access_mask, null, 0) != 0)
                            event_handle = null;
                        @atomicStore(State, &event_state, .Signaled, .Release);
                        return event_handle;
                    },
                    .Waiting => {
                        std.SpinLock.yield(100);
                        state = @atomicLoad(State, &event_state, .Acquire);
                    },
                    .Signaled => {
                        return event_handle;
                    },
                }
            }
        }
    };
};

test "std.ResetEvent" {
    var event = ResetEvent.init();
    defer event.deinit();

    // test event setting
    testing.expect(event.isSet() == false);
    event.set();
    testing.expect(event.isSet() == true);

    // test event resetting
    event.reset();
    testing.expect(event.isSet() == false);

    // test cross-thread signaling
    if (builtin.single_threaded)
        return;

    const Context = struct {
        const Self = @This();

        value: u128,
        in: ResetEvent,
        out: ResetEvent,

        fn init() Self {
            return Self{
                .value = 0,
                .in = ResetEvent.init(),
                .out = ResetEvent.init(),
            };
        }

        fn deinit(self: *Self) void {
            self.in.deinit();
            self.out.deinit();
            self.* = undefined;
        }

        fn sender(self: *Self) void {
            // update value and signal input
            testing.expect(self.value == 0);
            self.value = 1;
            self.in.set();

            // wait for receiver to update value and signal output
            self.out.wait();
            testing.expect(self.value == 2);
            
            // update value and signal final input
            self.value = 3;
            self.in.set();
        }

        fn receiver(self: *Self) void {
            // wait for sender to update value and signal input
            self.in.wait();
            assert(self.value == 1);
            
            // update value and signal output
            self.in.reset();
            self.value = 2;
            self.out.set();
            
            // wait for sender to update value and signal final input
            self.in.wait();
            assert(self.value == 3);
        }
    };

    var context = Context.init();
    defer context.deinit();
    const receiver = try std.Thread.spawn(&context, Context.receiver);
    defer receiver.wait();
    context.sender();
}