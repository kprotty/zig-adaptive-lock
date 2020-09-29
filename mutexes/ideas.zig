const Idea1 = struct {
    const std = @import("std");

    pub const Mutex = struct {
        pub const NAME = "event_lock";

        const UNLOCKED = 0;
        const LOCKED = 1 << 0;
        const PARKED = 1 << 1;

        state: usize,
        futex: Futex align(128),
        
        pub fn init(self: *Mutex) void {
            self.state = UNLOCKED;
            self.futex.init();
        }

        pub fn deinit(self: *Mutex) void {
            self.futex.deinit();
            self.* = undefined;
        }

        pub fn acquire(self: *Mutex) void {
            const state = @atomicRmw(usize, &self.state, .Xchg, LOCKED, .Acquire);
            if (state != UNLOCKED)
                self.acquireSlow(state);
        }

        fn acquireSlow(self: *Mutex, current_state: usize) void {
            @setCold(true);

            var wait = current_state;
            var state = @atomicLoad(usize, &self.state, .Monotonic);

            while (true) {
                var i: u3 = 0;
                while (i < 5) : (i += 1) {
                    if (state == UNLOCKED) {
                        _ = @cmpxchgWeak(
                            usize,
                            &self.state,
                            state,
                            wait,
                            .Acquire,
                            .Monotonic,
                        ) orelse return;
                    }
                    if (i < 4) {
                        std.SpinLock.loopHint(@as(usize, 2) << i);
                    } else {
                        std.os.sched_yield() catch unreachable;
                    }
                    state = @atomicLoad(usize, &self.state, .Monotonic);
                }

                state = @atomicRmw(usize, &self.state, .Xchg, PARKED, .Acquire);
                if (state == UNLOCKED)
                    return;

                wait = PARKED;
                self.futex.wait(&self.state, wait);            
                state = @atomicLoad(usize, &self.state, .Monotonic);
            }
        }

        pub fn release(self: *Mutex) void {
            const state = @atomicRmw(usize, &self.state, .Xchg, UNLOCKED, .Release);
            if (state == PARKED)
                self.releaseSlow();
        }

        fn releaseSlow(self: *Mutex) void {
            @setCold(true);
            self.futex.wake(&self.state);
        }
    };

    const Futex = 
        if (std.builtin.os.tag == .linux)
            extern struct {
                fn init(self: *@This()) void {
                }

                fn deinit(self: *@This()) void {
                }

                fn wait(self: *@This(), state: *usize, compare: usize) void {
                    while (@atomicLoad(usize, state, .Monotonic) == compare) {
                        _ = std.os.linux.futex_wait(
                            @ptrCast(*const i32, state),
                            std.os.linux.FUTEX_WAIT | std.os.linux.FUTEX_PRIVATE_FLAG,
                            @intCast(i32, compare),
                            null,
                        );
                    }
                }

                fn wake(self: *@This(), state: *usize) void {
                    _ = std.os.linux.futex_wake(
                        @ptrCast(*const i32, state),
                        std.os.linux.FUTEX_WAKE | std.os.linux.FUTEX_PRIVATE_FLAG,
                        1,
                    );
                }
            }
        else
            struct {
                // const nanotime = @import("./nanotime.zig").nanotime;
                const Parker = @import("../v2/parker.zig").OsParker;
                const InnerLock = 
                    if (std.builtin.os.tag == .windows)
                        @import("./test_new_lock.zig").Mutex
                    else if (true)
                        @import("./spin.zig").Mutex
                    else
                        extern struct {
                            locked: bool,

                            fn init(self: *@This()) void {
                                self.locked = false;
                            }

                            fn deinit(self: *@This()) void {
                                self.locked = undefined;
                            }

                            fn acquire(self: *@This()) void {
                                while (@atomicRmw(bool, &self.locked, .Xchg, true, .Acquire))
                                    std.SpinLock.loopHint(1);
                            }

                            fn release(self: *@This()) void {
                                @atomicStore(bool, &self.locked, false, .Release);        
                            }
                        };

                lock: InnerLock align(128),
                queue: ?*Waiter align(128),

                const Waiter = extern struct {
                    next: ?*Waiter,
                    tail: *Waiter,
                    parker: Parker,
                };

                fn init(self: *@This()) void {
                    self.lock.init();
                    self.queue = null;
                }

                fn deinit(self: *@This()) void {
                    self.lock.deinit();
                    self.* = undefined;
                }

                fn wait(self: *@This(), state: *usize, compare: usize) void {
                    var is_waiting: bool = undefined;
                    var waiter: Waiter = undefined;

                    {
                        self.lock.acquire();
                        defer self.lock.release();

                        is_waiting = @atomicLoad(usize, state, .Monotonic) == compare;
                        if (!is_waiting)
                            return;

                        waiter.next = null;
                        waiter.tail = &waiter;
                        if (self.queue) |head| {
                            head.tail.next = &waiter;
                            head.tail = &waiter;
                        } else {
                            self.queue = &waiter;
                        }

                        waiter.parker = Parker.init();
                        waiter.parker.prepare();
                    }

                    if (is_waiting) {
                        waiter.parker.park();
                        waiter.parker.deinit();
                    }
                }

                fn wake(self: *@This(), state: *usize) void {
                    var waiter: ?*Waiter = undefined;
                    {
                        self.lock.acquire();
                        defer self.lock.release();

                        waiter = self.queue;
                        if (waiter) |w| {
                            self.queue = w.next;
                            if (self.queue) |next|
                                next.tail = w.tail;
                        }
                    }

                    if (waiter) |w| {
                        w.parker.unpark();
                    }
                }
            };
};

const Idea2 = struct {
    const std = @import("std");
    const windows = std.os.windows;

    pub const Mutex = struct {
        pub const NAME = "keyed_event_lock";

        const UNLOCKED = 0;
        const LOCKED = 1 << 0;
        const WAKING = 1 << 8;
        const WAITING = 1 << 9;

        state: usize,

        pub extern "NtDll" fn NtWaitForKeyedEvent(
            handle: ?windows.HANDLE,
            key: *const usize,
            alertable: windows.BOOLEAN,
            timeout: ?*const windows.LARGE_INTEGER,
        ) callconv(.Stdcall) windows.NTSTATUS;

        pub extern "NtDll" fn NtReleaseKeyedEvent(
            handle: ?windows.HANDLE,
            key: *const usize,
            alertable: windows.BOOLEAN,
            timeout: ?*const windows.LARGE_INTEGER,
        ) callconv(.Stdcall) windows.NTSTATUS;

        pub fn init(self: *Mutex) void {
            self.state = UNLOCKED;
        }

        pub fn deinit(self: *Mutex) void {
            self.* = undefined;
        }

        inline fn tryAcquire(self: *Mutex) bool {
            return asm volatile(
                "lock btsl $0, %[ptr]"
                : [ret] "={@ccc}" (-> u8),
                : [ptr] "*m" (&self.state)
                : "cc", "memory"
            ) == 0;
        }

        pub fn acquire(self: *Mutex) void {
            if (!self.tryAcquire())
                self.acquireSlow();
        }

        fn acquireSlow(self: *Mutex) void {
            @setCold(true);

            const max_spin = 12;
            var spin: std.math.Log2Int(usize) = 0;

            while (true) {
                const state = @atomicLoad(usize, &self.state, .Monotonic);

                if (state & LOCKED == 0) {
                    if (@atomicRmw(u8, @ptrCast(*u8, &self.state), .Xchg, LOCKED, .Acquire) == UNLOCKED)
                        return;
                } else if (state >= WAITING or spin > max_spin) {
                    _ = @cmpxchgWeak(
                        usize,
                        &self.state,
                        state,
                        state + WAITING,
                        .Monotonic,
                        .Monotonic,
                    ) orelse {
                        _ = NtWaitForKeyedEvent(null, &self.state, windows.FALSE, null);
                        _ = @atomicRmw(usize, &self.state, .And, ~@as(usize, WAKING), .Monotonic);
                        spin = 0;
                        continue;
                    };
                }

                if (spin <= max_spin) {
                    std.SpinLock.loopHint(@as(usize, 1) << spin);
                    spin += 1;
                } else {
                    windows.kernel32.Sleep(0);
                }
            }
        }

        pub fn release(self: *Mutex) void {
            @atomicStore(u8, @ptrCast(*u8, &self.state), UNLOCKED, .Release);

            if (@atomicLoad(usize, &self.state, .Monotonic) >= WAITING)
                self.releaseSlow();
        }

        fn releaseSlow(self: *Mutex) void {
            @setCold(true);

            while (true) {
                const state = @atomicLoad(usize, &self.state, .Monotonic);
                if ((state < WAITING) or (state & (LOCKED | WAKING) != 0))
                    return;

                _ = @cmpxchgWeak(
                    usize,
                    &self.state,
                    state,
                    (state - WAITING) | WAKING,
                    .Monotonic,
                    .Monotonic,
                ) orelse {
                    _ = NtReleaseKeyedEvent(null, &self.state, windows.FALSE, null);
                    return;
                };

                std.SpinLock.loopHint(1);
            }


        }
    };
};