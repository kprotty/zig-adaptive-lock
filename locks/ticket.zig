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
const sync = @import("../sync.zig");
const spinLoopHint = sync.spinLoopHint;

pub const Lock = extern struct {
    pub const name = "ticket_lock";

    ticket: u16,
    owner: u16,

    pub fn init(self: *Lock) void {
        self.ticket = 0;
        self.owner = 0;
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
        const ticket = @atomicRmw(u16, &self.ticket, .Add, 1, .monotonic);
        while (true) {
            const owner = @atomicLoad(u16, &self.owner, .acquire);
            if (owner == ticket)
                return;
            spinLoopHint();
        }
    }

    fn release(self: *Lock) void {
        const owner = self.owner;
        @atomicStore(u16, &self.owner, owner +% 1, .release);
    }
};
