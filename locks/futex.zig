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
const sync = @import("../sync/sync.zig");

pub const Lock = struct {
    pub const name = "futex";

    const State = enum(i32) {
        unlocked,
        locked,
        waiting,
    };

    state: State,
    futex: Futex,

    pub fn init(self: *Lock) void {
        self.state = .unlocked;
        self.futex.init();
    }

    pub fn deinit(self: *Lock) void {
        self.futex.deinit();
    }

    pub fn withLock(self: *Lock, context: anytype) void {
        self.acquire();
        context.run();
        self.release();
    }

    fn acquire(self: *Lock) void {
        const state = @atomicRmw(State, &self.state, .Xchg, .locked, .Acquire);
        if (state != .unlocked)
            self.acquireSlow(state);
    }

    fn acquireSlow(self: *Lock, current_state: State) void {
        @setCold(true);

        var wait = current_state;
        var spin: std.math.Log2Int(usize) = 0;
        var state = @atomicLoad(State, &self.state, .Monotonic);

        while (true) {
            while (true) {
                if (state == .unlocked) {
                    _ = @cmpxchgWeak(
                        State,
                        &self.state,
                        state,
                        wait,
                        .Acquire,
                        .Monotonic,
                    ) orelse return;
                }
                if (!Futex.yield(spin))
                    break;
                spin += 1;
                state = @atomicLoad(State, &self.state, .Monotonic);
            }

            state = @atomicRmw(State, &self.state, .Xchg, .waiting, .Acquire);
            if (state == .unlocked)
                return;

            wait = .waiting;
            self.futex.wait(@ptrCast(*const i32, &self.state), @enumToInt(State.waiting));            
            state = @atomicLoad(State, &self.state, .Monotonic);
        }
    }

    fn release(self: *Lock) void {
        const state = @atomicRmw(State, &self.state, .Xchg, .unlocked, .Release);
        if (state == .waiting)
            self.releaseSlow();
    }

    fn releaseSlow(self: *Lock) void {
        @setCold(true);
        self.futex.wake(@ptrCast(*const i32, &self.state));
    }
};

pub const Futex = switch (std.builtin.os.tag) {
    .windows => Windows,
    .linux => Linux,
    else => Posix,
};

const Windows = extern struct {
    const windows = std.os.windows;

    pub fn init(self: *Futex) void {}
    pub fn deinit(self: *Futex) void {}

    pub fn yield(i: std.math.Log2Int(usize)) bool {
        if (i <= 5) {
            sync.spinLoopHint(@as(usize, 1) << i);
        } else {
            return false;
        }
        return true;
    }

    pub fn wait(self: *Futex, state: *const i32, cmp: i32) void {
        var wait_fn = @atomicLoad(usize, &_WAIT, .Monotonic);
        if (wait_fn == 0) {
            load();
            wait_fn = @atomicLoad(usize, &_WAIT, .Monotonic);
            if (wait_fn == 0) {
                while (@atomicLoad(i32, state, .Acquire) == cmp)
                    sync.spinLoopHint(1);
                return;
            }
        }

        const _wait_fn = @intToPtr(fn (
            Address: windows.PVOID,
            CompareAddress: windows.PVOID,
            AddressSize: windows.SIZE_T,
            Timeout: windows.DWORD,
        ) callconv(.Stdcall) windows.BOOL, wait_fn);

        _ = (_wait_fn)(
            @intToPtr(windows.PVOID, @ptrToInt(state)),
            @intToPtr(windows.PVOID, @ptrToInt(&cmp)),
            @sizeOf(i32),
            windows.INFINITE,
        );
    }

    pub fn wake(self: *Futex, state: *const i32) void {
        var wake_fn = @atomicLoad(usize, &_WAKE, .Monotonic);
        if (wake_fn == 0) {
            load();
            wake_fn = @atomicLoad(usize, &_WAKE, .Monotonic);
            if (wake_fn == 0)
                return;
        }

        const _wake_fn = @intToPtr(fn (
            Address: windows.PVOID,
        ) callconv(.Stdcall) void, wake_fn);

        return (_wake_fn)(
            @intToPtr(windows.PVOID, @ptrToInt(state))
        );
    }

    var _WAIT: usize = 0;
    var _WAKE: usize = 0;

    fn load() void {
        @setCold(true);

        const _dll = windows.kernel32.GetModuleHandleA(
            "api-ms-win-core-synch-l1-2-0.dl\x00",
        ) orelse return;

        const _wait = windows.kernel32.GetProcAddress(
            _dll,
            "WaitOnAddress\x00",
        ) orelse return;

        const _wake = windows.kernel32.GetProcAddress(
            _dll,
            "WakeByAddressSingle\x00",
        ) orelse return;

        @atomicStore(usize, &_WAIT, @ptrToInt(_wait), .Monotonic);
        @atomicStore(usize, &_WAKE, @ptrToInt(_wake), .Monotonic);
    }
};

const Linux = struct {
    const linux = std.os.linux;

    pub fn init(self: *Futex) void {}
    pub fn deinit(self: *Futex) void {}

    pub fn yield(i: std.math.Log2Int(usize)) bool {
        if (i < 5) {
            sync.spinLoopHint(@as(usize, 1) << i);
        } else if (i < 6) {
            std.os.sched_yield() catch unreachable;
        } else {
            return false;
        }
        return true;
    }

    pub fn wait(self: *Futex, state: *const i32, cmp: i32) void {
        _ = linux.futex_wait(
            state,
            linux.FUTEX_PRIVATE_FLAG | linux.FUTEX_WAIT,
            cmp,
            null,
        );
    }

    pub fn wake(self: *Futex, state: *const i32) void {
        _ = linux.futex_wake(
            state,
            linux.FUTEX_PRIVATE_FLAG | linux.FUTEX_WAKE,
            1,
        );
    }
};