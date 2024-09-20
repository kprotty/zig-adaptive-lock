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

pub const Lock = extern struct {
    pub const name = "word_lock";

    state: Atomic(usize) = Atomic(usize).init(UNLOCKED),

    const UNLOCKED = 0;
    const LOCKED = 1;
    const WAKING = 2;
    const WAITING = ~@as(usize, LOCKED | WAKING);

    const Waiter = struct {
        prev: ?*Waiter align(~WAITING + 1),
        next: ?*Waiter,
        tail: ?*Waiter,
        event: utils.Event,
    };

    pub fn init(self: *Lock) void {
        self.* = Lock{};
    }

    pub fn deinit(self: *Lock) void {
        self.* = undefined;
    }

    pub fn acquire(self: *Lock) void {
        if (self.state.cmpxchgWeak(
            UNLOCKED,
            LOCKED,
            .acquire,
            .monotonic,
        )) |_| {
            self.acquireSlow();
        }
    }

    fn acquireSlow(self: *Lock) void {
        @setCold(true);

        var spin = utils.SpinWait{};
        var state = self.state.load(.monotonic);

        while (true) {
            if (state & LOCKED == 0) {
                state = self.state.cmpxchgWeak(
                    state,
                    state | LOCKED,
                    .acquire,
                    .monotonic,
                ) orelse return;
                continue;
            }

            const head = @ptrFromInt(?*Waiter, state & WAITING);
            if (head == null and spin.yield()) {
                state = self.state.load(.monotonic);
                continue;
            }

            var waiter: Waiter = undefined;
            waiter = Waiter{
                .prev = null,
                .next = head,
                .tail = if (head == null) &waiter else null,
                .event = utils.Event{},
            };

            if (self.state.cmpxchgWeak(
                state,
                (state & ~WAITING) | @intFromPtr(&waiter),
                .release,
                .monotonic,
            )) |updated| {
                state = updated;
                continue;
            }

            waiter.event.wait();
            spin.reset();
            state = self.state.load(.monotonic);
        }
    }

    pub fn release(self: *Lock) void {
        const state = self.state.fetchSub(LOCKED, .release);
        if ((state & WAKING == 0) and (state & WAITING != 0)) {
            self.releaseSlow();
        }
    }

    fn releaseSlow(self: *Lock) void {
        @setCold(true);

        var state = self.state.load(.monotonic);
        while (true) {
            if ((state & (WAKING | LOCKED) != 0) or (state & WAITING == 0))
                return;
            state = self.state.cmpxchgWeak(
                state,
                state | WAKING,
                .acquire,
                .monotonic,
            ) orelse break;
        }

        state |= WAKING;
        dequeue: while (true) {
            const head = @ptrFromInt(*Waiter, state & WAITING);
            const tail = head.tail orelse blk: {
                var current = head;
                while (true) {
                    const next = current.next.?;
                    next.prev = current;
                    current = next;
                    if (current.tail) |tail| {
                        head.tail = tail;
                        break :blk tail;
                    }
                }
            };

            if (state & LOCKED != 0) {
                state = self.state.cmpxchgWeak(
                    state,
                    state & ~@as(usize, WAKING),
                    .acq_rel,
                    .acquire,
                ) orelse return;
                continue;
            }

            if (tail.prev) |new_tail| {
                head.tail = new_tail;
                _ = self.state.fetchAnd(~@as(usize, WAKING), .release);
            } else {
                while (true) {
                    state = self.state.cmpxchgWeak(
                        state,
                        state & LOCKED,
                        .acq_rel,
                        .acquire,
                    ) orelse break;
                    if (state & WAITING != 0) {
                        continue :dequeue;
                    }
                }
            }

            tail.event.notify();
            return;
        }
    }
};
