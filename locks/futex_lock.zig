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

pub const Lock = extern struct {
    pub const name = "futex_lock";

    state: Atomic(u32) = Atomic(u32).init(UNLOCKED),

    const UNLOCKED = 0;
    const LOCKED = 0b01;
    const CONTENDED = 0b11;

    pub fn init(self: *Lock) void {
        self.* = Lock{};
    }

    pub fn deinit(self: *Lock) void {
        self.* = undefined;
    }

    pub fn acquire(self: *Lock) void {
        if (self.acquireFast()) return;
        return self.acquireSlow();
    }

    inline fn acquireFast(self: *Lock) bool {
        if (utils.is_x86) {
            return self.state.fetchOr(LOCKED, .acquire) & LOCKED == UNLOCKED;
        }

        return self.state.cmpxchgWeak(UNLOCKED, LOCKED, .acquire, .monotonic) == null;
    }

    noinline fn acquireSlow(self: *Lock) void {
        @branchHint(.unlikely);
        
        var state = for (0..if (utils.is_arm) 10 else 7) |i| {
            if (utils.is_arm) {
                asm volatile("wfe" ::: "memory");
            } else {
                for (0..@as(u32, 1) << @intCast(i)) |_| std.atomic.spinLoopHint();
            }
            switch (self.state.load(.monotonic)) {
                UNLOCKED => _ = self.state.cmpxchgStrong(UNLOCKED, LOCKED, .acquire, .monotonic) orelse return,
                LOCKED => continue,
                else => |state| break state,
            }
        } else LOCKED;

        while (true) {
            if (state != CONTENDED) {
                if (self.state.swap(CONTENDED, .acquire) == UNLOCKED) return;
            }
            Futex.wait(&self.state, CONTENDED);
            state = UNLOCKED;
        }
    }

    pub fn release(self: *Lock) void {
        if (self.state.swap(UNLOCKED, .release) == CONTENDED) {
            self.releaseSlow();
        }
    }

    noinline fn releaseSlow(self: *Lock) void {
        @branchHint(.unlikely);

        Futex.wake(&self.state, 1);
    }
};
