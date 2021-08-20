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

pub const Lock = extern struct {
    pub const name = "ticket_lock";

    ticket: Atomic(u16) = Atomic(u16).init(0),
    owner: Atomic(u16) = Atomic(u16).init(0),

    pub fn init(self: *Lock) void {
        self.* = Lock{};
    }

    pub fn deinit(self: *Lock) void {
        self.* = undefined;
    }

    pub fn acquire(self: *Lock) void {
        var spin = utils.SpinWait{};
        const ticket = self.ticket.fetchAdd(1, .Monotonic);

        while (self.owner.load(.Acquire) != ticket) {
            if (!spin.yield()) {
                utils.yieldThread(1);
            }
        }
    }

    pub fn release(self: *Lock) void {
        const new_owner = self.owner.loadUnchecked() +% 1;
        self.owner.store(new_owner, .Release);
    }
};