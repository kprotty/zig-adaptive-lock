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
        var spin: usize = 0;
        var state: State = .Unlocked;
        while (true) {
            if (state == .Unlocked) {
                state = @cmpxchgWeak(
                    State,
                    &self.state,
                    .Unlocked,
                    .Locked,
                    .Acquire,
                    .Monotonic,
                ) orelse return;
            } else {
                std.SpinLock.loopHint(1);
                state = @atomicLoad(State, &self.state, .Monotonic);
            }
        }
    }

    pub fn release(self: *Mutex) void {
        @atomicStore(State, &self.state, .Unlocked, .Release);
    }
};