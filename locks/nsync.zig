
const std = @import("std");
const assert = std.debug.assert;

pub const Lock = extern struct {
    pub const name = "nsync";

    const WLOCK: u32 = 1 << 0;
    const SPINLOCK: u32 = 1 << 1;
    const WAITING: u32 = 1 << 2;
    const DESIG_WAKER: u32 = 1 << 3;
    const CONDITION: u32 = 1 << 4;
    const WRITER_WAITING: u32 = 1 << 5;
    const LONG_WAIT: u32 = 1 << 6;
    const ALL_FALSE: u32 = 1 << 7;
    const RLOCK: u32 = 1 << 8;

    const RLOCK_FIELD = ~@as(u32, RLOCK - 1);
    const ANY_LOCK = (WLOCK | RLOCK_FIELD);

    const WZERO_TO_ACQ = ANY_LOCK | LONG_WAIT;
    const WADD_TO_ACQ = WLOCK;
    const WHELD_IF_NON_ZERO = WLOCK;
    const WSET_WHEN_WAITING = WAITING | WRITER_WAITING;
    const WCLEAR_ON_ACQ = WRITER_WAITING;
    const WCLEAR_ON_UNCONT_REL = ALL_FALSE;

    const Semaphore = struct {
        state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

        fn wait(self: *Semaphore) void {
            while (true) {
                var i = self.state.load(.monotonic);
                while (i > 0) i = self.state.cmpxchgWeak(i, i - 1, .acquire, .monotonic) orelse return;
                std.Thread.Futex.wait(&self.state, 0);
            }
        }

        fn post(self: *Semaphore) void {
            _ = self.state.fetchAdd(1, .release);
            std.Thread.Futex.wake(&self.state, 1);
        }
    };

    const Waiter = struct {
        next: ?*Waiter = null,
        prev: ?*Waiter = null,
        sema: Semaphore = .{},
        remove_count: u32 = 0,
        flags: u32 = 0,
    };

    word: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    waiters: ?*Waiter = null,

    pub fn init(self: *Lock) void {
        self.* = Lock{};
    }

    pub fn deinit(self: *Lock) void {
        self.* = undefined;
    }

    fn spinDelay(attempts: u32) u32 {
        if (attempts < 7) {
            for (0..@as(u32, 1) << @intCast(attempts)) |_| std.atomic.spinLoopHint();
            return attempts + 1;
        } else {
            //for (0..@as(u32, 1) << 7) |_| std.atomic.spinLoopHint();
            std.Thread.yield() catch {};
            return attempts;
        }
    }

    fn releaseSpinLock(self: *Lock) void {
        var old = self.word.load(.monotonic);
        while (true) {
            old = self.word.cmpxchgWeak(old, old & ~SPINLOCK, .release, .monotonic) orelse break;
        }
    }

    pub fn acquire(self: *Lock) void {
        if (self.word.cmpxchgStrong(0, WADD_TO_ACQ, .acquire, .monotonic)) |old| {
            if ((old & WZERO_TO_ACQ > 0) or self.word.cmpxchgStrong(
                old,
                (old +% WADD_TO_ACQ) & ~WCLEAR_ON_ACQ,
                .acquire,
                .monotonic,
            ) != null) {
                self.acquireSlow(0);
            } 
        }
    }

    fn acquireSlow(self: *Lock, clear_init: u32) void {
        @branchHint(.unlikely);

        var w = Waiter{};
        var attempts: u32 = 0;
        var wait_count: u32 = 0;
        var long_wait: u32 = 0;
        var clear: u32 = clear_init;
        var zero_to_acq: u32 = WZERO_TO_ACQ;

        while (true) {
            const old = self.word.load(.monotonic);
            if (old & zero_to_acq == 0) {
                _ = self.word.cmpxchgWeak(
                    old,
                    (old +% WADD_TO_ACQ) & ~(clear | long_wait | WCLEAR_ON_ACQ),
                    .acquire,
                    .monotonic,
                ) orelse return;
            } else if (old & SPINLOCK == 0 and self.word.cmpxchgWeak(
                old,
                (old | SPINLOCK | long_wait | WSET_WHEN_WAITING) & ~(clear | ALL_FALSE),
                .acquire,
                .monotonic,
            ) == null) {
                w.sema = .{};
                self.push(&w, wait_count == 0);
                self.releaseSpinLock();

                w.sema.wait();
                
                wait_count += 1;
                if (wait_count == 30) long_wait = LONG_WAIT;

                attempts = 0;
                clear = DESIG_WAKER;
                zero_to_acq &= ~(WRITER_WAITING | LONG_WAIT);
            }
            attempts = spinDelay(attempts);
        }
    }

    pub fn release(self: *Lock) void {
        if (self.word.cmpxchgWeak(WLOCK, 0, .release, .monotonic)) |old| {
            const new = (old - WLOCK) & ~ALL_FALSE;
            assert(new & WLOCK == 0);
            if (old & (WAITING | DESIG_WAKER) == WAITING or self.word.cmpxchgStrong(old, new, .release, .monotonic) != null) {
                self.releaseSlow();
            } 
        }
    }

    fn releaseSlow(self: *Lock) void {
        @branchHint(.unlikely);

        var attempts: u32 = 0;
        while (true) {
            var old = self.word.load(.monotonic);
            if (
                (old & WAITING == 0) or
                (old & DESIG_WAKER > 0) or
                (old & (RLOCK | ALL_FALSE) == (RLOCK | ALL_FALSE))
            ) {
                _ = self.word.cmpxchgWeak(
                    old, 
                    (old - WADD_TO_ACQ) & ~WCLEAR_ON_UNCONT_REL, 
                    .release, 
                    .monotonic,
                ) orelse return;
            } else if (old & SPINLOCK == 0 and self.word.cmpxchgWeak(old, (old - WADD_TO_ACQ) | SPINLOCK | DESIG_WAKER, .acq_rel, .monotonic) == null) {
                var set_on_rel = ALL_FALSE;
                var clear_on_rel = SPINLOCK;

                const to_wake = self.popFirst();
                if (self.waiters != null) {
                    set_on_rel |= WRITER_WAITING;
                    set_on_rel &= ~ALL_FALSE;
                } 

                if (to_wake == null) clear_on_rel |= DESIG_WAKER;
                if (set_on_rel & ALL_FALSE == 0) clear_on_rel |= ALL_FALSE;
                if (self.waiters == null) clear_on_rel |= WAITING | WRITER_WAITING | CONDITION | ALL_FALSE;

                old = self.word.load(.monotonic);
                while (true) {
                    old = self.word.cmpxchgWeak(old, ((old - 0) | set_on_rel) & ~clear_on_rel, .release, .monotonic) orelse break;
                }

                if (to_wake) |w| {
                    w.sema.post();
                }

                return;
            }
            attempts = spinDelay(attempts);
        }
    }

    fn push(self: *Lock, w: *Waiter, last: bool) void {
        const head = self.waiters orelse {
            w.prev = w;
            w.next = w;
            self.waiters = w;
            return;
        };

        const tail = head.prev orelse unreachable;
        assert(tail.next == head);

        tail.next = w;
        w.prev = tail;
        w.next = head;
        head.prev = w;

        if (!last) {
            self.waiters = w;
        }
    }

    fn popFirst(self: *Lock) ?*Waiter {
        const head = self.waiters orelse return null;
        const tail = head.prev orelse unreachable;
        assert(tail.next == head);
        
        const next = head.next orelse unreachable;
        tail.next = next;
        next.prev = tail;

        self.waiters = next;
        if (next == head) self.waiters = null;
        
        return head;
    }
};