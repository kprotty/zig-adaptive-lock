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
const Atomic = std.atomic.Atomic;
const Futex = std.Thread.Futex;

pub const Lock = extern struct {
    pub const name = "mcs_lock";

    tail: Atomic(?*Waiter) = Atomic(?*Waiter).init(null),

    const Waiter = struct {
        next: Atomic(usize),
        futex: Atomic(u32),
    };

    pub fn init(self: *Lock) void {
        self.* = Lock{};
    }

    pub fn deinit(self: *Lock) void {
        self.* = undefined;
    }

    threadlocal var waiter: Waiter = undefined;

    pub fn acquire(self: *Lock) void {
        waiter.next.storeUnchecked(0);
        const prev = self.tail.swap(&waiter, .AcqRel) orelse return;
        acquireSlow(prev);
    }

    fn acquireSlow(noalias prev: *Waiter) void {
        @setCold(true);

        waiter.futex = Atomic(u32).init(0);
        prev.next.store(@ptrToInt(&waiter), .Release);

        var spin = utils.SpinWait{};
        while (waiter.futex.load(.Acquire) == 0) {
            if (!spin.yield()) utils.yieldThread(1);
        }
    }

    pub fn release(self: *Lock) void {
        _ = self.tail.compareAndSwap(&waiter, null, .Release, .Monotonic) orelse return;
        releaseSlow();
    }

    fn releaseSlow() void {
        @setCold(true);
        
        var spin = utils.SpinWait{};
        while (true) : ({
            if (!spin.yield()) utils.yieldThread(1);
        }) {
            const next = @intToPtr(?*Waiter, waiter.next.load(.Acquire)) orelse continue;
            next.futex.store(1, .Release);
            return;
        }
    }
};