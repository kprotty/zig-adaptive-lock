// Copyright (c) 2022 kprotty
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
const builtin = @import("builtin");

const assert = std.debug.assert;
const Atomic = std.atomic.Atomic;

const unlocked = 0;
const locked = 1;
const queued = 2;
const queue_locked = 4;
const waiter_mask = ~@as(usize, locked | queued | queue_locked);

const Waiter = struct {
    prev: ?*Waiter align(8),
    next: ?*Waiter,
    tail: ?*Waiter,
    event: @import("../utils.zig").Event,
};

pub const Lock = extern struct {
    pub const name = "queue_lock";

    state: Atomic(usize) = Atomic(usize).init(0),

    pub fn init(self: *Lock) void {
        self.* = .{};
    }

    pub fn deinit(self: *Lock) void {
        self.* = undefined;
    }

    inline fn tryAcquire(self: *Lock) bool {
        return self.state.bitSet(@ctz(usize, locked), .Acquire) == 0;
    }

    pub inline fn acquire(self: *Lock) void {
        if (!self.tryAcquire())
            self.acquireSlow();
    }

    noinline fn acquireSlow(self: *Lock) void {
        var spin: usize = 0;
        var has_event = false;
        var waiter: Waiter = undefined;
        var state = self.state.load(.Monotonic);
        
        while (true) {
            var backoff: usize = 0;
            while (state & locked == 0) {
                if (self.tryAcquire()) {
                    if (has_event) waiter.event.deinit();
                    return;
                }

                backoff = std.math.min(32, backoff << 1);
                var i: usize = backoff;
                while (i > 0) : (i -= 1) std.atomic.spinLoopHint();

                state = self.state.load(.Monotonic);
            }

            if ((state & queued == 0) and spin < 32) {
                spin += 1;
                std.atomic.spinLoopHint();
                state = self.state.load(.Monotonic);
                continue;
            }

            if (!has_event) {
                has_event = true;
                waiter.event = .{};
            }

            var new_state = (state & ~waiter_mask) | @ptrToInt(&waiter) | queued;
            if (state & queued == 0) {
                assert(state & waiter_mask == 0);
                waiter.tail = &waiter;
                waiter.next = null;
                waiter.prev = null;
            } else {
                new_state |= queue_locked;
                waiter.tail = null;
                waiter.next = @intToPtr(?*Waiter, state & waiter_mask);
                waiter.prev = null;
            }

            state = self.state.tryCompareAndSwap(state, new_state, .Release, .Monotonic) orelse blk: {
                if (state & (queued | queue_locked) == queued) {
                    self.linkQueueOrUnpark(new_state);
                }
                
                spin = 0;
                waiter.event.wait();
                waiter.event.reset();
                break :blk self.state.load(.Monotonic);
            };
        }
    }

    pub inline fn release(self: *Lock) void {
        const state = self.state.compareAndSwap(locked, unlocked, .Release, .Monotonic) orelse return;
        self.releaseSlow(state);
    }

    noinline fn releaseSlow(self: *Lock, current_state: usize) void {
        var state = current_state;
        while (true) {
            assert(state & locked != 0);
            assert(state & queued != 0);

            var new_state = state & ~@as(usize, locked);
            new_state |= queue_locked;

            state = self.state.tryCompareAndSwap(state, new_state, .Release, .Monotonic) orelse {
                if (state & queue_locked == 0) self.unpark(new_state);
                return;
            };
        }
    }

    fn linkQueueOrUnpark(self: *Lock, current_state: usize) void {
        var state = current_state;
        while (true) {
            assert(state & (queued | queue_locked) == (queued | queue_locked));
            if (state & locked == 0) {
                return self.unpark(state);
            }

            std.atomic.fence(.Acquire);
            _ = self.getAndLinkQueue(state);

            const new_state = state & ~@as(usize, queue_locked); 
            state = self.state.tryCompareAndSwap(state, new_state, .Release, .Monotonic) orelse return;
        }
    }

    noinline fn unpark(self: *Lock, current_state: usize) void {
        var state = current_state;
        while (true) {
            assert(state & (queued | queue_locked) == (queued | queue_locked));
            if (state & locked != 0) {
                const new_state = state & ~@as(usize, queue_locked);
                state = self.state.tryCompareAndSwap(state, new_state, .Release, .Monotonic) orelse return;
                continue;
            }

            std.atomic.fence(.Acquire);
            const queue = self.getAndLinkQueue(state);
            assert(queue.head.tail == queue.tail);

            if (queue.tail.prev) |new_tail| {
                queue.head.tail = new_tail;
                _ = self.state.fetchAnd(~@as(usize, queue_locked), .Release);
                return queue.tail.event.notify();
            }

            const new_state = unlocked;
            state = self.state.tryCompareAndSwap(state, new_state, .Release, .Monotonic) orelse {
                return queue.tail.event.notify();
            };
        }
    }

    const Queue = struct {
        head: *Waiter,
        tail: *Waiter,
    };

    fn getAndLinkQueue(self: *Lock, state: usize) Queue {
        _ = self;
        assert(state & (queued | queue_locked) == (queued | queue_locked));

        var queue: Queue = undefined;
        queue.head = @intToPtr(*Waiter, state & waiter_mask);
        queue.tail = queue.head.tail orelse blk: {
            var current = queue.head;
            while (true) {
                const next = current.next orelse unreachable;
                std.debug.assert(next.prev == null);
                next.prev = current;
                current = next;

                if (current.tail) |tail| {
                    queue.head.tail = tail;
                    break :blk tail;
                }
            }
        };

        return queue;
    }
};