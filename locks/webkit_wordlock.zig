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
    pub const name = "webkit_wordlock";

    state: usize = UNLOCKED,

    const UNLOCKED = 0;
    const LOCKED = 1;
    const QLOCKED = 2;
    const WAITING = ~@as(usize, LOCKED | QLOCKED);

    const Waiter = struct {
        next: ?*Waiter align(~WAITING + 1),
        tail: *Waiter,
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

        var spin: std.math.Log2Int(usize) = 0;
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

            if (spin < 40) {
                spin += 1;
                utils.yieldThread(1);
                state = @atomicLoad(usize, &self.state, .Monotonic);
                continue;
            }

            if (state & QLOCKED != 0) {
                utils.yieldThread(1);
                state = @atomicLoad(usize, &self.state, .Monotonic);
                continue;
            }

            if (@cmpxchgWeak(
                usize,
                &self.state,
                state,
                state | QLOCKED,
                .Acquire,
                .Monotonic,
            )) |updated| {
                state = updated;
                continue;
            }

            var waiter: Waiter = undefined;
            waiter.next = null;
            waiter.event = utils.Event{};

            var head = @intToPtr(?*Waiter, state & WAITING);
            if (head) |h| {
                h.tail.next = &waiter;
                h.tail = &waiter;
            } else {
                head = &waiter;
                waiter.tail = &waiter;
            }

            @atomicStore(usize, &self.state, @ptrToInt(head) | LOCKED, .Release);
            waiter.event.wait();

            // spin = 0;
            waiter.event.reset();
            state = @atomicLoad(usize, &self.state, .Monotonic);
        }
    }

    pub fn release(self: *Lock) void {
        if (@cmpxchgWeak(
            usize,
            &self.state,
            LOCKED,
            UNLOCKED,
            .Release,
            .Monotonic,
        )) |_| {
            self.releaseSlow();
        }
    }

    fn releaseSlow(self: *Lock) void {
        @setCold(true);

        var state = @atomicLoad(usize, &self.state, .Monotonic);

        while (true) {
            if (state & QLOCKED != 0) {
                utils.yieldThread(1);
                state = @atomicLoad(usize, &self.state, .Monotonic);
                continue;
            }

            const waiter = @intToPtr(?*Waiter, state & WAITING) orelse {
                state = @cmpxchgWeak(
                    usize,
                    &self.state,
                    state,
                    state & ~@as(usize, LOCKED),
                    .Release,
                    .Monotonic,
                ) orelse return;
                continue;
            };

            if (@cmpxchgWeak(
                usize,
                &self.state,
                state,
                state | QLOCKED,
                .Acquire,
                .Monotonic,
            )) |updated| {
                state = updated;
                continue;
            }

            const head = waiter.next;
            if (head) |h|
                h.tail = waiter.tail;

            @atomicStore(usize, &self.state, @ptrToInt(head), .Release);
            waiter.event.notify();
            return;
        }
    }
};