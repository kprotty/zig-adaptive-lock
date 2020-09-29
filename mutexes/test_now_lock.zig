const std = @import("std");
const nanotime = @import("./nanotime.zig").nanotime;
const Parker = @import("../v2/parker.zig").OsParker;

pub const Mutex = struct {
    pub const NAME = "test_now_lock";

    const UNLOCKED = 0;
    const LOCKED = 1 << 0;
    const WAITING = ~@as(usize, LOCKED);

    const Waiter = struct {
        prev: ?*Waiter align((~WAITING) + 1),
        next: ?*Waiter,
        tail: ?*Waiter,
        parker: Parker,
        acquired: bool,
        started: u64,
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

        var waiter: Waiter = undefined;
        waiter.parker = Parker.init();
        defer waiter.parker.deinit();

        var spin: u4 = 0;
        var has_started = false;
        var state = @atomicLoad(usize, &self.state, .Monotonic);

        while (true) {
            var new_state = state;
            const head = @intToPtr(?*Waiter, state & WAITING);

            if (state & LOCKED == 0) {
                new_state |= LOCKED;

            } else if (head == null and spin <= 10) {
                std.SpinLock.loopHint(@as(usize, 1) << spin);
                spin += 1;
                state = @atomicLoad(usize, &self.state, .Monotonic);
                continue;

            } else {
                waiter.prev = null;
                waiter.next = head;
                waiter.tail = if (head == null) &waiter else null;
                new_state = (new_state & ~WAITING) | @ptrToInt(&waiter);

                waiter.parker.prepare();
                if (!has_started) {
                    has_started = true;
                    waiter.started = nanotime();
                }
            }

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

            waiter.parker.park();
            if (waiter.acquired)
                break;

            spin = 0;
            state = @atomicLoad(usize, &self.state, .Monotonic);
        }
    }

    pub fn release(self: *Mutex) void {
        if (@cmpxchgStrong(
            usize,
            &self.state,
            LOCKED,
            UNLOCKED,
            .Release,
            .Monotonic,
        ) != null) {
            self.releaseSlow();
        }
    }

    fn releaseSlow(self: *Mutex) void {
        @setCold(true);

        var release_at: ?u64 = null;
        var state = @atomicLoad(usize, &self.state, .Acquire);

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

            const is_fair = blk: {
                const released = release_at orelse r: {
                    const now = nanotime();
                    release_at = now;
                    break :r now;
                };

                var timeout = @as(u64, @ptrToInt(tail) >> 3);
                timeout %= 500 * std.time.ns_per_us;
                timeout += 500 * std.time.ns_per_us;
                break :blk (released > (tail.started + timeout));
            };

            if (tail.prev) |new_tail| {
                head.tail = new_tail;
                if (!is_fair) {
                    _ = @atomicRmw(usize, &self.state, .And, ~@as(usize, LOCKED), .Release);
                }

            } else if (@cmpxchgWeak(
                usize,
                &self.state,
                state,
                @as(usize, if (is_fair) LOCKED else UNLOCKED),
                .AcqRel,
                .Acquire,
            )) |updated_state| {
                state = updated_state;
                continue;
            }

            tail.acquired = is_fair;
            tail.parker.unpark();
            return;
        }
    }
};

