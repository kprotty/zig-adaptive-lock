const std = @import("std");

pub const Mutex = struct {
    pub const NAME = "custom";

    const UNLOCKED = 0;
    const LOCKED = 1 << 0;
    const WAKING = 1 << 1;
    const WAITING = ~@as(usize, (1 << 2) - 1);

    const Waiter = struct {
        prev: ?*Waiter align((~WAITING) + 1),
        next: ?*Waiter,
        tail: ?*Waiter,
        event: std.ResetEvent, 
    };

    state: usize = UNLOCKED,

    pub fn init(self: *Mutex) void {
        self.* = Mutex{};
    }

    pub fn deinit(self: *Mutex) void {
        self.* = undefined;
    }

    pub fn acquire(self: *Mutex) void {
        const acquired = switch (std.builtin.arch) {
            // on x86, unlike cmpxchg, bts doesnt require a register setup for the value
            // which results in a slightly smaller hit on the i-cache. 
            .i386, .x86_64 => asm volatile(
                "lock btsl $0, %[ptr]"
                : [ret] "={@ccc}" (-> u8),
                : [ptr] "*m" (&self.state)
                : "cc", "memory"
            ) == 0,
            else => @cmpxchgWeak(
                usize,
                &self.state,
                UNLOCKED,
                LOCKED,
                .Acquire,
                .Monotonic,
            ) == null,
        };

        if (!acquired)
            self.acquireSlow();
    }

    fn acquireSlow(self: *Mutex) void {
        @setCold(true);

        var spin: u4 = 0;
        var is_waking = false;
        var has_event = false;
        var waiter: Waiter = undefined;
        var state = @atomicLoad(usize, &self.state, .Monotonic);

        while (true) {
            var new_state = state;
            const head = @intToPtr(?*Waiter, state & WAITING);

            if (state & LOCKED == 0) {
                new_state |= LOCKED;

            } else if (head == null and spin <= 10) {
                if (spin <= 3) {
                    std.SpinLock.loopHint(@as(usize, 1) << spin);
                } else if (std.builtin.os.tag == .windows) {
                    std.os.windows.kernel32.Sleep(1);
                } else {
                    std.os.sched_yield() catch unreachable;
                }
                spin += 1;
                state = @atomicLoad(usize, &self.state, .Monotonic);
                continue;

            } else {
                waiter.prev = null;
                waiter.next = head;
                waiter.tail = if (head == null) &waiter else null;
                new_state = (new_state & ~WAITING) | @ptrToInt(&waiter);

                if (!has_event) {
                    has_event = true;
                    waiter.event = std.ResetEvent.init(); 
                }
            }

            if (is_waking)
                new_state &= ~@as(usize, WAKING);

            

            if (@cmpxchgWeak(
                usize,
                &self.state,
                state,
                new_state,
                .AcqRel,
                .Monotonic,
            )) |updated_state| {
                state = updated_state;
                continue;
            }

            if (state & LOCKED == 0)
                break;

            waiter.event.wait();
            waiter.event.reset();

            spin = 0;
            is_waking = true;
            state = @atomicLoad(usize, &self.state, .Monotonic);
        }

        if (has_event)
            waiter.event.deinit();
    }

    pub fn release(self: *Mutex) void {
        const state = @atomicRmw(usize, &self.state, .Sub, LOCKED, .Release);

        if ((state & WAITING != 0) and (state & WAKING == 0))
            self.releaseSlow();
    }

    fn releaseSlow(self: *Mutex) void {
        @setCold(true);

        var state = @atomicLoad(usize, &self.state, .Monotonic);
        while (true) {
            if ((state & WAITING == 0) or (state & (LOCKED | WAKING) != 0))
                return;
            state = @cmpxchgWeak(
                usize,
                &self.state,
                state,
                state | WAKING,
                .Acquire,
                .Monotonic,
            ) orelse break;
        }

        while (true) {
            const head = @intToPtr(*Waiter, state & WAITING);
            const tail = head.tail orelse blk: {
                var current = head;
                while (true) {
                    const next = current.next.?;
                    next.prev = current;
                    current = next;
                    if (current.tail) |tail| {
                        head.tail = tail;
                        break :blk tail;
                    }
                }
            };

            if (state & LOCKED != 0) {
                state = @cmpxchgWeak(
                    usize,
                    &self.state,
                    state,
                    state & ~@as(usize, WAKING),
                    .AcqRel,
                    .Acquire,
                ) orelse return;
                continue;
            }

            if (tail.prev) |new_tail| {
                head.tail = new_tail;
                @fence(.Release);

            } else if (@cmpxchgWeak(
                usize,
                &self.state,
                state,
                state & WAKING,
                .AcqRel,
                .Acquire,
            )) |updated_state| {
                state = updated_state;
                continue;
            }

            tail.event.set();
            return;
        }
    }
};