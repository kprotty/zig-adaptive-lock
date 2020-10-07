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
    pub const name = "ticket_lock";

    ticket: u16 = 0,
    owner: u16 = 0,

    pub fn acquire(self: *Lock) void {
        var spin: std.math.Log2Int(usize) = 0;
        const ticket = @atomicRmw(u16, &self.ticket, .Add, 1, .Monotonic);

        while (true) {
            if (@atomicLoad(u16, &self.owner, .Acquire) == ticket)
                return;

            if (spin < 5) {
                utils.yieldCpu(@as(usize, 1) << spin);
                spin += 1;
            } else {
                utils.yieldThread(1);
            }
        }
    }

    pub fn release(self: *Lock) void {
        @atomicStore(u16, &self.owner, self.owner +% 1, .Release);
    }
};