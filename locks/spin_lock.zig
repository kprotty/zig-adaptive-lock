const std = @import("std");
const Atomic = std.atomic.Atomic;

const builtin = @import("builtin");
const x86 = builtin.target.cpu.arch.isX86();

pub const Lock = struct {
    locked: Atomic(bool) = Atomic(bool).init(false),

    pub const name = "spin_lock";

    pub fn init(self: *Lock) void {
        self.* = .{};
    }

    pub fn deinit(self: *Lock) void {
        self.* = undefined;
    }

    pub fn acquire(self: *Lock) void {
        if (x86 and !self.locked.swap(true, .Acquire)) return;
        if (!x86 and self.locked.tryCompareAndSwap(false, true, .Acquire, .Monotonic) == null) return;
        return self.acquireSlow();
    }

    fn acquireSlow(self: *Lock) void {
        @setCold(true);

        while (true) {
            std.atomic.spinLoopHint();
            if (self.locked.load(.Monotonic)) continue;
            if (x86 and !self.locked.swap(true, .Acquire)) return;
            if (!x86 and self.locked.compareAndSwap(false, true, .Acquire, .Monotonic) == null) return;
        }
    }

    pub fn release(self: *Lock) void {
        self.locked.store(false, .Release);
    }
};