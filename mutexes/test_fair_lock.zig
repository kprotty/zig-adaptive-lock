const std = @import("std");
const nanotime = @import("./nanotime.zig").nanotime;
const Parker = @import("../v2/parker.zig").OsParker;

const InnerLock = @import("./word_lock.zig").Mutex;
const _InnerLock = struct {
    locked: bool,

    fn init(self: *@This()) void {
        self.locked = false;
    }

    fn deinit(self: *@This()) void {
        self.locked = undefined;
    }

    fn acquire(self: *@This()) void {

    }

    fn release(self: *@This()) void {
        
    }
};

pub const Mutex = struct {
    pub const NAME = "test_fair_lock";

    const UNLOCKED = 0;
    const LOCKED = 1 << 0;
    const PARKED = 1 << 1;

    const Waiter = struct {
        next: ?*Waiter,
        tail: *Waiter,
        parker: Parker,
        acquired: bool,
        force_fair_at: u64,
    };

    state: usize,
    lock: InnerLock,
    queue: ?*Waiter,

    pub fn init(self: *Mutex) void {
        self.state = UNLOCKED;
        self.lock.init();
        self.queue = null;
    }

    pub fn deinit(self: *Mutex) void {
        self.lock.deinit();
    }

    pub fn acquire(self: *Mutex) void {
        if (@cmpxchgWeak(
            usize,
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

        var spin: u4 = 0;
        var has_event = false;
        var waiter: Waiter = undefined;
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
                ) orelse break;
                continue;
            }

            if (state & PARKED == 0) {
                if (spin <= 5) {
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
                }
                if (@cmpxchgWeak(
                    usize,
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

            var is_waiting: bool = undefined;
            blk: {
                self.lock.acquire();
                defer self.lock.release();

                state = @atomicLoad(usize, &self.state, .Monotonic);
                is_waiting = state == LOCKED | PARKED;
                if (!is_waiting)
                    break :blk;

                waiter.next = null;
                waiter.tail = &waiter;
                if (self.queue) |head| {
                    head.tail.next = &waiter;
                    head.tail = &waiter;
                } else {
                    self.queue = &waiter;
                }

                if (!has_event) {
                    has_event = true;
                    waiter.parker = Parker.init();
                    waiter.parker.prepare();
                    waiter.force_fair_at = nanotime();
                    
                    var timeout = @as(u64, @ptrToInt(self.queue orelse &waiter));
                    timeout = (13 *% timeout) ^ (timeout >> 15);
                    timeout %= 1 * std.time.ns_per_ms;
                    waiter.force_fair_at += timeout;
                }
            }

            if (is_waiting) {
                waiter.parker.park();
                if (waiter.acquired) {
                    break;
                } else {
                    waiter.parker.prepare();
                }
            }

            spin = 0;
            state = @atomicLoad(usize, &self.state, .Monotonic);
        }

        if (has_event)
            waiter.parker.deinit();
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

        var is_fair: bool = undefined;
        var waiter: ?*Waiter = undefined;

        {
            self.lock.acquire();
            defer self.lock.release();

            waiter = self.queue;
            if (waiter) |w| {
                self.queue = w.next;
                if (self.queue) |next|
                    next.tail = w.tail;

                is_fair = nanotime() >= w.force_fair_at;
                if (is_fair) {
                    if (self.queue == null)
                        @atomicStore(usize, &self.state, LOCKED, .Monotonic);
                } else if (self.queue == null) {
                    @atomicStore(usize, &self.state, UNLOCKED, .Release);
                } else {
                    @atomicStore(usize, &self.state, PARKED, .Release);
                }

            } else {
                @atomicStore(usize, &self.state, UNLOCKED, .Release);
            }
        }

        if (waiter) |w| {
            w.acquired = is_fair;
            w.parker.unpark();
        }
    }
};

