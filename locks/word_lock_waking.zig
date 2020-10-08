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

pub const Lock = extern struct {
    pub const name = "word_lock_waking";

    state: usize = UNLOCKED,

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
        if (@cmpxchgWeak(
            usize,
            &self.state,
            UNLOCKED,
            LOCKED,
            .Acquire,
            .Monotonic,
        )) |_| {
            self.acquireSlow();
        }
    }

    fn acquireSlow(self: *Lock) void {
        @setCold(true);

        var spin = utils.SpinWait{};
        var state = @atomicLoad(usize, &self.state, .Monotonic);

        while (true) {
            if (state & LOCKED == 0) {
                state = @cmpxchgWeak(
                    usize,
                    &self.state,
                    state,
                    state | LOCKED,
                    .Acquire,
                    .Monotonic,
                ) orelse return;
                continue;
            }
            
            const head = @intToPtr(?*Waiter, state & WAITING);
            if (head == null and spin.yield()) {
                state = @atomicLoad(usize, &self.state, .Monotonic);
                continue;
            }

            var waiter: Waiter = undefined;
            waiter = Waiter{
                .prev = null,
                .next = head,
                .tail = if (head == null) &waiter else null,
                .event = utils.Event{},
            };

            if (@cmpxchgWeak(
                usize,
                &self.state,
                state,
                (state & ~WAITING) | @ptrToInt(&waiter),
                .Release,
                .Monotonic,
            )) |updated| {
                state = updated;
                continue;
            }

            waiter.event.wait();
            spin.reset();

            _ = @atomicRmw(usize, &self.state, .And, ~@as(usize, WAKING), .Release);
            state = @atomicLoad(usize, &self.state, .Monotonic);
        }
    }

    pub fn release(self: *Lock) void {
        const state = @atomicRmw(usize, &self.state, .Sub, LOCKED, .Release);
        if ((state & WAKING == 0) and (state & WAITING != 0)) {
            self.releaseSlow();
        }
    }

    fn releaseSlow(self: *Lock) void {
        @setCold(true);

        var state = @atomicLoad(usize, &self.state, .Monotonic);
        while (true) {
            if ((state & (WAKING | LOCKED) != 0) or (state & WAITING == 0))
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

        state |= WAKING;
        while (true) {
            const head = @intToPtr(*Waiter, state & WAITING);
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
                state = @cmpxchgWeak(
                    usize,
                    &self.state,
                    state,
                    state & ~@as(usize, WAKING),
                    .Release,
                    .Acquire,
                ) orelse return;
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
                .AcqRel,
                .Acquire,
            )) |updated| {
                state = updated;
                continue;
            }

            tail.event.notify();
            return;
        }
    }
};