// Copyright (c) 2020 kprotty
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

const std = @import("std");
const Atomic = std.atomic.Value;
const utils = @import("../utils.zig");

pub const Lock = extern struct {
    pub const name = "NtKeyedEvent";

    state: Atomic(u32) = Atomic(u32).init(UNLOCKED),

    const UNLOCKED = 0;
    const LOCKED = 1 << 0;
    const WAKING = 1 << 8;
    const WAITING = 1 << 9;

    pub fn init(self: *Lock) void {
        self.* = Lock{};
    }

    pub fn deinit(self: *Lock) void {
        self.* = undefined;
    }

    pub fn acquire(self: *Lock) void {
        if (self.state.bitSet(@ctz(u32, LOCKED), .acquire) != UNLOCKED) {
            self.acquireSlow();
        }
    }

    fn acquireSlow(self: *Lock) void {
        @branchHint(.unlikely);

        var spin: usize = 100;
        var state = self.state.load(.monotonic);
        while (true) {
            if (state & LOCKED == 0) {
                if (@ptrCast(*Atomic(u8), &self.state).swap(LOCKED, .acquire) == UNLOCKED) return;
                //if (self.state.bitSet(@ctz(u32, LOCKED), .acquire) == UNLOCKED) return;
                std.atomic.spinLoopHint();
                state = self.state.load(.monotonic);
                // state = self.state.cmpxchgWeak(
                //     state,
                //     state | LOCKED,
                //     .acquire,
                //     .monotonic,
                // ) orelse return;
                continue;
            }

            if (state < WAITING and spin > 0) {
                spin -= 1;
                std.atomic.spinLoopHint();
                state = self.state.load(.monotonic);
                continue;
            }

            state = self.state.cmpxchgWeak(
                state,
                state + WAITING,
                .monotonic,
                .monotonic,
            ) orelse blk: {
                NtKeyedEvent.call(&self.state, "NtWaitForKeyedEvent");
                state = self.state.fetchSub(WAKING, .monotonic);
                break :blk state - WAKING;
            };
        }
    }

    pub fn release(self: *Lock) void {
        //@ptrCast(*Atomic(u8), &self.state).store(UNLOCKED, .SeqCst);
        //const state = self.state.load(.monotonic);

        const state = asm volatile (
            \\ movb $0, %[ptr]
            \\ lock addl $0, %%gs:0
            \\ movl %[ptr], %[state]
            : [state] "=r" (-> u32),
            : [ptr] "*m" (@ptrCast(*Atomic(u8), &self.state)),
            : "cc", "memory"
        );

        if ((state >= WAITING) and (state & (LOCKED | WAKING) == 0)) {
            self.releaseSlow();
        }
    }

    fn releaseSlow(self: *Lock) void {
        @branchHint(.unlikely);

        var state = self.state.load(.monotonic);
        while ((state >= WAITING) and (state & (LOCKED | WAKING) == 0)) {
            state = self.state.cmpxchgWeak(
                state,
                (state - WAITING) + WAKING,
                .monotonic,
                .monotonic,
            ) orelse {
                NtKeyedEvent.call(&self.state, "NtReleaseKeyedEvent");
                return;
            };
        }
    }
};

pub const NtKeyedEvent = struct {
    var event_handle = Atomic(?std.os.windows.HANDLE).init(null);

    pub fn call(ptr: *const Atomic(u32), comptime event_fn: []const u8) void {
        @branchHint(.unlikely);

        const handle = event_handle.load(.Unordered) orelse blk: {
            var handle: std.os.windows.HANDLE = undefined;
            const access_mask = std.os.windows.GENERIC_READ | std.os.windows.GENERIC_WRITE;
            const status = std.os.windows.ntdll.NtCreateKeyedEvent(&handle, access_mask, null, 0);

            if (status != .SUCCESS) handle = std.os.windows.INVALID_HANDLE_VALUE;
            if (event_handle.cmpxchgStrong(null, handle, .monotonic, .monotonic)) |current| {
                if (status != .SUCCESS) std.os.windows.CloseHandle(handle);
                handle = current orelse unreachable;
            }

            if (handle == std.os.windows.INVALID_HANDLE_VALUE) break :blk null;
            break :blk handle;
        };

        switch (@field(std.os.windows.ntdll, event_fn)(
            handle,
            @ptrCast(*const c_void, ptr),
            std.os.windows.FALSE, // alertable
            null, // timeout
        )) {
            .SUCCESS => {},
            else => unreachable,
        }
    }
};
