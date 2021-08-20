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
    pub const name = "futex_lock";

    state: Atomic(u32) = Atomic(u32).init(UNLOCKED),

    const UNLOCKED = 0;
    const LOCKED = 0b01;
    const CONTENDED = 0b11;

    pub fn init(self: *Lock) void {
        self.* = Lock{};
    }

    pub fn deinit(self: *Lock) void {
        self.* = undefined;
    }

    pub fn acquire(self: *Lock) void {
        if (!self.acquireFast()) {
            self.acquireSlow();
        }
    }

    inline fn acquireFast(self: *Lock) bool {
        if (utils.is_x86) {
            return self.state.bitSet(@ctz(u32, LOCKED), .Acquire) == UNLOCKED;
        }

        return self.state.tryCompareAndSwap(
            UNLOCKED,
            LOCKED,
            .Acquire,
            .Monotonic,
        ) == null;
    }

    fn acquireSlow(self: *Lock) void {
        @setCold(true);

        var spin: u8 = 10;
        while (spin > 0) : (spin -= 1) {
            std.atomic.spinLoopHint();

            switch (self.state.load(.Monotonic)) {
                UNLOCKED => _ = self.state.compareAndSwap(
                    UNLOCKED,
                    LOCKED,
                    .Acquire,
                    .Monotonic,
                ) orelse return,
                LOCKED => continue,
                CONTENDED => break,
                else => unreachable,
            }
        }

        while (true) : (Futex.wait(&self.state, CONTENDED, null) catch unreachable) {
            var state = self.state.load(.Monotonic);
            if (state == CONTENDED) {
                continue;
            }

            if (utils.is_x86) {
                switch (self.state.swap(CONTENDED, .Acquire)) {
                    UNLOCKED => return,
                    LOCKED, CONTENDED => continue,
                    else => unreachable,
                }
            }

            while (state != CONTENDED) {
                state = switch (state) {
                    UNLOCKED => self.state.tryCompareAndSwap(state, CONTENDED, .Acquire, .Monotonic) orelse return,
                    LOCKED => self.state.tryCompareAndSwap(state, CONTENDED, .Acquire, .Monotonic) orelse break,
                    else => unreachable,
                };
            }
        }
    }

    pub fn release(self: *Lock) void {
        switch (self.state.swap(UNLOCKED, .Release)) {
            UNLOCKED => unreachable,
            LOCKED => {},
            CONTENDED => self.releaseSlow(),
            else => unreachable,
        }
    }
    
    fn releaseSlow(self: *Lock) void {
        @setCold(true);

        Futex.wake(&self.state, 1);
    }
};