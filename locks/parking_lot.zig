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
    pub const name = "parking_lot";

    state: u16 = UNLOCKED,

    const UNLOCKED = 0;
    const LOCKED = 1;
    const PARKED = 2;

    pub fn init(self: *Lock) void {
        self.* = Lock{};
    }

    pub fn deinit(self: *Lock) void {
        self.* = undefined;
    }

    pub fn acquire(self: *Lock) void {
        const acquired = asm volatile(
            "lock btsw $0, %[ptr]"
            : [ret] "={@ccc}" (-> u8),
            : [ptr] "*m" (&self.state)
            : "cc", "memory"
        ) == 0;
        if (!acquired) {
            self.acquireSlow();
        }
    }

    fn acquireSlow(self: *Lock) void {
        @setCold(true);

        var spin = utils.SpinWait{};
        var state = @atomicLoad(u16, &self.state, .Monotonic);

        while (true) {
            if (state & LOCKED == 0) {
                const acquired = asm volatile(
                    "lock btsw $0, %[ptr]"
                    : [ret] "={@ccc}" (-> u8),
                    : [ptr] "*m" (&self.state)
                    : "cc", "memory"
                ) == 0;
                if (acquired)
                    return;
                utils.yieldThread(1);
                state = @atomicLoad(u16, &self.state, .Monotonic);
                continue;
            }

            if (state & PARKED == 0) {
                if (spin.yield()) {
                    state = @atomicLoad(u16, &self.state, .Monotonic);
                    continue;
                }

                if (@cmpxchgWeak(
                    u16,
                    &self.state,
                    state,
                    state | PARKED,
                    .Monotonic,
                    .Monotonic,
                )) |updated| {
                    state = updated;
                    continue; 
                }
            }

            const addr = @ptrToInt(&self.state);
            const bucket = Bucket.get(addr);
            bucket.lock.acquire();

            state = @atomicLoad(u16, &self.state, .Monotonic);
            if (state != (PARKED | LOCKED)) {
                bucket.lock.release();
                spin.reset();
                state = @atomicLoad(u16, &self.state, .Monotonic);
                continue;
            }

            var waiter: Waiter = undefined;
            waiter.addr = addr;
            waiter.next = null;
            waiter.acquired = false;
            waiter.event = utils.Event{};
            if (bucket.tail) |t| {
                t.next = &waiter;
                waiter.prev = t;
            } else {
                bucket.head = &waiter;
                waiter.prev = null;
            }
            bucket.tail = &waiter;
            bucket.lock.release();

            waiter.event.wait();
            if (waiter.acquired)
                return;

            spin.reset();
            state = @atomicLoad(u16, &self.state, .Monotonic);
        }
    }

    pub fn release(self: *Lock) void {
        if (@cmpxchgWeak(
            u16,
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

        var state = @atomicLoad(u16, &self.state, .Monotonic);
        while (state == LOCKED) {
            state = @cmpxchgWeak(
                u16,
                &self.state,
                state,
                UNLOCKED,
                .Release,
                .Monotonic,
            ) orelse return;
        }

        const addr = @ptrToInt(&self.state);
        const bucket = Bucket.get(addr);
        bucket.lock.acquire();

        const waiter = blk: {
            var waiter = bucket.head;
            while (waiter) |w| {
                if (w.addr == addr) {
                    if (w.prev) |p|
                        p.next = w.next;
                    if (w.next) |n|
                        n.prev = w.prev;
                    if (bucket.head == @as(?*Waiter, w))
                        bucket.head = w.next;
                    if (bucket.tail == @as(?*Waiter, w))
                        bucket.tail = w.prev;
                    break :blk w;
                }
                waiter = w.next;
            }
            break :blk null;
        };

        if (waiter) |w| {
            const has_more = bucket.head != null;
            const be_fair = false;
            // const be_fair = blk: {
            //     const now = utils.nanotime();
            //     const be_fair = now > bucket.timed_out;
            //     if (be_fair) {
            //         var x = bucket.prng;
            //         x ^= x << 13;
            //         x ^= x >> 17;
            //         x ^= x << 5;
            //         bucket.prng = x;
            //         var timeout = x % (1 * std.time.ns_per_ms);
            //         bucket.timed_out = now + timeout;
            //     }
            //     break :blk be_fair;
            // };

            w.acquired = be_fair;
            if (be_fair) {
                if (!has_more)
                    @atomicStore(u16, &self.state, LOCKED, .Monotonic);
            } else  {
                state = if (has_more) PARKED else UNLOCKED;
                @atomicStore(u16, &self.state, state, .Release);
            }
        } else {
            @atomicStore(u16, &self.state, UNLOCKED, .Release);
        }

        bucket.lock.release();
        if (waiter) |w|
            w.event.notify();
    }

    const Waiter = struct {
        addr: usize,
        prev: ?*Waiter,
        next: ?*Waiter,
        acquired: bool,
        event: utils.Event,
    };

    const Bucket = struct {
        lock: WordLock,
        head: ?*Waiter,
        tail: ?*Waiter,
        timed_out: u64,
        prng: u32,
        timer: std.time.Timer,

        // const WordLock = @import("./spin.zig").Lock;
        const WordLock = @import("./word_lock_waking.zig").Lock;

        var bk_state = State.uninit;
        var bk_instance: Bucket = undefined;

        const State = extern enum(usize) {
            uninit,
            pending,
            init,
        };

        fn get(addr: usize) *Bucket {
            if (@atomicLoad(State, &bk_state, .Acquire) != .init)
                initSlow();
            return &bk_instance;
        }

        fn initSlow() void {
            @setCold(true);

            var state = @atomicLoad(State, &bk_state, .Acquire);
            while (true) {
                switch (state) {
                    .uninit => state = @cmpxchgWeak(
                        State,
                        &bk_state,
                        .uninit,
                        .pending,
                        .Acquire,
                        .Acquire,
                    ) orelse break,
                    .pending => {
                        utils.yieldThread(1);
                        state = @atomicLoad(State, &bk_state, .Acquire);
                    },
                    .init => return,
                }
            }

            bk_instance.lock.init();
            bk_instance.head = null;
            bk_instance.tail = null;
            bk_instance.timed_out = 0;
            bk_instance.prng = @truncate(u32, @ptrToInt(&bk_instance) >> 16);
            @atomicStore(State, &bk_state, .init, .Release);
        }
    };
};