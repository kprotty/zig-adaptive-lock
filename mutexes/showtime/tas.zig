const std = @import("std");

pub const Mutex = struct {
    pub const NAME = "test & set";

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
        while (@atomicRmw(State, &self.state, .Xchg, .locked, .Acquire) == .locked) {
            std.SpinLock.loopHint(1);
        }
    }

    pub fn release(self: *Mutex) void {
        @atomicStore(State, &self.state, .unlocked, .Release);
    }
};