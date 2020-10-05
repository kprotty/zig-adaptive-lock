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
    pub const name = "word_lock";

    const UNLOCKED = 0;
    const LOCKED = 1;
    const WAKING = 2;
    const WAITING = ~@as(usize, LOCKED | WAKING);

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
        self.acquire(sync.OsContinuation);
        context.run();
        self.release();
    }

    fn acquire(self: *Lock, comptime Continuation: type) void {
        if (@cmpxchgWeak(
            usize,
            &self.state,
            UNLOCKED,
            LOCKED,
            .Acquire,
            .Monotonic,
        )) |_| {
            self.acquireSlow(Continuation);
        }
    }

    fn acquireSlow(this_lock: *Lock, comptime Continuation: type) void {
        @setCold(true);

        const Future = struct {
            lock: *Lock,
            acquired: bool,
            waiter: Waiter,
            continuation: Continuation,

            fn wake(waker: *sync.Waker) void {
                const waiter = @fieldParentPtr(Waiter, "waker", waker);
                const self = @fieldParentPtr(@This(), "waiter", waiter);
                self.continuation.unblock();
            }

            pub fn shouldBlock(self: *@This(), _continuation: *Continuation) bool {
                const max_spin = switch (std.builtin.os.tag) {
                    .windows => 10,
                    else => 5,
                };
                
                var spin: std.math.Log2Int(usize) = 0;
                var state = @atomicLoad(usize, &self.lock.state, .Monotonic);

                while (true) {
                    var new_state: usize = undefined;

                    if (state & LOCKED == 0) {
                        new_state = state | LOCKED;
                    } else {
                        const head = @intToPtr(?*Waiter, state & WAITING);
                        if (head == null and spin < max_spin) {
                            spin += 1;
                            sync.spinLoopHint(@as(usize, 1) << spin);
                            state = @atomicLoad(usize, &self.lock.state, .Monotonic);
                            continue;
                        }

                        self.waiter.prev = null;
                        self.waiter.next = head;
                        self.waiter.tail = if (head == null) &self.waiter else null;
                        self.waiter.waker = sync.Waker{ .wakeFn = @This().wake };
                        new_state = (state & ~WAITING) | @ptrToInt(&self.waiter);
                    }

                    state = @cmpxchgWeak(
                        usize,
                        &self.lock.state,
                        state,
                        new_state,
                        .AcqRel,
                        .Monotonic,
                    ) orelse {
                        self.acquired = state & LOCKED == 0;
                        return !self.acquired;
                    };
                }
            }
        };

        var future: Future = undefined;
        future.continuation.init();
        defer future.continuation.deinit();

        future.lock = this_lock;
        future.acquired = false;

        while (!future.acquired) {
            future.continuation.block(&future);
        }
    }

    fn release(self: *Lock) void {
        const state = @atomicRmw(usize, &self.state, .Sub, LOCKED, .Release);
        if ((state & WAKING == 0) and (state & WAITING != 0)) {
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
                _ = @atomicRmw(usize, &self.state, .And, ~@as(usize, WAKING), .Release);

            } else if (@cmpxchgWeak(
                usize,
                &self.state,
                state,
                UNLOCKED,
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