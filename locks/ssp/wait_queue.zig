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

const ssp = @import("./ssp.zig");
const atomic = ssp.atomic;
const WaitSpin = ssp.WaitSpin;
const WaitEvent = ssp.WaitEvent;

pub const WaitQueue = extern struct {
    state: usize,

    const LOCKED = 1 << 2;
    const WAITING = 1 << 3;
    const WAITER = ~@as(usize, (1 << 4) - 1);

    const Waiter = struct {
        prev: ?*Waiter align (~WAITER + 1),
        next: ?*Waiter,
        head: ?*Waiter,
        tail: ?*Waiter,
        event: WaitEvent,
        token: usize,
        timeout: u64,
        prng: u16,
    };

    pub fn wait(ptr: *usize, deadline: ?u64, context: anytype) void {
        var list = self.acquire();

        const token = context.onValidate(!list.isEmpty()) orelse {
            self.release(list);
            return;
        };

        var waiter: Waiter = undefined;
        waiter.token = token;
        list.insert(&waiter);

        waiter.event = WaitEvent{};
        waiter.event.prepare();
        context.onBeforeWait(waiter.prev == null);
        self.release(list);

        waiter.event.wait(deadline) catch {
            list = self.acquire();

            if (list.tryRemove(&waiter)) {
                context.onTimedOut(list.isEmpty());
                self.release(list);
                return;
            }

            self.release(list);
            waiter.event.wait(null) catch unreachable;
            return;
        };
    }

    pub fn notifyOne(ptr: *usize, context: anytype) void {
        var list = self.acquire();



        var be_fair = false;
        var has_more = false;
    }

    pub fn notifyAll(ptr: *usize, context: anytype) void {

    }

    const List = struct {
        head: ?*Waiter,
        prng: u16,
        timeout: u64,

        fn insert(self: *List, waiter: *Waiter) void {
            waiter.next = null;
            waiter.tail = waiter;

            const head = self.head orelse {
                const tail = head.tail orelse unreachable;
                tail.next = &waiter;
                waiter.prev = tail;
                head.tail = &waiter;
                return;
            };

            self.head = &waiter;
            waiter.prev = null;
            waiter.prng = self.prng;
            waiter.timeout = self.timeout;
        }

        const Iter = 
    };

    fn acquire(self: *WaitQueue) List {

    }

    

    fn release(self: *WaitQueue, list: List) void {

    }
};