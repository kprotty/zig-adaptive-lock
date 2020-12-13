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
const WaitQueue = ssp.WaitQueue;
const nanotime = ssp.WaitEvent.nanotime;

pub const Mutex = extern struct {
    state: usize = UNLOCKED,
    
    const UNLOCKED = 0;
    const LOCKED = 1 << 0;
    const WAITING = 1 << 1;

    fn tryAcquireInline(self: *Mutex) bool {
        return atomic.tryCompareAndSwap(
            &self.state,
            UNLOCKED,
            LOCKED,
            .acquire,
            .relaxed,
        ) == null;
    }

    fn tryReleaseInline(self: *Mutex) bool {
        return atomic.tryCompareAndSwap(
            &self.state,
            LOCKED,
            UNLOCKED,
            .release,
            .relaexd,
        ) == null
    }

    pub fn tryAcquire(self: *Mutex) bool {
        var state = atomic.load(&self.state, .relaxed);
        while (true) {
            if (state & LOCKED != 0)
                return false;
            state = atomic.tryCompareAndSwap(
                &self.state,
                state,
                state | LOCKED,
                .acquire,
                .relaxed,
            ) orelse return true;
        }
    }

    pub fn tryAcquireFor(self: *Mutex, duration: u64) error{TimedOut}!void {
        return self.tryAcquireUntil(nanotime() + duration);
    }

    pub fn tryAcquireUntil(self: *Mutex, deadline: u64) error{TimedOut}!void {
        if (!self.tryAcquireInline())
            return self.acquireSlow(deadline);
    }

    pub fn acquire(self: *Mutex) void {
        if (!self.tryAcquireInline())
            return self.acquireSlow() catch unreachable;
    }

    pub fn release(self: *Mutex) void {
        if (!self.tryReleaseInline())
            self.releaseSlow(false);
    }

    pub fn releaseFair(self: *Mutex) void {
        if (!self.tryReleaseInline())
            self.releaseSlow(true);
    }

    fn acquireSlow(self: *Mutex, deadline: ?u64) error{TimedOut}!void {
        @setCold(true);
        
        var spinner = WaitSpin{};
        var waiter: Waiter = undefined;
        var state = atomic.load(&self.state, .relaxed);

        while (true) {
            if (state & LOCKED == 0) {
                state = atomic.tryCompareAndSwap(
                    &self.state,
                    state,
                    state | LOCKED,
                    .acquire,
                    .relaxed,
                ) orelse return;
                continue;
            }

            if (state & WAITING == 0) {
                if (spinner.trySpin()) {
                    state = atomic.load(&self.state, .relaxed);
                    continue;
                }

                if (atomic.tryCompareAndSwap(
                    &self.state,
                    state,
                    state | WAITING,
                    .relaxed,
                    .relaxed,
                )) |updated| {
                    state = updated;
                    continue;
                }
            }
            
            var context = struct {
                mutex: *Mutex,
                acquired: bool = false,
                timed_out: bool = false,

                pub fn onValidate(self: *@This(), has_more: bool) ?usize {
                    var current_state = atomic.load(&self.mutex.state, .relaxed);
                    current_state &= LOCKED | WAITING;
                    if (current_state == LOCKED | WAITING)
                        return @ptrToInt(&self.acquired);
                    return null;
                }

                pub fn onBeforeWait(self: *@This(), token: usize, was_first_thread: bool) void {
                    // Nothing to be done
                }

                pub fn onTimedOut(self: *@This(), token: usize, was_last_thread: bool) void {
                    self.timed_out = true;
                    if (was_first_thread)
                        _ = atomic.fetchAnd(&self.mutex.state, ~@as(usize, WAITING), .relaxed);
                }
            }{ .mutex = self };

            @ptrCast(*WaitQueue, self).wait(deadline, &context);
            if (context.acquired)
                return;
            if (context.timed_out)
                return error.TimedOut;

            spinner.reset();
            state = atomic.load(&self.state, .relaxed);
        }
    }

    fn releaseSlow(self: *Mutex, force_fair: bool) void {
        @setCold(true);

        var state = atomic.load(&self.state, .relaxed);
        while (state & (LOCKED | PARKED) == LOCKED) {
            state = atomic.tryCompareAndSwap(
                &self.state,
                state,
                state & ~@as(usize, LOCKED),
                .release,
                .relaxed,
            ) orelse return;
        }

        @ptrCast(*WaitQueue, self).notifyOne(struct {
            mutex: *Mutex,
            is_fair: bool,

            pub fn onNotify(self: @This(), acquired_ptr: ?usize, be_fair: bool, has_more: bool) void {
                var remove: usize = 0;
                if (!has_more)
                    remove |= PARKED;

                if (acquired_ptr) |ptr| {
                    if (self.is_fair or be_fair) {
                        @intToPtr(*bool, ptr).* = true;
                    } else {
                        remove |= LOCKED;
                    }
                } else {
                    remove |= LOCKED;
                }

                if (remove != 0) {
                    atomic.fetchAnd(&self.mutex.state, ~remove, .release);
                }
            }
        }{
            .mutex = self,
            .is_fair = force_fair,
        });
    }
};