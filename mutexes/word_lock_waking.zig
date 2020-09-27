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
const Parker = @import("../v2/parker.zig").OsParker;

pub const Mutex = struct {
    pub const NAME = "word_lock_waking";

    const UNLOCKED = 0;
    const LOCKED = 1 << 0;
    const WAKING = 1 << 8;
    const WAITING = ~@as(usize, (1 << 9) - 1);

    const Waiter = struct {
        prev: ?*Waiter align((~WAITING) + 1),
        next: ?*Waiter,
        tail: ?*Waiter,
        parker: Parker,
    };

    state: usize = UNLOCKED,

    pub fn init(self: *Mutex) void {
        self.* = Mutex{};
    }

    pub fn deinit(self: *Mutex) void {
        self.* = undefined;
    }

    pub fn acquire(self: *Mutex) void {
        const acquired = switch (std.builtin.arch) {
            // on x86, unlike cmpxchg, bts doesnt require a register setup for the value
            // which results in a slightly smaller hit on the i-cache. 
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

    fn acquireSlow(self: *Mutex) void {
        @setCold(true);

        var waiter: Waiter = undefined;
        waiter.parker = Parker.init();
        defer waiter.parker.deinit();

        var spin: u4 = 0;
        var is_waking = false;
        var state = @atomicLoad(usize, &self.state, .Monotonic);

        while (true) {
            var new_state = state;
            const head = @intToPtr(?*Waiter, state & WAITING);

            if (state & LOCKED == 0) {
                new_state |= LOCKED;

            } else if (head == null and spin <= 5) {
                std.SpinLock.loopHint(@as(usize, 1) << spin);
                spin += 1;
                state = @atomicLoad(usize, &self.state, .Monotonic);
                continue;

            } else {
                waiter.prev = null;
                waiter.next = head;
                waiter.tail = if (head == null) &waiter else null;
                waiter.parker.prepare();
                new_state = (new_state & ~WAITING) | @ptrToInt(&waiter);
            }

            if (is_waking)
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

            waiter.parker.park();
            spin = 0;
            is_waking = true;
            state = @atomicLoad(usize, &self.state, .Monotonic);
        }
    }

    pub fn release(self: *Mutex) void {
        @atomicStore(u8, @ptrCast(*u8, &self.state), UNLOCKED, .Release);

        const state = @atomicLoad(usize, &self.state, .Monotonic);
        if ((state & WAITING != 0) and (state & (WAKING | LOCKED) == 0))
            self.releaseSlow(state);
    }

    fn releaseSlow(self: *Mutex, current_state: usize) void {
        @setCold(true);

        var state = current_state;
        while (true) {
            if ((state & WAITING == 0) or (state & (LOCKED | WAKING) != 0))
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
                state & WAKING,
                .Release,
                .Acquire,
            )) |updated_state| {
                state = updated_state;
                continue;
            }

            tail.parker.unpark();
            return;
        }
    }
};