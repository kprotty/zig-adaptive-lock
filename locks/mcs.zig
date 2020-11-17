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
const sync = @import("../sync.zig");
const spinLoopHint = sync.spinLoopHint;

pub const Lock = extern struct {
    pub const name = "mcs_lock";

    tail: *Waiter,

    const Waiter = struct {
        next: ?*Waiter,
        notified: bool,
    };

    pub fn init(self: *Lock) void {
        self.tail = null;
    }

    pub fn deinit(self: *Lock) void {
        self.* = undefined;
    }

    pub fn withLock(self: *Lock, context: anytype) void {
        var waiter: Waiter = undefined;
        self.acquire(&waiter);
        context.run();
        self.release(&waiter);
    }

    fn acquire(noalias self: *Lock, noalias waiter: *Waiter) void {
        waiter.next = null;
        if (@atomicRmw(?*Waiter, &self.tail, .Xchg, &waiter, .AcqRel)) |prev|
            acquireSlow(prev, waiter);
    }

    fn acquireSlow(noalias prev: *Waiter, noalias waiter: *Waiter) void {
        @setCold(true);

        waiter.notified = false;
        @atomicStore(?*Waiter, &prev.next, waiter, .Release);

        while (!@atomicLoad(bool, &waiter.notified, .Acquire)) {
            spinLoopHint();
        }
    }

    fn release(noalias self: *Lock, noalias waiter: *Waiter) void {
        if (@cmpxchgStrong(
            ?*Waiter,
            &self.tail,
            waiter,
            null,
            .Release,
            .Monotonic,
        )) |_failed| {
            releaseSlow(waiter);
        }
    }

    fn releaseSlow(noalias waiter: *Waiter) void {
        @setCold(true);

        while (true) {
            const next = @atomicLoad(?*Waiter, &waiter.next, .Acquire) orelse {
                spinLoopHint();
                continue;
            };

            @atomicStore(bool, &next.notified, true, .Release);
            return;
        }
    }
};
