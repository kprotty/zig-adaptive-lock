const std = @import("std");

pub const Mutex = struct {
    pub const NAME = "test & test & set";

    const State = enum(usize) {
        unlocked = 0,
        locked = 1,
    };

    state: State,

    pub fn init(self: *Mutex) void {
        self.state = .unlocked;
    }

    pub fn deinit(self: *Mutex) void {
        self.* = undefined;
    }

    pub fn acquire(self: *Mutex) void {
        var state: State = .unlocked;
        while (true) {
            switch (state) {
                .locked => {
                    std.SpinLock.loopHint(1);
                    state = @atomicLoad(State, &self.state, .Monotonic);
                },
                .unlocked => {
                    state = @atomicRmw(
                        State,
                        &self.state,
                        .Xchg,
                        .locked,
                        .Acquire,
                    );
                    if (state == .unlocked)
                        return;
                }
            }
        }
    }

    pub fn release(self: *Mutex) void {
        @atomicStore(State, &self.state, .unlocked, .Release);
    }
};