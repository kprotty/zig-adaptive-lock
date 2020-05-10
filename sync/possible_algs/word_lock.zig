const std = @import("std");

pub fn Lock(comptime AutoResetEvent: type) type {
    return struct {
        const Self = @This();

        const UNLOCKED = 0;
        const LOCKED = 1 << 0;
        const WAKING = 1 << 8;
        const WAIT_ALIGN = 1 << 9;
        const WAITING = ~@as(usize, WAIT_ALIGN - 1);

        const Waiter = struct {
            prev: ?*Waiter,
            next: ?*Waiter,
            tail: ?*Waiter,
            event: AutoResetEvent,

            fn findTail(self: *Waiter) *Waiter {
                return self.tail orelse blk: {
                    var current = self;
                    while (true) {
                        const next = current.next.?;
                        next.prev = current;
                        current = next;
                        if (current.tail) |tail| {
                            self.tail = tail;
                            break :blk tail;
                        }
                    }
                };
            }
        };

        state: usize = UNLOCKED,

        pub fn init() Self {
            return Self{};
        }

        pub fn deinit(self: *Self) void {
            defer self.* = undefined;
            if (std.debug.runtime_safety) {
                const state = @atomicLoad(usize, &self.state, .Monotonic);
                if (state & WAITING != 0)
                    std.debug.panic("Lock.deinit() with existing waiters", .{});
            }
        }

        const isX86 = std.builtin.arch == .i386 or .arch == .x86_64;
        inline fn bitTestAndSet(self: *Self, comptime bit: u8) bool {
            comptime var bit_str = [1]u8{ '0' + bit };
            return asm volatile(
                "lock btsl $" ++ bit_str ++ ", %[state]\n" ++
                "setnc %[bit_is_now_set]"
                : [bit_is_now_set] "=r" (-> bool)
                : [state] "*m" (&self.state)
                : "cc", "memory"
            );
        }

        pub inline fn tryAcquire(self: *Self) bool {
            if (isX86)
                return self.bitTestAndSet(0);
            return @cmpxchgStrong(
                u8,
                @ptrCast(*u8, &self.state),
                UNLOCKED,
                LOCKED,
                .Acquire,
                .Monotonic,
            ) == null;
        }

        pub inline fn acquire(self: *Self) void {
            if (!self.tryAcquire())
                self.acquireSlow();
        }

        fn acquireSlow(self: *Self) void {
            @setCold(true);

            var has_event = false;
            var spin_iter: usize = 0;
            var waiter align(WAIT_ALIGN) = @as(Waiter, undefined);
            var state = @atomicLoad(usize, &self.state, .Monotonic);

            while (true) {
                if (state & LOCKED == 0) {
                    if (self.tryAcquire()) {
                        if (has_event)
                            waiter.event.deinit();
                        return;
                    }
                    _ = AutoResetEvent.yield(false, 0);
                    state = @atomicLoad(usize, &self.state, .Monotonic);
                    continue;
                }

                const head = @intToPtr(?*Waiter, state & WAITING);
                if (AutoResetEvent.yield(head != null, spin_iter)) {
                    spin_iter +%= 1;
                    state = @atomicLoad(usize, &self.state, .Monotonic);
                    continue;
                }

                waiter.prev = null;
                waiter.next = head;
                waiter.tail = if (head == null) &waiter else null;
                if (!has_event) {
                    has_event = true;
                    waiter.event.init();
                }

                if (@cmpxchgWeak(
                    usize,
                    &self.state,
                    state,
                    (state & ~WAITING) | @ptrToInt(&waiter),
                    .Release,
                    .Monotonic,
                )) |new_state| {
                    state = new_state;
                    continue;
                }

                waiter.event.wait();
                spin_iter = 0;
                state = @atomicLoad(usize, &self.state, .Monotonic);
            }
        }

        pub fn release(self: *Self) void {
            @atomicStore(
                u8,
                @ptrCast(*u8, &self.state),
                UNLOCKED,
                .Release,
            );

            const state = @atomicLoad(usize, &self.state, .Monotonic);
            if ((state & WAITING != 0) and (state & (WAKING | LOCKED) == 0))
                self.releaseSlow(state);
        }

        fn releaseSlow(self: *Self, new_state: usize) void {
            @setCold(true);
            
            var state = new_state;
            while (true) {
                if ((state & WAITING == 0) or (state & (WAKING | LOCKED) != 0))
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

            dequeue: while (true) {
                const head = @intToPtr(*Waiter, state & WAITING);
                const tail = head.findTail();

                if (state & LOCKED != 0) {
                    state = @cmpxchgWeak(
                        usize,
                        &self.state,
                        state,
                        state & ~@as(usize, WAKING),
                        .Release,
                        .Acquire,
                    ) orelse return;
                    continue;
                }

                if (tail.prev) |new_tail| {
                    head.tail = new_tail;
                    _ = @atomicRmw(usize, &self.state, .And, ~@as(usize, WAKING), .Release);
                } else {
                    while (true) {
                        state = @cmpxchgWeak(
                            usize,
                            &self.state,
                            state,
                            state & LOCKED,
                            .Release,
                            .Acquire,
                        ) orelse break;
                        if ((state & WAITING) != @ptrToInt(head))
                            continue :dequeue;
                    }
                }

                tail.event.set();
                return;
            }
        }
    };
}