const std = @import("std");

pub const Mutex = 
    if (std.builtin.os.tag == .windows)
        struct {
            pub const NAME = "SRWLOCK";

            inner: usize,

            extern "kernel32" fn AcquireSRWLockExclusive(ptr: *usize) callconv(.Stdcall) void;
            extern "kernel32" fn ReleaseSRWLockExclusive(ptr: *usize) callconv(.Stdcall) void;

            pub fn init(self: *Mutex) void {
                self.inner = 0;
            }

            pub fn deinit(self: *Mutex) void {
                self.* = undefined;
            }

            pub fn acquire(self: *Mutex) void {
                AcquireSRWLockExclusive(&self.inner);
            }

            pub fn release(self: *Mutex) void {
                ReleaseSRWLockExclusive(&self.inner);
            }
        }
    else if (std.builtin.link_libc)
        struct {
            pub const NAME = "pthread_mutex_t";

            inner: std.c.pthread_mutex_t,

            pub fn init(self: *Mutex) void {
                self.inner = std.c.PTHREAD_MUTEX_INITIALIZER;
            }

            pub fn deinit(self: *Mutex) void {
                _ = std.c.pthread_mutex_destroy(&self.inner);
                self.* = undefined;
            }

            pub fn acquire(self: *Mutex) void {
                _ = std.c.pthread_mutex_lock(&self.inner);
            }

            pub fn release(self: *Mutex) void {
                _ = std.c.pthread_mutex_unlock(&self.inner);
            }
        }
    else if (std.builtin.os.tag == .linux)
        struct {
            pub const NAME = "futex";

            state: usize,

            const UNLOCKED = 0;
            const LOCKED = 1 << 0;
            const WAKING = 1 << 8;
            const WAITING = ~@as(usize, (1 << 9) - 1);

            const linux = std.os.linux;
            const Waiter = extern struct {
                prev: ?*Waiter align(1 << 9),
                next: ?*Waiter,
                tail: ?*Waiter,
                key: i32,
            };

            pub fn init(self: *Mutex) void {
                self.state = UNLOCKED;
            }

            pub fn deinit(self: *Mutex) void {
                self.* = undefined;
            }

            pub fn acquire(self: *Mutex) void {
                if (@cmpxchgWeak(
                    u8,
                    @ptrCast(*u8, &self.state),
                    UNLOCKED,
                    LOCKED,
                    .Acquire,
                    .Monotonic,
                )) |_| {
                    self.acquireSlow();
                }
            }

            fn acquireSlow(self: *Mutex) void {
                @setCold(true);
                
                var spin: u3 = 0;
                var is_waking = false;
                var waiter: Waiter = undefined;
                var state = @atomicLoad(usize, &self.state, .Monotonic);
                
                while (true) {
                    var new_state = state;
                    
                    if (state & LOCKED == 0) {
                        new_state |= LOCKED;

                    } else {
                        const head = @intToPtr(?*Waiter, state & WAITING);

                        if (head == null and spin < 5) {
                            spin += 1;
                            std.SpinLock.loopHint(@as(usize, 1) << spin);
                            state = @atomicLoad(usize, &self.state, .Monotonic);
                            continue;
                        }

                        waiter.key = 0;
                        waiter.next = head;
                        waiter.prev = null;
                        waiter.tail = if (head == null) &waiter else null;
                        new_state = @ptrToInt(&waiter) | (state & ~WAITING);
                    }

                    if (is_waking)
                        new_state &= ~@as(usize, WAKING);

                    if (@cmpxchgWeak(
                        usize,
                        &self.state,
                        state,
                        new_state,
                        .AcqRel,
                        .Monotonic,
                    )) |updated_state| {
                        state = updated_state;
                        continue;
                    }

                    if (state & LOCKED == 0)
                        return;

                    while (@atomicLoad(i32, &waiter.key, .Acquire) == 0) {
                        _ = linux.futex_wait(
                            &waiter.key,
                            linux.FUTEX_WAIT | linux.FUTEX_PRIVATE_FLAG,
                            @as(i32, 0),
                            null,
                        );
                    }

                    spin = 0;
                    is_waking = true;
                    state = @atomicLoad(usize, &self.state, .Monotonic);
                }
            }

            pub fn release(self: *Mutex) void {
                @atomicStore(u8, @ptrCast(*u8, &self.state), UNLOCKED, .Release);

                const state = @atomicLoad(usize, &self.state, .Monotonic);
                if ((state & WAITING != 0) and (state & (WAKING | LOCKED) == 0))
                    self.releaseSlow(state);
            }

            fn releaseSlow(self: *Mutex, current_state: usize) void {
                @setCold(true);

                var state = current_state;
                while (true) {
                    if ((state & WAITING == 0) or (state & (WAKING | LOCKED) != 0))
                        return;
                    state = @cmpxchgWeak(
                        usize,
                        &self.state,
                        state,
                        state | WAKING,
                        .Acquire,
                        .Monotonic,
                    ) orelse break;
                }

                while (true) {
                    const head = @intToPtr(*Waiter, state & WAITING);
                    const tail = head.tail orelse blk: {
                        var current = head;
                        while (true) {
                            const next = current.next.?;
                            next.prev = current;
                            if (next.tail) |tail| {
                                head.tail = tail;
                                break :blk tail;
                            } else {
                                current = next;
                            }
                        }
                    };

                    if (state & LOCKED != 0) {
                        state = @cmpxchgWeak(
                            usize,
                            &self.state,
                            state,
                            state & ~@as(usize, WAKING),
                            .Release,
                            .Acquire,
                        ) orelse break;
                        continue;
                    }

                    if (tail.prev) |new_tail| {
                        head.tail = new_tail;
                        @fence(.Release);
                    } else if (@cmpxchgWeak(
                        usize,
                        &self.state,
                        state,
                        WAKING,
                        .Release,
                        .Acquire,
                    )) |updated_state| {
                        state = updated_state;
                        continue;
                    }

                    @atomicStore(i32, &tail.key, 1, .Release);
                    _ = linux.futex_wake(&tail.key, linux.FUTEX_WAKE | linux.FUTEX_PRIVATE_FLAG, 1);
                    break;
                }
            }
        }
    else 
        @compileError("No OS Mutex detected")
;