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

            inner: pthread_t,

            pub fn init(self: *Mutex) void {
                _ = pthread_mutex_init(&self.inner, 0);
            }

            pub fn deinit(self: *Mutex) void {
                _ = pthread_mutex_destroy(&self.inner);
            }

            pub fn acquire(self: *Mutex) void {
                _ = pthread_mutex_lock(&self.inner);
            }

            pub fn release(self: *Mutex) void {
                _ = pthread_mutex_unlock(&self.inner);
            }

            const pthread_t = extern struct {
                _opaque: [64]u8 align(16),
            };

            extern "c" fn pthread_mutex_init(p: *pthread_t, a: usize) callconv(.C) c_int;
            extern "c" fn pthread_mutex_destroy(p: *pthread_t) callconv(.C) c_int;
            extern "c" fn pthread_mutex_lock(p: *pthread_t) callconv(.C) c_int;
            extern "c" fn pthread_mutex_unlock(p: *pthread_t) callconv(.C) c_int;
        }
    else if (std.builtin.os.tag == .linux)
        struct {
            pub const NAME = "go_futex";

            const State = enum(i32) {
                unlocked = 0,
                locked = 1,
                sleeping = 2,
            };

            state: State,

            pub fn init(self: *Mutex) void {
                self.state = .unlocked;
            }

            pub fn deinit(self: *Mutex) void {
                self.* = undefined;
            }

            pub fn acquire(self: *Mutex) void {
                const state = @atomicRmw(State, &self.state, .Xchg, .locked, .Acquire);
                if (state != .unlocked)
                    self.acquireSlow(state);
            }

            fn acquireSlow(self: *Mutex, current_state: State) void {
                @setCold(true);

                var spin: u3 = 0;
                var wait = current_state;
                var state = @atomicLoad(State, &self.state, .Monotonic);

                while (true) {
                    if (state == .unlocked) {
                        _ = @cmpxchgWeak(
                            State,
                            &self.state,
                            .unlocked,
                            wait,
                            .Acquire,
                            .Monotonic,
                        ) orelse return;
                    }

                    if (spin < 5) {
                        if (spin < 4) {
                            std.SpinLock.loopHint(@as(usize, 3) << spin);
                        } else {
                            std.os.sched_yield() catch unreachable;
                        }
                        spin += 1;
                        state = @atomicLoad(State, &self.state, .Monotonic);

                    } else {
                        state = @atomicRmw(State, &self.state, .Xchg, .sleeping, .Acquire);
                        if (state == .unlocked)
                            return;

                        wait = .sleeping;
                        while (state == .sleeping) {
                            _ = std.os.linux.futex_wait(
                                @ptrCast(*const i32, &self.state),
                                std.os.linux.FUTEX_PRIVATE_FLAG | std.os.linux.FUTEX_WAIT,
                                @enumToInt(State.sleeping),
                                null,
                            );
                            state = @atomicLoad(State, &self.state, .Monotonic);
                        }
                    }                    
                }
            }

            pub fn release(self: *Mutex) void {
                const state = @atomicRmw(State, &self.state, .Xchg, .unlocked, .Release);
                if (state == .sleeping)
                    self.releaseSlow();
            }

            fn releaseSlow(self: *Mutex) void {
                @setCold(true);
                _ = std.os.linux.futex_wake(
                    @ptrCast(*const i32, &self.state),
                    std.os.linux.FUTEX_PRIVATE_FLAG | std.os.linux.FUTEX_WAKE,
                    @as(i32, 1),
                );
            }
        }
    else 
        @compileError("No OS Mutex detected")
;