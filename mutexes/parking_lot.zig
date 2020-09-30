pub const Mutex = struct {
    pub const NAME = "parking_lot";

    const UNLOCKED = 0;
    const LOCKED = 1;
    const PARKED = 2;

    state: u8 align(128) = UNLOCKED,
    bucket: Bucket align(128) = Bucket{},

    const std = @import("std");
    const nanotime = @import("./nanotime.zig").nanotime;

    const Parker = switch (std.builtin.os.tag) {
        .windows, .linux => @import("../v2/parker.zig").OsParker,
        else => struct {
            event: std.ResetEvent,

            fn init() Parker {
                return Parker{.event = std.ResetEvent.init()};
            }
            
            fn deinit(self: *Parker) void {
                self.event.deinit();
            }

            fn prepare(self: *Parker) void {
                self.event.reset();
            }

            fn park(self: *Parker) void {
                self.event.wait();
            }

            fn unpark(self: *Parker) void {
                self.event.set();
            }
        },
    };

    pub fn init(self: *Mutex) void {
        self.* = Mutex{};
        self.bucket.timeout = nanotime();
        self.bucket.seed = @truncate(u32, @ptrToInt(self) >> 16);
    }

    pub fn deinit(self: *Mutex) void {
        self.* = undefined;
    }

    pub fn acquire(self: *Mutex) void {
        if (@cmpxchgWeak(
            u8,
            &self.state,
            UNLOCKED,
            LOCKED,
            .Acquire,
            .Monotonic,
        )) |_| {
            self.acquireSlow();
        }
    }

    fn acquireSlow(self: *Mutex) void {
        @setCold(true);

        var spin_wait = SpinWait{};
        var state = @atomicLoad(u8, &self.state, .Monotonic);

        while (true) {
            if (state & LOCKED == 0) {
                state = @cmpxchgWeak(
                    u8,
                    &self.state,
                    state,
                    state | LOCKED,
                    .Acquire,
                    .Monotonic,
                ) orelse return;
                continue;
            }

            if ((state & PARKED == 0) and spin_wait.spin()) {
                state = @atomicLoad(u8, &self.state, .Monotonic);
                continue;
            }

            if (state & PARKED == 0) {
                if (@cmpxchgWeak(
                    u8,
                    &self.state,
                    state,
                    state | PARKED,
                    .Monotonic,
                    .Monotonic,
                )) |new_state| {
                    state = new_state;
                    continue;
                }
            }

            switch (blk: {
                self.bucket.lock.lock();

                if (@atomicLoad(u8, &self.state, .Monotonic) != (LOCKED | PARKED)) {
                    self.bucket.lock.unlock();
                    break :blk ParkResult.invalid;
                }

                var waiter: Waiter = undefined;
                waiter.parker = Parker.init();
                defer waiter.parker.deinit();

                waiter.next = null;
                if (self.bucket.tail) |tail| {
                    tail.next = &waiter;
                } else {
                    self.bucket.head = &waiter;
                }
                self.bucket.tail = &waiter;
                self.bucket.lock.unlock();

                waiter.parker.park();
                if (waiter.acquired)
                    break :blk ParkResult.handoff;
                break :blk ParkResult.unparked;
            }) {
                .handoff => return,
                .unparked => {},
                .invalid => {},
            }

            spin_wait.reset();
            state = @atomicLoad(u8, &self.state, .Monotonic);
        }
    }

    pub fn release(self: *Mutex) void {
        if (@cmpxchgStrong(
            u8,
            &self.state,
            LOCKED,
            UNLOCKED,
            .Release,
            .Monotonic,
        )) |_| {
            self.releaseSlow();
        }
    }

    fn releaseSlow(self: *Mutex) void {
        @setCold(true);
        const force_fair = false;

        var result = UnparkResult{
            .unparked = 0,
            .be_fair = false,
            .has_more = false,
        };
        
        self.bucket.lock.lock();

        const waiter = self.bucket.head;
        if (waiter) |w| {
            self.bucket.head = w.next;
            if (self.bucket.head == null)
                self.bucket.tail = null;
                
            result.unparked = 1;
            result.has_more = self.bucket.head != null;
            result.be_fair = should_timeout: {
                const now = nanotime();
                const timed_out = now > self.bucket.timeout;
                if (timed_out) {
                    const gen_u32 = gen: {
                        self.bucket.seed ^= self.bucket.seed << 13;
                        self.bucket.seed ^= self.bucket.seed >> 17;
                        self.bucket.seed ^= self.bucket.seed << 5;
                        break :gen self.bucket.seed;
                    };
                    const nanos = gen_u32 % 1_000_000;
                    self.bucket.timeout = now + nanos;
                }
                break :should_timeout timed_out;
            };
        }

        const acquired = callback: {
            if ((result.unparked != 0) and (force_fair or result.be_fair)) {
                if (!result.has_more)
                    @atomicStore(u8, &self.state, LOCKED, .Monotonic);
                break :callback true;
            }

            const new_state: u8 = if (result.has_more) PARKED else UNLOCKED;
            @atomicStore(u8, &self.state, new_state, .Release);
            break :callback false;
        };

        if (waiter) |w|
            w.acquired = acquired;

        self.bucket.lock.unlock();

        if (waiter) |w|
            w.parker.unpark();
    }

    const ParkResult = enum {
        handoff,
        unparked,
        invalid,
    };

    const UnparkResult = struct {
        unparked: usize,
        be_fair: bool,
        has_more: bool,
    };

    const Bucket = struct {
        lock: WordLock = WordLock{},
        head: ?*Waiter = null,
        tail: ?*Waiter = null,
        timeout: u64 = 0,
        seed: u32 = 0,
    };

    const SpinWait = struct {
        counter: std.math.Log2Int(usize) = 0,

        fn spin(self: *SpinWait) bool {
            if (self.counter >= 10)
                return false;

            self.counter += 1;
            if (self.counter <= 3) {
                std.SpinLock.loopHint(@as(usize, 1) << self.counter);
            } else if (std.builtin.os.tag == .windows) {
                std.os.windows.kernel32.Sleep(0);
            } else {
                std.os.sched_yield() catch unreachable;
            }

            return true;
        }

        fn reset(self: *SpinWait) void {
            self.counter = 0;
        }
    };

    const Waiter = struct {
        prev: ?*Waiter align(4),
        next: ?*Waiter,
        tail: ?*Waiter,
        parker: Parker,
        acquired: bool,
    };

    const WordLock = struct {
        state: usize = UNLOCKED,

        const QLOCKED = PARKED;
        const WAITING = ~@as(usize, LOCKED | QLOCKED);

        fn lock(self: *WordLock) void {
            if (@cmpxchgWeak(
                usize,
                &self.state,
                UNLOCKED,
                LOCKED,
                .Acquire,
                .Monotonic,
            )) |_| {
                self.lockSlow();
            }
        }

        fn lockSlow(self: *WordLock) void {
            @setCold(true);

            var waiter: Waiter = undefined;
            waiter.parker = Parker.init();
            defer waiter.parker.deinit();

            var spin_wait = SpinWait{};
            var state = @atomicLoad(usize, &self.state, .Monotonic);

            while (true) {
                if (state & LOCKED == 0) {
                    state = @cmpxchgWeak(
                        usize,
                        &self.state,
                        state,
                        state | LOCKED,
                        .Acquire,
                        .Monotonic,
                    ) orelse return;
                    continue;
                }

                const head = @intToPtr(?*Waiter, state & WAITING);
                if ((head == null) and spin_wait.spin()) {
                    state = @atomicLoad(usize, &self.state, .Monotonic);
                    continue;
                }

                waiter.parker.prepare();
                waiter.prev = null;
                waiter.next = head;
                waiter.tail = if (head == null) &waiter else null;

                if (@cmpxchgWeak(
                    usize,
                    &self.state,
                    state,
                    (state & ~WAITING) | @ptrToInt(&waiter),
                    .Release,
                    .Monotonic,
                )) |updated| {
                    state = updated;
                    continue;
                }

                waiter.parker.park();
                spin_wait.reset();
                state = @atomicLoad(usize, &self.state, .Monotonic);
            }
        }

        fn unlock(self: *WordLock) void {
            const state = @atomicRmw(usize, &self.state, .Sub, LOCKED, .Release);
            if ((state & QLOCKED != 0) or (state & WAITING == 0))
                return;
            self.unlockSlow();
        }

        fn unlockSlow(self: *WordLock) void {
            @setCold(true);

            var state = @atomicLoad(usize, &self.state, .Monotonic);
            while (true) {
                if ((state & QLOCKED != 0) or (state & WAITING == 0))
                    return;
                state = @cmpxchgWeak(
                    usize,
                    &self.state,
                    state,
                    state | QLOCKED,
                    .Acquire,
                    .Monotonic,
                ) orelse break;
            }

            outer: while (true) {
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
                        state & ~@as(usize, QLOCKED),
                        .Release,
                        .Monotonic,
                    ) orelse return;
                    @fence(.Acquire);
                    continue;
                }

                if (tail.prev) |new_tail| {
                    head.tail = new_tail;
                    _ = @atomicRmw(usize, &self.state, .And, ~@as(usize, QLOCKED), .Release);
                } else {
                    while (true) {
                        state = @cmpxchgWeak(
                            usize,
                            &self.state,
                            state,
                            state & LOCKED,
                            .Release,
                            .Monotonic,
                        ) orelse break;
                        if (state & WAITING != 0) {
                            @fence(.Acquire);
                            continue :outer;
                        }
                    }
                }

                tail.parker.unpark();
                break;
            }
        }
    };
};

