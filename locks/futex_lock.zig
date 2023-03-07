const std = @import("std");
const Atomic = std.atomic.Atomic;
const Futex = std.Thread.Futex;

pub const Lock = struct {
    state: Atomic(u32) = Atomic(u32).init(unlocked),

    const unlocked = 0;
    const locked = 1;
    const contended = 2;

    pub const name = "futex_lock";

    pub fn init(self: *Lock) void {
        self.* = .{};
    }

    pub fn deinit(self: *Lock) void {
        self.* = undefined;
    }

    pub fn acquire(self: *Lock) void {
        const state = self.state.tryCompareAndSwap(unlocked, locked, .Acquire, .Monotonic) orelse return;
        self.acquireSlow(state);
    }

    fn acquireSlow(self: *Lock, state: u32) void {
        @setCold(true);

        if (state == contended) {
            Futex.wait(&self.state, contended);
        }

        while (self.state.swap(contended, .Acquire) != unlocked) {
            Futex.wait(&self.state, contended);
        }
    }

    pub fn release(self: *Lock) void {
        if (self.state.swap(unlocked, .Release) == contended) {
            self.releaseSlow();
        }
    }

    fn releaseSlow(self: *Lock) void {
        @setCold(true);

        Futex.wake(&self.state, 1);
    }
};