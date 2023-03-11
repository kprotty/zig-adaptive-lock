const std = @import("std");
const assert = std.debug.assert;
const Atomic = std.atomic.Atomic;

const Event = struct {
    state: Atomic(u32) = Atomic(u32).init(0),

    fn wait(event: *Event) void {
        for (0..32) |_| {
            if (event.state.load(.Acquire) == 2) return;
            std.atomic.spinLoopHint();
        }

        if (event.state.swap(1, .Acquire) == 0) {
            while (true) {
                std.Thread.Futex.wait(&event.state, 1);
                if (event.state.load(.Acquire) == 2) return;
            }
        }
    }

    fn set(event: *Event) void {
        if (event.state.swap(2, .Release) == 1) {
            std.Thread.Futex.wake(&event.state, 1);
        }
    }
};

const Backoff = struct {
    rng: u32 = 0,

    fn yield(backoff: *Backoff, seed: usize) void {
        var rng = backoff.rng;
        if (rng == 0) rng = @truncate(u32, seed);
        backoff.rng = (rng *% 1103515245) +% 12345;
        
        var spin = ((rng >> 24) & (128 - 1)) | (32 - 1);
        while (spin > 0) : (spin -= 1) std.atomic.spinLoopHint();
    }
};

pub const Lock = struct {
    state: Atomic(usize) = Atomic(usize).init(0),

    pub const name = "srwlock";

    pub fn init(self: *Lock) void {
        self.* = .{};
    }

    pub fn deinit(self: *Lock) void {
        self.* = undefined;
    }

    const locked: usize = 1 << 0;
    const qlocked: usize = 1 << 1;
    const qmask = ~(locked | qlocked);

    comptime { assert(@alignOf(Waiter) > ~qmask); }
    const Waiter = struct {
        tail: ?*Waiter,
        next: ?*Waiter,
        prev: ?*Waiter,
        event: Event,
    };

    pub fn acquire(self: *Lock) void {
        if (self.state.fetchOr(locked, .Acquire) & locked != 0) {
            self.acquireSlow();
        }
    }

    fn acquireSlow(self: *Lock) void {
        @setCold(true);

        var backoff = Backoff{};
        var waiter: Waiter = undefined;
        while (true) {
            waiter.prev = null;
            waiter.event = .{};

            while (true) {
                const state = self.state.load(.Monotonic);
                const rng_seed = state ^ @ptrToInt(&waiter);

                if (state & locked == 0) {
                    _ = self.state.tryCompareAndSwap(state, state | locked, .Acquire, .Monotonic) orelse return;
                    backoff.yield(rng_seed);
                    continue;
                }

                const head = @intToPtr(?*Waiter, state & qmask);
                waiter.next = head;

                const qacquire = head != null;
                waiter.tail = if (!qacquire) &waiter else null;
                
                const new_state = @ptrToInt(&waiter) | locked | (qlocked * @boolToInt(qacquire));
                if (self.state.tryCompareAndSwap(state, new_state, .Release, .Monotonic)) |_| {
                    backoff.yield(rng_seed);
                    continue;
                }

                if ((state | ~new_state) & qlocked == 0) self.fixup(new_state);
                break waiter.event.wait();
            }
        }
    }

    fn fixup(self: *Lock, current_state: usize) void {
        @setCold(true);

        var state = current_state;
        while (true) {
            assert(state & qlocked != 0);
            if (state & locked == 0) {
                return self.unpark(state);
            }

            const head = @intToPtr(*Waiter, state & qmask);
            _ = self.find_tail(head);
            state = self.state.tryCompareAndSwap(state, state - qlocked, .Release, .Monotonic) orelse return;
        }
    }

    fn find_tail(self: *Lock, head: *Waiter) *Waiter {
        self.state.fence(.Acquire);
        
        var waiter = head;
        while (true) {
            if (waiter.tail) |tail| {
                head.tail = tail;
                return tail;
            }

            const next = waiter.next orelse unreachable;
            assert(next.prev == null);
            next.prev = waiter;
            waiter = next;
        }
    }

    pub fn release(self: *Lock) void {
        const state = self.state.compareAndSwap(locked, 0, .Release, .Monotonic) orelse return;
        self.releaseSlow(state);
    }

    fn releaseSlow(self: *Lock, current_state: usize) void {
        @setCold(true);

        var state = current_state;
        while (true) {
            assert(state & locked != 0);
            const new_state = (state - locked) | qlocked;
            state = self.state.tryCompareAndSwap(state, new_state, .Release, .Monotonic) orelse {
                if ((state | ~new_state) & qlocked == 0) return self.unpark(new_state);
                return;
            };
        }
    }

    fn unpark(self: *Lock, current_state: usize) void {
        var state = current_state;
        while (true) {
            assert(state & qlocked != 0);
            if (state & locked != 0) {
                state = self.state.tryCompareAndSwap(state, state - qlocked, .Release, .Monotonic) orelse return;
                continue;
            }

            const head = @intToPtr(*Waiter, state & qmask);
            const tail = self.find_tail(head);

            if (tail.prev) |new_tail| {
                head.tail = new_tail;
                _ = self.state.fetchSub(qlocked, .Release);
            } else blk: {
                state = self.state.tryCompareAndSwap(state, 0, .Release, .Monotonic) orelse break :blk;
                continue;
            }

            return tail.event.set();
        }
    }
};