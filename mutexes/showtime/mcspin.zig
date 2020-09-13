const std = @import("std");

fn spinLoopHint() void {
    std.SpinLock.loopHint(1);
}

pub const Mutex = struct {
    pub const NAME = "mcs spinlock";

    const Waiter = struct {
        next: ?*Waiter,
        wakeup: bool,
    };

    tail: ?*Waiter,

    pub fn init(self: *Mutex) void {
        self.tail = null;
    }

    pub fn deinit(self: *Mutex) void {
        self.* = undefined;
    }

    threadlocal var tls_waiter: Waiter = undefined;

    pub fn acquire(self: *Mutex) void {
        const waiter = &tls_waiter;
        waiter.next = null;

        if (@atomicRmw(
            ?*Waiter,
            &self.tail,
            .Xchg,
            waiter,
            .AcqRel,
        )) |old_tail| {
            acquireSlow(waiter, old_tail);
        }
    }

    fn acquireSlow(waiter: *Waiter, old_tail: *Waiter) void {
        @setCold(true);

        waiter.wakeup = false;
        @atomicStore(
            ?*Waiter,
            &old_tail.next,
            waiter,
            .Release,
        );

        while (!@atomicLoad(bool, &waiter.wakeup, .Acquire)) {
            std.os.sched_yield() catch unreachable;
        }
    }

    pub fn release(self: *Mutex) void {
        const waiter = &tls_waiter;

        if (@cmpxchgStrong(
            ?*Waiter,
            &self.tail,
            waiter,
            null,
            .Release,
            .Monotonic,
        )) |failed| {
            releaseSlow(waiter);
        }
    }

    fn releaseSlow(waiter: *Waiter) void {
        @setCold(true);

        while (true) {
            const next_waiter = @atomicLoad(
                ?*Waiter,
                &waiter.next,
                .Acquire,
            ) orelse {
                std.os.sched_yield() catch unreachable;
                continue;
            };
            
            return @atomicStore(
                bool,
                &next_waiter.wakeup,
                true,
                .Release,
            );
        }
    }
};