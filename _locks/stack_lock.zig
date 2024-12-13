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
const waiter_mask = ~@as(usize, locked);

const Waiter = struct {
    next: ?*Waiter,
    event: @import("../utils.zig").Event,
};

pub const Lock = extern struct {
    pub const name = "stack_lock";

    state: Atomic(usize) = Atomic(usize).init(0),

    pub fn init(self: *Lock) void {
        self.* = .{};
    }

    pub fn deinit(self: *Lock) void {
        self.* = undefined;
    }

    pub inline fn acquire(self: *Lock) void {
        const state = self.state.tryCompareAndSwap(unlocked, locked, .Acquire, .Monotonic) orelse return;
        self.acquireSlow(state);
    }

    noinline fn acquireSlow(self: *Lock, current_state: usize) void {
        var spin: usize = 0;
        var has_event = false;
        var waiter: Waiter = undefined;
        var state = current_state;

        while (true) {
            while (state & locked == 0) {
                state = self.state.tryCompareAndSwap(state, state | locked, .Acquire, .Monotonic) orelse {
                    if (has_event) waiter.event.deinit();
                    return;
                };
            }

            const head = @intToPtr(?*Waiter, state & waiter_mask);
            if (head == null and spin < 100) {
                spin += 1;
                std.atomic.spinLoopHint();
                state = self.state.load(.Monotonic);
                continue;
            }

            waiter.next = head;
            if (!has_event) {
                has_event = true;
                waiter.event = .{};
            }

            const new_state = (state & ~waiter_mask) | @ptrToInt(&waiter);
            state = self.state.tryCompareAndSwap(state, new_state, .Release, .Monotonic) orelse blk: {
                waiter.event.wait();
                waiter.event.reset();
                spin = 0;
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
            const head = @intToPtr(*Waiter, state & waiter_mask);
            
            std.atomic.fence(.Acquire);
            const new_state = @ptrToInt(head.next);

            state = self.state.tryCompareAndSwap(state, new_state, .Release, .Monotonic) orelse {
                return head.event.notify();
            };
        }
    }
};