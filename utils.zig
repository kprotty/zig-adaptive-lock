// Copyright (c) 2020 kprotty
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// 	http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

const std = @import("std");

pub const is_linux = std.builtin.os.tag == .linux;
pub const is_windows = std.builtin.os.tag == .windows;
pub const is_darwin = switch (std.builtin.os.tag) {
    .macosx, .watchos, .tvos, .ios => true,
    else => false,
};

pub const is_posix = std.builtin.link_libc and (switch (std.builtin.os.tag) {
    .linux,
    .minix,
    .macosx,
    .watchos,
    .tvos,
    .ios,
    .solaris,
    .aix,
    .openbsd,
    .kfreebsd,
    .freebsd,
    .netbsd,
    .dragonfly,
    .hermit,
    .haiku,
    .cloudabi,
    .fuchsia => true,
    else => false,
});

pub fn yieldCpu(iterations: usize) void {
    var i = iterations;
    while (i != 0) : (i -= 1) {
        switch (std.builtin.arch) {
            .i386, .x86_64 => asm volatile("pause" ::: "memory"),
            .arm, .aarch64 => asm volatile("yield" ::: "memory"),
            else => {},
        }
    }
}

pub fn yieldThread(iterations: usize) void {
    var i = iterations;
    while (i != 0) : (i -= 1) {
        switch (std.builtin.os.tag) {
            .windows => _ = std.os.windows.kernel32.SwitchToThread(),
            else => _ = std.os.system.sched_yield(),
        }
    }
}

pub const SpinWait = struct {
    counter: std.math.Log2Int(usize) = 0,

    pub fn reset(self: *SpinWait) void {
        self.counter = 0;
    }

    pub fn yield(self: *SpinWait) bool {
        if (self.counter > 10)
            return false;

        self.counter += 1;
        if (self.counter <= 3) {
            yieldCpu(@as(usize, 1) << self.counter);
        } else {
            yieldThread(1);
        }

        return true;
    }
};

pub const Event = 
    if (is_windows)
        extern struct {
            const windows = std.os.windows;

            updated: bool align(@alignOf(usize)) = false,

            pub fn reset(self: *Event) void {
                self.updated = false;
            }

            pub fn wait(self: *Event) void {
                if (!@atomicRmw(bool, &self.updated, .Xchg, true, .Acquire)) {
                    const key = @ptrCast(*align(@alignOf(usize)) const c_void, &self.updated);
                    const status = NtWaitForKeyedEvent(null, key, windows.FALSE, null);
                    std.debug.assert(status == .SUCCESS);
                }
            }

            pub fn notify(self: *Event) void {
                if (@atomicRmw(bool, &self.updated, .Xchg, true, .Acquire)) {
                    const key = @ptrCast(*align(@alignOf(usize)) const c_void, &self.updated);
                    const status = NtReleaseKeyedEvent(null, key, windows.FALSE, null);
                    std.debug.assert(status == .SUCCESS);
                }
            }

            extern "NtDll" fn NtWaitForKeyedEvent(
                EventHandle: ?windows.HANDLE,
                Key: *align(@alignOf(usize)) const c_void,
                Alertable: windows.BOOLEAN,
                Timeout: ?*windows.LARGE_INTEGER,
            ) callconv(.Stdcall) windows.NTSTATUS;

            extern "NtDll" fn NtReleaseKeyedEvent(
                EventHandle: ?windows.HANDLE,
                Key: *align(@alignOf(usize)) const c_void,
                Alertable: windows.BOOLEAN,
                Timeout: ?*windows.LARGE_INTEGER,
            ) callconv(.Stdcall) windows.NTSTATUS;
        }
    else if (is_posix)
        extern struct {
            state: usize = 0,

            pub fn reset(self: *Event) void {
                self.state = 0;
            }

            pub fn wait(self: *Event) void {
                const inner = Inner.get();
                if (@atomicLoad(usize, &self.state, .Acquire) == 0) {
                    if (@atomicRmw(usize, &self.state, .Xchg, @ptrToInt(inner), .Acquire) == 0) {
                        inner.wait();
                    }
                }
            }

            pub fn notify(self: *Event) void {
                const state = @atomicRmw(usize, &self.state, .Xchg, 1, .Release);
                if (state != 0) {
                    @intToPtr(*Inner, state).notify();
                }
            }

            const Inner = struct {
                updated: bool,
                cond: pthread_cond_t,
                mutex: pthread_mutex_t,

                var key_state = KeyState.uninit;
                var key: pthread_key_t = undefined;

                const KeyState = extern enum(usize) {
                    uninit,
                    pending,
                    init,
                };

                fn init(self: *Inner) void {
                    self.updated = false;
                    std.debug.assert(pthread_cond_init(&self.cond, null) == 0);
                    std.debug.assert(pthread_mutex_init(&self.mutex, null) == 0);
                }

                fn deinit(self: *Inner) void {
                    std.debug.assert(pthread_cond_destroy(&self.cond) == 0);
                    std.debug.assert(pthread_mutex_destroy(&self.mutex) == 0);
                }

                fn get() *Inner {
                    const tls_key = blk: {
                        if (@atomicLoad(KeyState, &key_state, .Acquire) == .init)
                            break :blk key;
                        break :blk getKeySlow();
                    };

                    const tls_val = pthread_getspecific(tls_key);
                    const tls_inner = @ptrCast(?*Inner, @alignCast(@alignOf(Inner), tls_val)) orelse blk: {
                        const inner = std.heap.c_allocator.create(Inner) catch unreachable;
                        inner.init();
                        std.debug.assert(pthread_setspecific(tls_key, @ptrCast(*c_void, inner)) == 0);
                        break :blk inner;
                    };

                    tls_inner.updated = false;
                    return tls_inner;
                }

                fn getKeySlow() pthread_key_t {
                    @setCold(true);
                    var state = KeyState.uninit;
                    while (true) {
                        switch (state) {
                            .uninit => state = @cmpxchgWeak(
                                KeyState,
                                &key_state,
                                state,
                                KeyState.pending,
                                .Acquire,
                                .Acquire,
                            ) orelse blk: {
                                if (pthread_key_create(&key, Inner.deinit) != 0)
                                    unreachable;
                                @atomicStore(KeyState, &self.state, .init, .Release);
                                break :blk .init;
                            },
                            .pending => {
                                yieldThread(1);
                                state = @atomicLoad(KeyState, &self.state, .Acquire);
                            },
                            .init => {
                                return key;
                            },
                        }
                    }
                }

                fn wait(self: *Inner) void {
                    std.debug.assert(pthread_mutex_lock(&self.mutex) == 0);
                    defer std.debug.assert(pthread_mutex_unlock(&self.mutex) == 0);

                    if (self.updated) {
                        self.updated = false;
                        return;
                    }

                    self.updated = true;
                    while (self.updated) {
                        std.debug.assert(pthread_cond_wait(&self.cond, &self.mutex));
                    }
                }

                fn notify(self: *Inner) void {
                    const should_notify = blk: {
                        std.debug.assert(pthread_mutex_lock(&self.mutex) == 0);
                        defer std.debug.assert(pthread_mutex_unlock(&self.mutex) == 0);

                        if (self.updated) {
                            self.updated = false;
                        } else {
                            self.updated = true;
                        }

                        break :blk !self.updated;
                    };

                    if (should_notify) {
                        std.debug.assert(pthread_cond_signal(&self.cond) == 0);
                    }
                }
            };

            const pthread_t = extern struct {
                _opaque: [64]u8 align(16),
            };

            const pthread_key_t = usize;
            extern "c" fn pthread_key_create(p: *pthread_key_t, destructor: fn(*c_void) callconv(.C) void) callconv(.C) c_int;
            extern "c" fn pthread_getspecific(p: *pthread_key_t) callconv(.C) ?*c_void;
            extern "c" fn pthread_setspecific(p: *pthread_key_t, value: ?*const c_void) callconv(.C) c_int;

            const pthread_cond_t = pthread_t;
            const pthread_condattr_t = pthread_t;
            extern "c" fn pthread_cond_init(p: *pthread_cond_t, attr: ?*const pthread_condattr_t) callconv(.C) c_int;
            extern "c" fn pthread_cond_destroy(p: *pthread_cond_t) callconv(.C) c_int;
            extern "c" fn pthread_cond_signal(p: *pthread_cond_t) callconv(.C) c_int;
            extern "c" fn pthread_cond_wait(noalias p: *pthread_cond_t, noalias m: *pthread_mutex_t) callconv(.C) c_int;

            const pthread_mutex_t = pthread_t;
            const pthread_mutexattr_t = pthread_t;
            extern "c" fn pthread_mutex_init(p: *pthread_mutex_t, attr: ?*const pthread_mutexattr_t) callconv(.C) c_int;
            extern "c" fn pthread_mutex_destroy(p: *pthread_mutex_t) callconv(.C) c_int;
            extern "c" fn pthread_mutex_lock(p: *pthread_mutex_t) callconv(.C) c_int;
            extern "c" fn pthread_mutex_unlock(p: *pthread_mutex_t) callconv(.C) c_int;
        }
    else if (is_linux)
        extern struct {
            const linux = std.os.linux;

            state: State = State.empty,

            const State = extern enum(i32) {
                empty,
                waiting,
                notified,
            };

            pub fn reset(self: *Event) void {
                self.state = .empty;
            }

            pub fn wait(self: *Event) void {
                switch (@atomicRmw(State, &self.state, .Xchg, .waiting, .Acquire)) {
                    .empty => {
                        while (true) {
                            const rc = linux.futex_wait(
                                @ptrCast(*const i32, &self.state),
                                linux.FUTEX_PRIVATE_FLAG | linux.FUTEX_WAIT,
                                @as(i32, @enumToInt(State.waiting)),
                                null,
                            );
                            switch (linux.getErrno(rc)) {
                                0, linux.EINTR => {
                                    if (@atomicLoad(State, &self.state, .Acquire) != .waiting)
                                        break;
                                },
                                linux.EAGAIN => break,
                                else => unreachable,
                            }
                        }
                    },
                    .waiting => unreachable,
                    .notified => {},
                }
            }

            pub fn notify(self: *Event) void {
                switch (@atomicRmw(State, &self.state, .Xchg, .notified, .Release)) {
                    .empty => {},
                    .waiting => {
                        const rc = linux.futex_wake(
                            @ptrCast(*const i32, &self.state),
                            linux.FUTEX_PRIVATE_FLAG | linux.FUTEX_WAKE,
                            @as(i32, 1),
                        );
                        std.debug.assert(linux.getErrno(rc) == 0);
                    },
                    .notified => unreachable,
                }
            }
        }
    else
        @compileError("OS not supported for Event");
