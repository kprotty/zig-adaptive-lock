const std = @import("std");

pub const Mutex = struct {
    pub const NAME = "tas + backoff";

    const State = enum(usize) {
        locked,
        unlocked,
    };

    state: State,

    pub fn init(self: *Mutex) void {
        self.state = .unlocked;
    }

    pub fn deinit(self: *Mutex) void {
        self.* = undefined;
    }

    pub fn acquire(self: *Mutex) void {
        var iter: std.math.Log2Int(usize) = 0;
        while (@atomicRmw(State, &self.state, .Xchg, .locked, .Acquire) == .locked) {
            if (iter <= 6) {
                std.SpinLock.loopHint(@as(usize, 1) << iter);
                iter += 1;
            } else {
                std.os.sched_yield() catch unreachable;
            }
        }
    }

    pub fn release(self: *Mutex) void {
        @atomicStore(State, &self.state, .unlocked, .Release);
    }
};
