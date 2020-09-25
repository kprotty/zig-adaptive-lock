const std = @import("std");

pub const Mutex = struct {
    pub const NAME = "test_new_lock";

    const UNLOCKED = 0;
    const LOCKED = 1 << 0;
    const WAITING = ~@as(usize, LOCKED);

    const Waiter = struct {
        prev: ?*Waiter align((~WAITING) + 1),
        next: ?*Waiter,
        tail: ?*Waiter,
        event: std.ResetEvent,
        acquired: bool,
        force_fair_at: u64,
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
        var has_event = false;
        var waiter: Waiter = undefined;
        var state = @atomicLoad(usize, &self.state, .Monotonic);

        while (true) {
            var new_state = state;
            const head = @intToPtr(?*Waiter, state & WAITING);

            if (state & LOCKED == 0) {
                new_state |= LOCKED;

            } else if (spin <= 5) {
                if (spin < 4) {
                    std.SpinLock.loopHint(@as(usize, 2) << spin);
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
                    waiter.force_fair_at = Time.nanotime();
                    
                    var timeout = @as(u64, @ptrToInt(head orelse &waiter));
                    timeout = (13 *% timeout) ^ (timeout >> 15);
                    timeout %= 500 * std.time.ns_per_us;
                    timeout += 500 * std.time.ns_per_us;
                    waiter.force_fair_at += timeout;
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

            waiter.event.wait();
            @fence(.Acquire);
            if (waiter.acquired) {
                break;
            } else {
                waiter.event.reset();
            }

            spin = 0;
            state = @atomicLoad(usize, &self.state, .Monotonic);
        }

        if (has_event)
            waiter.event.deinit();
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

        var is_fair: ?bool = null;
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

            const be_fair = is_fair orelse blk: {
                const be_fair = Time.nanotime() >= tail.force_fair_at;
                is_fair = be_fair;
                break :blk be_fair;
            };

            if (tail.prev) |new_tail| {
                head.tail = new_tail;
                if (!be_fair) {
                    _ = @atomicRmw(usize, &self.state, .And, ~@as(usize, LOCKED), .Release);
                }

            } else if (@cmpxchgWeak(
                usize,
                &self.state,
                state,
                @as(usize, if (be_fair) LOCKED else UNLOCKED),
                .AcqRel,
                .Acquire,
            )) |updated_state| {
                state = updated_state;
                continue;
            }

            tail.acquired = be_fair;
            @fence(.Release);
            tail.event.set();
            return;
        }
    }
};

const Time = struct {
    fn nanotime() u64 {
        if (@sizeOf(usize) < @sizeOf(u64))
            return nanotime32();
        return nanotime64();
    }

    var last_time: u64 = 0;
    var last_lock = std.Mutex{};

    fn nanotime32() u64 {
        const now = Os.nanotime();
        if (Os.is_monotonic)
            return now;

        const held = last_lock.acquire();
        defer held.release();

        if (last_time >= now) {
            return last_time;
        } else {
            last_time = now;
            return now;
        }
    }

    fn nanotime64() u64 {
        const now = Os.nanotime();
        if (Os.is_monotonic)
            return now;

        var last = @atomicLoad(u64, &last_time, .Monotonic);
        while (true) {
            if (last >= now)
                return now;
            last = @cmpxchgWeak(
                u64,
                &last_time,
                last,
                now,
                .Monotonic,
                .Monotonic,
            ) orelse return now;
        }
    }

    const Os = 
        if (std.builtin.os.tag == .windows)
            struct {
                pub const is_monotonic = false;

                var freq: u64 = undefined;
                var freq_state: usize = 0;

                fn getFreq() u64 {
                    if (@atomicLoad(usize, &freq_state, .Acquire) == 2)
                        return freq;
                    return getFreqSlow();
                }

                fn getFreqSlow() u64 {
                    const f = std.os.windows.QueryPerformanceFrequency();
                    if (@cmpxchgStrong(usize, &freq_state, 0, 1, .Acquire, .Monotonic) == null) {
                        freq = f;
                        @atomicStore(usize, &freq_state, 2, .Release);
                    }
                    return f;
                }

                fn nanotime() u64 {
                    const c = std.os.windows.QueryPerformanceCounter();
                    return (c *% std.time.ns_per_s) / getFreq();
                }
            }
        else if (std.builtin.os.tag == .linux or std.builtin.link_libc)
            struct {
                pub const is_monotonic = !(std.builtin.os.tag == .linux and (
                    std.builtin.arch == .arm or
                    .arch == .aarch64 or
                    .arch == .s390x
                ));

                fn nanotime() u64 {
                    var ts: std.os.timespec = undefined;
                    std.os.clock_gettime(std.os.CLOCK_MONOTONIC, &ts) catch unreachable;
                    return @intCast(u64, ts.tv_sec) * std.time.ns_per_s + @intCast(u64, ts.tv_nsec);
                }
            }
        else if (std.Target.current.isDarwin())
            struct {
                pub const is_monotonic = true;

                var freq: std.os.darwin.mach_timebase_info_data = undefined;
                var freq_state: usize = 0;

                fn getFreq() std.os.darwin.mach_timebase_info_data {
                    if (@atomicLoad(usize, &freq_state, .Acquire) == 2)
                        return freq;
                    return getFreqSlow();
                }

                fn getFreqSlow() std.os.darwin.mach_timebase_info_data {
                    var f: std.os.darwin.mach_timebase_info_data = undefined;
                    std.os.darwin.mach_timebase_info(&f);
                    if (@cmpxchgStrong(usize, &freq_state, 0, 1, .Acquire, .Monotonic) == null) {
                        freq = f;
                        @atomicStore(usize, &freq_state, 2, .Release);
                    }
                    return f;
                }

                fn nanotime() u64 {
                    const f = getFreq();
                    const c = std.os.darwin.mach_absolute_time();
                    return (c *% f.numer) / f.denom;
                }
            }
        
        else 
            @compileError("timers not supported");
};
