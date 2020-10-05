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
        waker: *sync.Waker,
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

    fn acquireSlow(self: *Lock, comptime Continuation: type) void {
        @setCold(true);

        const ContinuationWaker = struct {
            is_init: bool,
            waker: sync.Waker,
            continuation: Continuation,

            fn wake(waker: *sync.Waker) void {
                const continuation_waker = @fieldParentPtr(@This(), "waker", waker);
                continuation_waker.continuation.unblock();
            }
        };

        var continuation_waker: ContinuationWaker = undefined;
        continuation_waker.is_init = false;
        defer if (continuation_waker.is_init) {
            continuation_waker.continuation.deinit();
        };

        var waiter: Waiter = undefined;
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
                ) orelse break;
                continue;
            }

            const head = @intToPtr(?*Waiter, state & WAITING);
            if (head == null and spin < 10) {
                spin += 1;
                sync.spinLoopHint(@as(usize, 1) << spin);
                state = @atomicLoad(usize, &self.state, .Monotonic);
                continue;
            }

            waiter.prev = null;
            waiter.next = head;
            waiter.tail = if (head == null) &waiter else null;
            waiter.waker = &continuation_waker.waker;

            if (!continuation_waker.is_init) {
                continuation_waker.is_init = true;
                continuation_waker.continuation.init();
                continuation_waker.waker = sync.Waker{ .wakeFn = ContinuationWaker.wake };
            }

            continuation_waker.continuation.block((struct {
                state_ptr: *usize,
                state: usize,
                new_state: usize,

                pub fn shouldBlock(this: @This(), _continuation: *Continuation) bool {
                    return @cmpxchgWeak(
                        usize,
                        this.state_ptr,
                        this.state,
                        this.new_state,
                        .Release,
                        .Monotonic,
                    ) == null;
                }
            }){
                .state_ptr = &self.state,
                .state = state,
                .new_state = (state & ~WAITING) | @ptrToInt(&waiter),
            });

            spin = 0;
            sync.spinLoopHint(1);
            state = @atomicLoad(usize, &self.state, .Monotonic);
        }
    }

    fn release(self: *Lock) void {
        const state = @atomicRmw(usize, &self.state, .Sub, LOCKED, .Release);
        if (state != LOCKED) {
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