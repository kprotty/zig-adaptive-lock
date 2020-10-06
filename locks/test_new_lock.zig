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
const Futex = @import("./futex.zig").Futex;

pub const Lock = struct {
    pub const name = "test_new_lock";

    state: usize,

    const UNLOCKED = 0;
    const LOCKED = 1 << 0;
    const WAITING = ~@as(usize, LOCKED);

    const Waiter = struct {
        prev: ?*Waiter align((~WAITING) + 1),
        next: ?*Waiter,
        tail: ?*Waiter,
        event: sync.Event,
        acquired: bool,
        force_fair_at: u64,
    };

    pub fn init(self: *Lock) void {
        self.state = 0;
    }

    pub fn deinit(self: *Lock) void {
        self.* = undefined;
    }

    pub fn withLock(self: *Lock, context: anytype) void {
        self.acquire();
        context.run();
        self.release();
    }

    fn acquire(self: *Lock) void {
        const acquired = switch (std.builtin.arch) {
            .i386, .x86_64 => asm volatile(
                "lock btsl $0, %[ptr]"
                : [ret] "={@ccc}" (-> u8),
                : [ptr] "*m" (&self.state)
                : "cc", "memory"
            ) == 0,
            else => @cmpxchgWeak(
                usize,
                &self.state,
                UNLOCKED,
                LOCKED,
                .Acquire,
                .Monotonic,
            ) == null,
        };

        if (!acquired)
            self.acquireSlow();
    }

    fn acquireSlow(self: *Lock) void {
        @setCold(true);

        var has_event = false;
        var waiter: Waiter = undefined;
        defer if (has_event) {
            waiter.event.deinit();
        };

        var spin: std.math.Log2Int(usize) = 0;
        var state = @atomicLoad(usize, &self.state, .Monotonic);

        while (true) {
            var new_state = state;
            const head = @intToPtr(?*Waiter, state & WAITING);

            if (state & LOCKED == 0) {
                new_state |= LOCKED;

            } else if (head == null and spin < 10) {
                std.SpinLock.loopHint(@as(usize, 1) << spin);
                spin += 1;
                state = @atomicLoad(usize, &self.state, .Monotonic);
                continue;

            } else {
                waiter.prev = null;
                waiter.next = head;
                waiter.tail = if (head == null) &waiter else null;
                new_state = (new_state & ~WAITING) | @ptrToInt(&waiter);

                if (!has_event) {
                    has_event = true;
                    
                    var timeout = @as(u64, @ptrToInt(head orelse &waiter));
                    timeout = (13 *% timeout) ^ (timeout >> 15);
                    timeout %= 500 * std.time.ns_per_us;
                    timeout += 500 * std.time.ns_per_us;

                    waiter.event.init();
                    waiter.force_fair_at = sync.nanotime();
                    waiter.force_fair_at += timeout;
                }
            }

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

            waiter.event.wait();
            if (waiter.acquired) {
                break;
            }

            spin = 0;
            state = @atomicLoad(usize, &self.state, .Monotonic);
        }
    }

    fn release(self: *Lock) void {
        if (@cmpxchgStrong(
            usize,
            &self.state,
            LOCKED,
            UNLOCKED,
            .Release,
            .Monotonic,
        ) != null) {
            self.releaseSlow();
        }
    }

    fn releaseSlow(self: *Lock) void {
        @setCold(true);

        var released_at: ?u64 = null;
        var state = @atomicLoad(usize, &self.state, .Acquire);

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

            const released = released_at orelse blk: {
                released_at = sync.nanotime();
                break :blk released_at.?;
            };

            const be_fair = released >= tail.force_fair_at;

            if (tail.prev) |new_tail| {
                head.tail = new_tail;
                if (!be_fair) {
                    _ = @atomicRmw(usize, &self.state, .And, ~@as(usize, LOCKED), .Release);
                }

            } else if (@cmpxchgWeak(
                usize,
                &self.state,
                state,
                @as(usize, if (be_fair) LOCKED else UNLOCKED),
                .AcqRel,
                .Acquire,
            )) |updated_state| {
                state = updated_state;
                continue;
            }

            tail.acquired = be_fair;
            tail.event.notify();
            return;
        }
    }
};
