const std = @import("std");

threadlocal var tls_waiter: Waiter = undefined;

const Waiter = struct {
    next: ?*Waiter,
    event: usize,
};

pub const Mutex = struct {
    pub const NAME = "mcs_lock";

    head: ?*Waiter,

    pub fn init(self: *Mutex) void {
        self.head = null;
    }

    pub fn deinit(self: *Mutex) void {
        self.* = undefined;
    }

    pub fn acquire(self: *Mutex) void {
        const local = &tls_waiter;
        local.next = null;
        if (@atomicRmw(?*Waiter, &self.head, .Xchg, local, .AcqRel)) |prev|
            acquireSlow(local, prev);
    }

    fn acquireSlow(local: *Waiter, prev: *Waiter) void {
        @setCold(true);
        local.event = 1;
        @atomicStore(?*Waiter, &prev.next, local, .Release);

        for (@as([3]void, undefined)) |_, i| {
            std.SpinLock.loopHint(@as(usize, 1) << @intCast(std.math.Log2Int(usize), i));
            if (@atomicLoad(usize, &local.event, .Acquire) == 0)
                return;
        }

        var event = std.ResetEvent.init();
        defer event.deinit();
        if (@atomicRmw(usize, &local.event, .Xchg, @ptrToInt(&event), .AcqRel) != 0)
            event.wait();
    }

    pub fn release(self: *Mutex) void {
        const local = &tls_waiter;
        _ = @cmpxchgStrong(
            ?*Waiter,
            &self.head,
            local,
            null,
            .Release,
            .Acquire,
        ) orelse return;
        releaseSlow(local);
    }

    fn releaseSlow(local: *Waiter) void {
        @setCold(true);

        const next = blk: {
            var i: usize = 0;
            while (true) {
                if (@atomicLoad(?*Waiter, &local.next, .Acquire)) |waiter|
                    break :blk waiter;
                i +%= 1;
                std.SpinLock.loopHint(std.math.min(64, i));
            }
        };

        const event = @atomicRmw(usize, &next.event, .Xchg, 0, .AcqRel);
        if (event != 1)
            @intToPtr(*std.ResetEvent, event).set();
    }
};