// Copyright (c) 2020 kprotty
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

const std = @import("std");
const utils = @import("../utils.zig");
const Atomic = std.atomic.Value;
const Futex = std.Thread.Futex;
const NtKeyedEvent = @import("keyed_event_lock.zig").NtKeyedEvent;

pub const Lock = struct {
    pub const name = "count_lock";

    state: Atomic(u64) = Atomic(u64).init(0),

    const unlocked = 0;
    const locked = 1 << 0;
    const waking = 1 << 1;
    const waiting = 1 << 2;

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
        return self.state.bitSet(@ctz(locked), .acquire) == 0;
    }

    noinline fn acquireSlow(self: *Lock) void {
        var spin: u8 = 0;
        var state = self.state.load(.monotonic);
        while (true) {
            if (state & locked == 0) {
                if (self.acquireFast()) return;
                std.atomic.spinLoopHint();
                state = self.state.load(.monotonic);
                continue;
            }

            if (@as(u32, @truncate(state)) < waiting and spin < 100) {
                spin += 1;
                std.atomic.spinLoopHint();
                state = self.state.load(.monotonic);
                continue;
            }

            if (self.state.cmpxchgWeak(
                state,
                state + waiting,
                .monotonic,
                .monotonic,
            )) |updated| {
                state = updated;
                continue;
            }

            self.wait();
            spin = 0;
            state = self.state.fetchSub(waking, .monotonic) - waking;
        }
    }

    pub fn release(self: *Lock) void {
        const state = self.state.fetchSub(locked, .release);
        if (@as(u32, @truncate(state)) >= waiting) {
            self.releaseSlow();
        }
    }

    noinline fn releaseSlow(self: *Lock) void {
        var state = self.state.load(.monotonic);
        while (@as(u32, @truncate(state)) >= waiting and state & (locked | waking) == 0) {
            state = self.state.cmpxchgWeak(
                state,
                state - waiting + waking,
                .monotonic,
                .monotonic,
            ) orelse return self.wake();
        }
    }

    noinline fn wait(self: *Lock) void {
        const futex_ptr = &@as(*[2]Atomic(u32), @ptrCast(&self.state))[1];
        while (futex_ptr.swap(0, .acquire) == 0)
            Futex.wait(futex_ptr, 0, null) catch unreachable;
    }

    noinline fn wake(self: *Lock) void {
        const futex_ptr = &@as(*[2]Atomic(u32), @ptrCast(&self.state))[1];
        futex_ptr.store(1, .release);
        return Futex.wake(futex_ptr, 1);
    }
};
