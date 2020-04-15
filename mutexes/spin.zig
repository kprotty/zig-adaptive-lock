const std = @import("std");

pub const Mutex = struct {
    const State = enum(usize) {
        Locked,
        Unlocked,
    };

    state: State,

    pub fn init() Mutex {
        return Mutex{ .state = .Unlocked };
    }

    pub fn deinit(self: *Mutex) void {
        self.* = undefined;
    }

    pub fn locked(self: *Mutex, critical_section: var) void {
        self.acquire();
        critical_section.run();
        self.release();
    }

    fn acquire(self: *Mutex) void {
        var spin: usize = 0;
        while (true) {
            const state = @atomicLoad(State, &self.state, .Monotonic);
            if (state == .Unlocked)
                _ = @cmpxchgWeak(
                    State,
                    &self.state,
                    .Unlocked,
                    .Locked,
                    .Acquire,
                    .Monotonic,
                ) orelse return Held{ .mutex = self };
            if (spin < 1024) {
                spin <<= 1;
                std.SpinLock.loopHint(spin);
            } else {
                spin +%= 1;
                std.SpinLock.loopHint(std.math.min(10 * 1024, spin *% 1024));
            }
        }
    }

    fn release(self: *Mutex) void {
        @atomicStore(State, &self.mutex.state, .Unlocked, .Release);
    }
};