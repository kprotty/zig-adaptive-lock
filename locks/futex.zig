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
const utils = @import("../utils.zig");

pub const Lock = FutexLock(OsFutex);

pub const OsFutex = 
    if (utils.is_windows)
        WindowsFutex
    else if (utils.is_linux)
        LinuxFutex
    else if (utils.is_posix)
        GenericFutex
    else
        @compileError("OS does not expose a futex based api");

pub fn FutexLock(comptime Futex: type) type {
    return extern struct {
        pub const name = "futex_lock";
        const Lock = @This();

        state: State,
        futex: Futex,

        const State = extern enum(i32) {
            unlocked,
            locked,
            parked,
        };

        pub fn init(self: *Lock) void {
            self.state = .unlocked;
            self.futex.init();
        }

        pub fn deinit(self: *Lock) void {
            self.futex.deinit();
        }

        pub fn acquire(self: *Lock) void {
            const state = @atomicRmw(State, &self.state, .Xchg, .locked, .Acquire);
            if (state != .unlocked)
                self.acquireSlow(state);
        }

        fn acquireSlow(self: *Lock, acquire_state: State) void {
            @setCold(true);

            var spin = utils.SpinWait{};
            while (true) {
                const state = @atomicLoad(State, &self.state, .Monotonic);
                if (state == .unlocked) {
                    _ = @cmpxchgWeak(
                        State,
                        &self.state,
                        .unlocked,
                        acquire_state,
                        .Acquire,
                        .Monotonic,
                    ) orelse return;
                } else if (state == .parked) {
                    utils.yieldThread(1);
                    break;
                }
                if (!spin.yield()) {
                    break;
                }
            }

            while (true) {
                const state = @atomicLoad(State, &self.state, .Monotonic);
                if (state != .parked) {
                    if (@atomicRmw(State, &self.state, .Xchg, .parked, .Acquire) == .unlocked) {
                        return;
                    }
                }
                self.futex.wait(
                    @ptrCast(*const i32, &self.state),
                    @enumToInt(State.parked),
                );
            }
        }

        pub fn release(self: *Lock) void {
            if (@atomicRmw(State, &self.state, .Xchg, .unlocked, .Release) == .parked) {
                self.releaseSlow();
            } 
        }

        fn releaseSlow(self: *Lock) void {
            @setCold(true);
            self.futex.wake(
                @ptrCast(*const i32, &self.state),
            );
        }
    };
}

pub const LinuxFutex = extern struct {
    const linux = std.os.linux;
    const Futex = @This();

    pub fn init(self: *Futex) void {}
    pub fn deinit(self: *Futex) void {}

    pub fn wait(self: *Futex, ptr: *const i32, cmp: i32) void {
        _ = linux.futex_wait(
            ptr,
            linux.FUTEX_PRIVATE_FLAG | linux.FUTEX_WAIT,
            cmp,
            null,
        );
    }

    pub fn wake(self: *Futex, ptr: *const i32) void {
        _ = linux.futex_wake(
            ptr,
            linux.FUTEX_PRIVATE_FLAG | linux.FUTEX_WAKE,
            1,
        );
    }
};

pub const WindowsFutex = extern struct {
    const windows = std.os.windows;
    const Futex = @This();

    pub fn init(self: *Futex) void {}
    pub fn deinit(self: *Futex) void {}

    pub fn wait(self: *Futex, ptr: *const i32, cmp: i32) void {
        var wait_fn_ptr = @atomicLoad(usize, &WAIT_FN, .Monotonic);
        if (wait_fn_ptr == 0) {
            loadWaitOnAddress();
            wait_fn_ptr = @atomicLoad(usize, &WAIT_FN, .Monotonic);
        }

        const wait_fn = @intToPtr(
            fn (
                Address: windows.PVOID,
                CompareAddress: windows.PVOID,
                AddressSize: windows.SIZE_T,
                Timeout: windows.DWORD,
            ) callconv(.Stdcall) windows.BOOL,
            wait_fn_ptr,
        );

        _ = (wait_fn)(
            @intToPtr(windows.PVOID, @ptrToInt(ptr)),
            @intToPtr(windows.PVOID, @ptrToInt(&cmp)),
            @sizeOf(i32),
            windows.INFINITE,
        );
    }

    pub fn wake(self: *Futex, ptr: *const i32) void {
        var wake_fn_ptr = @atomicLoad(usize, &WAKE_FN, .Monotonic);
        if (wake_fn_ptr == 0) {
            loadWaitOnAddress();
            wake_fn_ptr = @atomicLoad(usize, &WAKE_FN, .Monotonic);
        }

        const wake_fn = @intToPtr(
            fn (
                Address: windows.PVOID,
            ) callconv(.Stdcall) void,
            wake_fn_ptr,
        );

        _ = (wake_fn)(
            @intToPtr(windows.PVOID, @ptrToInt(ptr)),
        );
    }

    var WAIT_FN: usize = 0;
    var WAKE_FN: usize = 0;

    fn loadWaitOnAddress() void {
        @setCold(true);

        const dll_module = windows.kernel32.GetModuleHandleA(
            "api-ms-win-core-synch-l1-2-0.dl\x00",
        ) orelse std.debug.panic("failed to load dll for WaitOnAddress functions", .{});

        const wait_fn = windows.kernel32.GetProcAddress(
            dll_module,
            "WaitOnAddress\x00",
        ) orelse std.debug.panic("failed to load WaitOnAddress ptr", .{});

        const wake_fn = windows.kernel32.GetProcAddress(
            dll_module,
            "WakeByAddressSingle\x00",
        ) orelse std.debug.panic("failed to load WakeByAddressSingle ptr", .{});

        @atomicStore(usize, &WAIT_FN, @ptrToInt(wait_fn), .Monotonic);
        @atomicStore(usize, &WAKE_FN, @ptrToInt(wake_fn), .Monotonic);
    }
};

pub const GenericFutex = extern struct {
    lock: WordLock,
    head: ?*Waiter,
    
    const Futex = @This();

    const WordLock = @import("./word_lock_waking.zig").Lock;
    
    const Waiter = struct {
        next: ?*Waiter,
        tail: *Waiter,
        event: utils.Event,
    };

    pub fn init(self: *Futex) void {
        self.lock.init();
        self.head = null;
    }

    pub fn deinit(self: *Futex) void {
        self.lock.deinit();
        self.* = undefined;
    }

    pub fn wait(self: *Futex, ptr: *const i32, cmp: i32) void {
        self.lock.acquire();

        if (@atomicLoad(i32, ptr, .Acquire) != cmp) {
            self.lock.release();
            return;
        }

        var waiter: Waiter = undefined;
        waiter = Waiter{
            .next = null,
            .tail = &waiter,
            .event = utils.Event{},
        };
        if (self.head) |head| {
            head.tail.next = &waiter;
            head.tail = &waiter;
        } else {
            self.head = &waiter;
        }

        self.lock.release();
        waiter.event.wait();
    }

    pub fn wake(self: *Futex, ptr: *const i32) void {
        const waiter = blk: {
            self.lock.acquire();
            defer self.lock.release();

            const waiter = self.head orelse break :blk null;
            self.head = waiter.next;
            if (self.head) |head|
                head.tail = waiter.tail;
            break :blk waiter;
        };

        if (waiter) |w| {
            w.event.notify();
        }
    }
};