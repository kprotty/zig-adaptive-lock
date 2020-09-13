const std = @import("std");

pub const Mutex = struct {
    pub const NAME = "hybrid";

    const State = enum(i32) {
        unlocked = 0,
        locked = 1,
        sleeping = 2,
    };

    state: State,

    pub fn init(self: *Mutex) void {
        self.state = .unlocked;
    }

    pub fn deinit(self: *Mutex) void {
        self.* = undefined;
    }

    pub fn acquire(self: *Mutex) void {
        const state = @atomicRmw(State, &self.state, .Xchg, .locked, .Acquire);
        if (state != .unlocked)
            self.acquireSlow(state);
    }

    fn acquireSlow(self: *Mutex, current_state: State) void {
        @setCold(true);

        var wait = current_state;
        while (true) {
            
            for ([_]void{{}} ** 4) |_| {
                if (@atomicLoad(State, &self.state, .Monotonic) == .unlocked)
                    _ = @cmpxchgWeak(State, &self.state, .unlocked, wait, .Acquire, .Monotonic) orelse return;
                std.SpinLock.loopHint(30);
            }

            if (@atomicRmw(State, &self.state, .Xchg, .sleeping, .Acquire) == .unlocked)
                return;

            wait = .sleeping;
            while (@atomicLoad(State, &self.state, .Monotonic) == .sleeping) {
                _ = std.os.linux.futex_wait(
                    @ptrCast(*const i32, &self.state),
                    std.os.linux.FUTEX_PRIVATE_FLAG | std.os.linux.FUTEX_WAIT,
                    @enumToInt(State.sleeping),
                    null,
                );
            }
        }
    }

    pub fn release(self: *Mutex) void {
        const state = @atomicRmw(State, &self.state, .Xchg, .unlocked, .Release);
        if (state == .sleeping)
            self.releaseSlow();
    }

    fn releaseSlow(self: *Mutex) void {
        @setCold(true);
        _ = std.os.linux.futex_wake(
            @ptrCast(*const i32, &self.state),
            std.os.linux.FUTEX_PRIVATE_FLAG | std.os.linux.FUTEX_WAKE,
            @as(i32, 1),
        );
    }
};