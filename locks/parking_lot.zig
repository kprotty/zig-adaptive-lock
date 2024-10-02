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
const Futex = utils.Futex;

pub const Lock = extern struct {
    pub const name = "parking_lot";

    const UNLOCKED = 0;
    const LOCKED = 1;
    const PARKED = 2;

    state: Atomic(u8) = Atomic(u8).init(UNLOCKED),
    pl_lock: @import("word_lock.zig").Lock = .{},
    pl_queue: ?*Waiter = null,

    const Waiter = struct {
        next: ?*Waiter,
        tail: *Waiter,
        futex: Atomic(u32),
    };

    pub fn init(self: *Lock) void {
        self.* = .{};
    }

    pub fn deinit(self: *Lock) void {
        self.* = undefined;
    }

    pub fn acquire(self: *Lock) void {
        if (self.state.cmpxchgWeak(UNLOCKED, LOCKED, .acquire, .monotonic) == null) return;
        self.acquireSlow();
    }

    fn acquireSlow(self: *Lock) void {
        @branchHint(.unlikely);

        var spin = utils.SpinWait{};
        var state = self.state.load(.monotonic);

        while (true) {
            if (state & LOCKED == 0) {
                state = self.state.cmpxchgWeak(state, state | LOCKED, .acquire, .monotonic) orelse return;
                continue;
            }

            if (state & PARKED == 0) blk: {
                if (spin.yield()) {
                    state = self.state.load(.monotonic);
                    continue;
                }

                state = self.state.cmpxchgWeak(state, state | PARKED, .monotonic, .monotonic) orelse break :blk;
                continue;
            }

            wait: {
                self.pl_lock.acquire();

                state = self.state.load(.monotonic);
                if (state != (LOCKED | PARKED)) {
                    self.pl_lock.release();
                    break :wait;
                }

                var waiter: Waiter = undefined;
                waiter.next = null;
                waiter.tail = &waiter;
                waiter.futex = Atomic(u32).init(0);
                if (self.pl_queue) |head| {
                    head.tail.next = &waiter;
                    head.tail = &waiter;
                } else {
                    self.pl_queue = &waiter;
                }

                self.pl_lock.release();
                while (waiter.futex.load(.acquire) == 0) {
                    Futex.wait(&waiter.futex, 0, null) catch unreachable;
                }
            }

            spin.reset();
            state = self.state.load(.monotonic);
        }
    }

    pub fn release(self: *Lock) void {
        if (self.state.cmpxchgStrong(LOCKED, UNLOCKED, .release, .monotonic) == null) return;
        self.releaseSlow();
    }

    fn releaseSlow(self: *Lock) void {
        @branchHint(.unlikely);

        self.pl_lock.acquire();

        const waiter = self.pl_queue;
        if (waiter) |w| {
            self.pl_queue = w.next;
            if (self.pl_queue) |head| {
                head.tail = w.tail;
            }
        }

        const new_state = if (waiter == null) @as(u8, UNLOCKED) else PARKED;
        self.state.store(new_state, .release);

        self.pl_lock.release();
        if (waiter) |w| {
            w.futex.store(1, .release);
            Futex.wake(&w.futex, 1);
        }
    }
};
