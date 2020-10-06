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

pub const Lock = struct {
    pub const name = "parking_lot";

    const UNLOCKED = 0;
    const LOCKED = 1;
    const PARKED = 2;

    state: u8 align(128) = UNLOCKED,
    bucket: Bucket align(128) = Bucket{},

    pub fn init(self: *Lock) void {
        self.* = Lock{};
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
        if (@cmpxchgWeak(
            u8,
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

        var spin_wait = SpinWait{};
        var state = @atomicLoad(u8, &self.state, .Monotonic);

        while (true) {
            if (state & LOCKED == 0) {
                state = @cmpxchgWeak(
                    u8,
                    &self.state,
                    state,
                    state | LOCKED,
                    .Acquire,
                    .Monotonic,
                ) orelse return;
                continue;
            }

            if ((state & PARKED == 0) and spin_wait.spin()) {
                state = @atomicLoad(u8, &self.state, .Monotonic);
                continue;
            }

            if (state & PARKED == 0) {
                if (@cmpxchgWeak(
                    u8,
                    &self.state,
                    state,
                    state | PARKED,
                    .Monotonic,
                    .Monotonic,
                )) |new_state| {
                    state = new_state;
                    continue;
                }
            }

            switch (blk: {
                self.bucket.lock.lock();

                if (@atomicLoad(u8, &self.state, .Monotonic) != (LOCKED | PARKED)) {
                    self.bucket.lock.unlock();
                    break :blk ParkResult.invalid;
                }

                var waiter: Waiter = undefined;
                waiter.event.init();
                defer waiter.event.deinit();

                waiter.next = null;
                if (self.bucket.tail) |tail| {
                    tail.next = &waiter;
                } else {
                    self.bucket.head = &waiter;
                }
                self.bucket.tail = &waiter;
                self.bucket.lock.unlock();

                waiter.event.wait();
                if (waiter.acquired)
                    break :blk ParkResult.handoff;
                break :blk ParkResult.unparked;
            }) {
                .handoff => return,
                .unparked => {},
                .invalid => {},
            }

            spin_wait.reset();
            state = @atomicLoad(u8, &self.state, .Monotonic);
        }
    }

    fn release(self: *Lock) void {
        if (@cmpxchgStrong(
            u8,
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
        const force_fair = false;

        var result = UnparkResult{
            .unparked = 0,
            .be_fair = false,
            .has_more = false,
        };
        
        self.bucket.lock.lock();

        const waiter = self.bucket.head;
        if (waiter) |w| {
            self.bucket.head = w.next;
            if (self.bucket.head == null)
                self.bucket.tail = null;
                
            result.unparked = 1;
            result.has_more = self.bucket.head != null;
            result.be_fair = should_timeout: {
                
                var now = @import("../sync/instant.zig").Os.nanotime();
                const last_now = self.bucket.last_now;
                if (last_now == 0 or (now > last_now)) {
                    self.bucket.last_now = now;
                } else {
                    now = last_now;
                }

                if (last_now == 0) {
                    self.bucket.seed = @truncate(u32, @ptrToInt(&self.bucket) >> 16) | 31;
                    self.bucket.timeout = now;
                }

                const timed_out = now > self.bucket.timeout;
                if (timed_out) {
                    const gen_u32 = gen: {
                        self.bucket.seed ^= self.bucket.seed << 13;
                        self.bucket.seed ^= self.bucket.seed >> 17;
                        self.bucket.seed ^= self.bucket.seed << 5;
                        break :gen self.bucket.seed;
                    };
                    const nanos = gen_u32 % 1_000_000;
                    // const nanos = (gen_u32 % 500_000) + 500_000;
                    self.bucket.timeout = now + nanos;
                }
                break :should_timeout timed_out;
                // break :should_timeout false;
            };
        }

        const acquired = callback: {
            if ((result.unparked != 0) and (force_fair or result.be_fair)) {
                if (!result.has_more)
                    @atomicStore(u8, &self.state, LOCKED, .Monotonic);
                break :callback true;
            }

            const new_state: u8 = if (result.has_more) PARKED else UNLOCKED;
            @atomicStore(u8, &self.state, new_state, .Release);
            break :callback false;
        };

        if (waiter) |w|
            w.acquired = acquired;

        self.bucket.lock.unlock();

        if (waiter) |w|
            w.event.notify();
    }

    const ParkResult = enum {
        handoff,
        unparked,
        invalid,
    };

    const UnparkResult = struct {
        unparked: usize,
        be_fair: bool,
        has_more: bool,
    };

    const Bucket = struct {
        lock: WordLock = WordLock{},
        head: ?*Waiter = null,
        tail: ?*Waiter = null,
        timeout: u64 = 0,
        last_now: u64 = 0,
        seed: u32 = 0,
    };

    const SpinWait = struct {
        counter: std.math.Log2Int(usize) = 0,

        fn spin(self: *SpinWait) bool {
            switch (std.builtin.os.tag) {
                .windows => {
                    if (self.counter > 10)
                        return false;
                    sync.spinLoopHint(@as(usize, 1) << self.counter);
                    self.counter += 1;
                    return true;
                },
                .linux => {
                    if (self.counter > 10)
                        return false;
                    if (self.counter <= 3) {
                        sync.spinLoopHint(@as(usize, 1) << self.counter);
                    } else {
                        std.os.sched_yield() catch unreachable;
                    }
                    self.counter += 1;
                    return true;
                },
                else => {
                    if (self.counter >= 40)
                        return false;
                    std.os.sched_yield() catch unreachable;
                    self.counter += 1;
                    return true;
                },
            }
        }

        fn reset(self: *SpinWait) void {
            self.counter = 0;
        }
    };

    const Waiter = struct {
        prev: ?*Waiter align(4),
        next: ?*Waiter,
        tail: ?*Waiter,
        event: sync.Event,
        acquired: bool,
    };

    const WordLock = 
        if (std.builtin.os.tag == .windows)
            struct {
                srwlock: usize = 0,

                extern "kernel32" fn AcquireSRWLockExclusive(p: *usize) callconv(.Stdcall) void;
                extern "kernel32" fn ReleaseSRWLockExclusive(p: *usize) callconv(.Stdcall) void;

                fn lock(self: *WordLock) void {
                    AcquireSRWLockExclusive(&self.srwlock);
                }

                fn unlock(self: *WordLock) void {
                    ReleaseSRWLockExclusive(&self.srwlock);
                }
            }
        else
            struct {
                state: usize = UNLOCKED,

                const QLOCKED = PARKED;
                const WAITING = ~@as(usize, LOCKED | QLOCKED);

                fn lock(self: *WordLock) void {
                    if (@cmpxchgWeak(
                        usize,
                        &self.state,
                        UNLOCKED,
                        LOCKED,
                        .Acquire,
                        .Monotonic,
                    )) |_| {
                        self.lockSlow();
                    }
                }

                fn lockSlow(self: *WordLock) void {
                    @setCold(true);

                    var has_event = false;
                    var waiter: Waiter = undefined;
                    defer if (has_event) {
                        waiter.event.deinit();
                    };

                    var spin_wait = SpinWait{};
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
                        if ((head == null) and spin_wait.spin()) {
                            state = @atomicLoad(usize, &self.state, .Monotonic);
                            continue;
                        }

                        waiter.prev = null;
                        waiter.next = head;
                        waiter.tail = if (head == null) &waiter else null;

                        if (!has_event) {
                            has_event = true;
                            waiter.event.init();
                        }

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
                        spin_wait.reset();
                        state = @atomicLoad(usize, &self.state, .Monotonic);
                    }
                }

                fn unlock(self: *WordLock) void {
                    const state = @atomicRmw(usize, &self.state, .Sub, LOCKED, .Release);
                    if ((state & QLOCKED != 0) or (state & WAITING == 0))
                        return;
                    self.unlockSlow();
                }

                fn unlockSlow(self: *WordLock) void {
                    @setCold(true);

                    var state = @atomicLoad(usize, &self.state, .Monotonic);
                    while (true) {
                        if ((state & QLOCKED != 0) or (state & WAITING == 0))
                            return;
                        state = @cmpxchgWeak(
                            usize,
                            &self.state,
                            state,
                            state | QLOCKED,
                            .Acquire,
                            .Monotonic,
                        ) orelse break;
                    }

                    outer: while (true) {
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
                                state & ~@as(usize, QLOCKED),
                                .Release,
                                .Monotonic,
                            ) orelse return;
                            @fence(.Acquire);
                            continue;
                        }

                        if (tail.prev) |new_tail| {
                            head.tail = new_tail;
                            _ = @atomicRmw(usize, &self.state, .And, ~@as(usize, QLOCKED), .Release);
                        } else {
                            while (true) {
                                state = @cmpxchgWeak(
                                    usize,
                                    &self.state,
                                    state,
                                    state & LOCKED,
                                    .Release,
                                    .Monotonic,
                                ) orelse break;
                                if (state & WAITING != 0) {
                                    @fence(.Acquire);
                                    continue :outer;
                                }
                            }
                        }

                        tail.event.notify();
                        break;
                    }
                }
            };
};
