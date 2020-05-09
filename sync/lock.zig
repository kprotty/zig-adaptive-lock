const std = @import("std");

pub fn Lock(comptime AutoResetEvent: type) type {
    return struct {
        const Self = @This();
        const isX86 = std.builtin.arch == .i386 or .arch == .x86_64;

        const UNLOCKED = 0;
        const LOCKED = 1;
        const WAKING = 1 << 8;
        const WAITING = ~@as(usize, Waiter.ALIGN - 1);

        const Waiter = struct {
            const ALIGN = 1 << 9;
            prev: ?*Waiter,
            next: ?*Waiter,
            tail: ?*Waiter,
            unset_waking: bool,
            event: AutoResetEvent,
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

        pub fn tryAcquire(self: *Self) bool {
            if (isX86)
                return self.bitTestAndSet(0);

            var state: usize = UNLOCKED;
            while (state & LOCKED == 0)
                state = @cmpxchgWeak(
                    usize,
                    &self.state,
                    state,
                    state | LOCKED,
                    .Acquire,
                    .Monotonic,
                ) orelse return true;
            return false;
        }

        pub fn acquire(self: *Self) void {
            if (isX86) {
                if (!self.bitTestAndSet(0))
                    self.acquireSlow({});
            } else {
                const state = @cmpxchgWeak(
                    usize,
                    &self.state,
                    UNLOCKED,
                    LOCKED,
                    .Acquire,
                    .Monotonic,
                ) orelse return;
                self.acquireSlow(state);
            }
        }

        fn acquireSlow(self: *Self, new_state: var) void {
            @setCold(true);

            var spin: usize = 0;
            var waiter_init = false;
            var waiter: Waiter align(Waiter.ALIGN) = undefined;
            var state = switch (@TypeOf(new_state)) {
                void => @atomicLoad(usize, &self.state, .Monotonic),
                else => new_state,
            };

            while (true) {
                // Try to acquire the lock if its unlocked
                if (state & LOCKED == 0) {
                    if (isX86) {
                        if (self.bitTestAndSet(0))
                            break;
                        state = @atomicLoad(usize, &self.state, .Monotonic);
                    } else {
                        state = @cmpxchgWeak(
                            usize,
                            &self.state,
                            state,
                            state | LOCKED,
                            .Acquire,
                            .Monotonic,
                        ) orelse break;
                    }
                    continue;
                }

                const head = @intToPtr(?*Waiter, state & WAITING);
                if (@hasDecl(AutoResetEvent, "yield") and AutoResetEvent.yield(head != null, spin)) {
                    spin +%= 1;
                    state = @atomicLoad(usize, &self.state, .Monotonic);
                    continue;
                }

                waiter.prev = null;
                waiter.next = head;
                waiter.tail = if (head == null) &waiter else null;
                if (!waiter_init) {
                    waiter_init = true;
                    waiter.event.init();
                }

                if (@cmpxchgWeak(
                    usize,
                    &self.state,
                    state,
                    (state & ~WAITING) | @ptrToInt(&waiter),
                    .Release,
                    .Monotonic,
                )) |updated_state| {
                    state = updated_state;
                    continue;
                }
                
                waiter.event.wait();
                spin = 0;
                if (waiter.unset_waking) {
                    state = @atomicRmw(usize, &self.state, .Sub, WAKING, .Monotonic) - WAKING;
                } else {
                    state = @atomicLoad(usize, &self.state, .Monotonic);
                }
            }

            if (@hasDecl(AutoResetEvent, "deinit") and waiter_init)
                waiter.event.deinit();
        }

        pub fn release(self: *Self) void {
            @atomicStore(u8, @ptrCast(*u8, &self.state), UNLOCKED, .Release);

            const ordering = if (isX86) .Acquire else .Monotonic;
            const state = @atomicLoad(usize, &self.state, ordering);
            if ((state & WAITING != 0) and (state & (WAKING | LOCKED) == 0))
                self.releaseSlow(state);
        }

        fn releaseSlow(self: *Self, new_state: usize) void {
            @setCold(true);
            var state = new_state;

            if (isX86) {
                if (!self.bitTestAndSet(8))
                    return;
            } else {
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
            }

            dequeue: while (true) {
                const head = @intToPtr(*Waiter, state & WAITING);
                const tail = head.tail orelse blk: {
                    var current = head;
                    while (true) {
                        const next = current.next.?;
                        next.prev = current;
                        current = next;
                        if (current.tail) |t| {
                            head.tail = t;
                            break :blk t;
                        }
                    }
                };

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

                tail.unset_waking = false;
                if (tail.prev) |new_tail| {
                    head.tail = new_tail;
                    tail.unset_waking = true;
                    @fence(.Release);

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
                        if (state & WAITING != @ptrToInt(head))
                            continue :dequeue;
                    }
                }

                tail.event.set();
                return;
            }
        }
    };
}