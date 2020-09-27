const std = @import("std");

pub const Mutex = struct {
    pub const NAME = "spin_lock";

    const State = enum(usize) {
        Locked,
        Unlocked,
    };

    state: State,

    pub fn init(self: *Mutex) void {
        self.state = .Unlocked;
    }

    pub fn deinit(self: *Mutex) void {
        self.* = undefined;
    }

    pub fn acquire(self: *Mutex) void {
        var spin: std.math.Log2Int(usize) = 0;
        while (true) {
            if (@atomicRmw(
                State,
                &self.state,
                .Xchg,
                .Locked,
                .Acquire,
            ) == .Unlocked) {
                return;
            }

            if (spin <= 6) {
                std.SpinLock.loopHint(@as(usize, 1) << spin);
                spin += 1;
            } else if (std.builtin.os.tag == .windows) {
                std.os.windows.kernel32.Sleep(0);
            } else {
                std.os.sched_yield() catch unreachable;
            }
        }
    }

    pub fn release(self: *Mutex) void {
        @atomicStore(State, &self.state, .Unlocked, .Release);
    }
};