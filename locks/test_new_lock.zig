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

pub const Lock = extern struct {
    pub const name = "word_lock_waking";

    const UNLOCKED = 0;
    const LOCKED = 1;
    const WAKING = 1 << 8;
    const WAITING = ~@as(usize, (1 << 9) - 1);

    const Waiter = struct {
        next: ?*Waiter align(~WAITING + 1),
        prev: ?*Waiter,
        tail: ?*Waiter,
        waker: sync.Waker,
    };

    state: usize,

    pub fn init(self: *Lock) void {
        self.state = UNLOCKED;
    }

    pub fn deinit(self: *Lock) void {
        self.* = undefined;
    }

    pub fn withLock(self: *Lock, context: anytype) void {
        self.acquire(sync.Event);
        context.run();
        self.release();
    }

    pub fn acquire(self: *Lock, comptime Event: type) void {
        if (@atomicRmw(u8, @ptrCast(*u8, &self.state), .Xchg, LOCKED, .Acquire) != UNLOCKED) {
            self.acquireSlow(Event);
        }
    }

    fn acquireSlow(self: *Lock, comptime Event: type) void {
        @setCold(true);

        const EventWaiter = struct {
            event: Event,
            waiter: Waiter,

            fn wake(waker: *sync.Waker) void {
                const waiter = @fieldParentPtr(Waiter, "waker", waker);
                const this = @fieldParentPtr(@This(), "waiter", waiter);
                this.event.notify();
            }
        };

        var has_event = false;
        var ev: EventWaiter = undefined;
        defer if (has_event) {
            ev.event.deinit();
        };
        
        var is_waiting = false;
        var spin: std.math.Log2Int(usize) = 0;
        var state = @atomicLoad(usize, &self.state, .Monotonic);
        while (true) {

            var new_state: usize = undefined;
            if (state & LOCKED == 0) {
                new_state = state | LOCKED;

            } else {
                const head = @intToPtr(?*Waiter, state & WAITING);
                if (head == null and spin < 40) {
                    spin += 1;
                    if (std.builtin.os.tag == .windows) {
                        _ = std.os.windows.kernel32.SwitchToThread();
                    } else {
                        std.os.sched_yield() catch unreachable;
                    }
                    state = @atomicLoad(usize, &self.state, .Monotonic);
                    continue;
                }

                if (!has_event) {
                    has_event = true;
                    ev.event.init();
                    ev.waiter.waker = sync.Waker{ .wakeFn = EventWaiter.wake };
                }

                ev.waiter.prev = null;
                ev.waiter.next = head;
                ev.waiter.tail = if (head == null) &ev.waiter else null;
                new_state = (state & ~WAITING) | @ptrToInt(&ev.waiter);
            }

            if (is_waiting)
                new_state &= ~@as(usize, WAKING);

            if (@cmpxchgWeak(
                usize,
                &self.state,
                state,
                new_state,
                .AcqRel,
                .Monotonic,
            )) |updated_state| {
                state = updated_state;
                continue;
            }

            if (state & LOCKED == 0)
                break;

            ev.event.wait();
            // spin = 0;
            _ = @atomicRmw(usize, &self.state, .And, ~@as(usize, WAKING), .Monotonic);// is_waiting = true;
            state = @atomicLoad(usize, &self.state, .Monotonic);
        }
    }

    pub fn release(self: *Lock) void {
        // const state = @atomicRmw(usize, &self.state, .Sub, LOCKED, .Release);
        // if ((state & WAKING == 0) and (state & WAITING != 0)) {
        //     self.releaseSlow();
        // }
        @atomicStore(u8, @ptrCast(*u8, &self.state), UNLOCKED, .Release);
        const state = @atomicLoad(usize, &self.state, .Monotonic);
        if ((state & (WAKING | LOCKED) == 0) and (state & WAITING != 0)) {
            self.releaseSlow();
        }
    }

    fn releaseSlow(self: *Lock) void {
        @setCold(true);

        var state = @atomicLoad(usize, &self.state, .Monotonic);
        while (true) {
            if ((state & (LOCKED | WAKING) != 0) or (state & WAITING == 0)) {
                return;
            }
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
                ) orelse break;
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
                .Release,
                .Acquire,
            )) |updated_state| {
                state = updated_state;
                continue;
            }

            tail.waker.wake();
            return;
        }
    }
};