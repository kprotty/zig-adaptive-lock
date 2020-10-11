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
    pub const name = "raw_futex";

    state: State = .unlocked,

    const State = extern enum(i32) {
        unlocked = 0,
        locked = 1,
    };

    pub fn init(self: *Lock) void {
        self.* = Lock{};
    }

    pub fn deinit(self: *Lock) void {
        self.* = undefined;
    }

    pub fn acquire(self: *Lock) void {
        while (true) {
            if (@atomicRmw(State, &self.state, .Xchg, .locked, .Acquire) == .unlocked)
                return;
            _ = std.os.linux.futex_wait(
                @ptrCast(*const i32, &self.state),
                std.os.linux.FUTEX_PRIVATE_FLAG | std.os.linux.FUTEX_WAIT,
                @enumToInt(State.locked),
                null,
            );
        }
    }

    pub fn release(self: *Lock) void {
        @atomicStore(State, &self.state, .unlocked, .Release);
        _ = std.os.linux.futex_wake(
            @ptrCast(*const i32, &self.state),
            std.os.linux.FUTEX_PRIVATE_FLAG | std.os.linux.FUTEX_WAKE,
            1,
        );
    }
};