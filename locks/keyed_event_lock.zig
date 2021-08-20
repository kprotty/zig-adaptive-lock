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
const Atomic = std.atomic.Atomic;
const utils = @import("../utils.zig");

pub const Lock = extern struct {
    pub const name = "NtKeyedEvent";

    state: Atomic(u32) = Atomic(u32).init(UNLOCKED),

    const UNLOCKED = 0;
    const LOCKED = 1 << 0;
    const WAKING = 1 << 1;
    const WAITING = 1 << 2;

    pub fn init(self: *Lock) void {
        self.* = Lock{};
    }

    pub fn deinit(self: *Lock) void {
        self.* = undefined;
    }

    pub fn acquire(self: *Lock) void {
        if (!self.acquireFast()) {
            self.acquireSlow();
        }
    }

    inline fn acquireFast(self: *Lock) bool {
        return self.state.bitSet(
            @ctz(u32, LOCKED),
            .Acquire,
        ) == UNLOCKED;
    }

    fn acquireSlow(self: *Lock) void {
        @setCold(true);
        
        var spin: usize = 100;
        var state = self.state.load(.Monotonic);
        while (true) {
            if (state & LOCKED == 0) {
                state = self.state.tryCompareAndSwap(
                    state,
                    state | LOCKED,
                    .Acquire,
                    .Monotonic,
                ) orelse return;
                continue;
            }

            if (state < WAITING and spin > 0) {
                spin -= 1;
                std.atomic.spinLoopHint();
                state = self.state.load(.Monotonic);
                continue;
            }

            state = self.state.compareAndSwap(
                state,
                state + WAITING,
                .Monotonic,
                .Monotonic,
            ) orelse blk: {
                self.callKeyedEvent("NtWaitForKeyedEvent");
                state = self.state.fetchSub(WAKING, .Monotonic);
                break :blk state - WAKING;
            };
        }
    }

    pub fn release(self: *Lock) void {
        const state = self.state.fetchSub(LOCKED, .Release);
        if ((state >= WAITING) and (state & WAKING == 0)) {
            self.releaseSlow();
        }
    }

    fn releaseSlow(self: *Lock) void {
        @setCold(true);

        var state = self.state.load(.Monotonic);
        while ((state >= WAITING) and (state & (LOCKED | WAKING) == 0)) {
            state = self.state.tryCompareAndSwap(
                state,
                (state - WAITING) + WAKING,
                .Monotonic,
                .Monotonic,
            ) orelse {
                self.callKeyedEvent("NtReleaseKeyedEvent");
                return;
            };
        }
    }

    var event_handle = Atomic(usize).init(std.math.maxInt(usize));

    fn callKeyedEvent(self: *Lock, comptime event_fn: []const u8) void {
        @setCold(true);

        var handle = event_handle.load(.Monotonic);
        if (handle == std.math.maxInt(usize)) {
            const handle_ptr = @ptrCast(*std.os.windows.HANDLE, &handle);
            const access_mask = std.os.windows.GENERIC_READ | std.os.windows.GENERIC_WRITE;
            const status = std.os.windows.ntdll.NtCreateKeyedEvent(handle_ptr, access_mask, null, 0);

            if (status != .SUCCESS) handle = 0;
            if (event_handle.compareAndSwap(
                std.math.maxInt(usize),
                handle,
                .Monotonic,
                .Monotonic,
            )) |current_handle| {
                if (status == .SUCCESS) std.os.windows.CloseHandle(handle_ptr.*);
                handle = current_handle;
            }
        }

        switch (@field(std.os.windows.ntdll, event_fn)(
            @intToPtr(?std.os.windows.HANDLE, handle),
            @ptrCast(*const c_void, &self.state),
            std.os.windows.FALSE, // alertable
            null, // timeout
        )) {
            .SUCCESS => {},
            else => unreachable,
        }
    }
};