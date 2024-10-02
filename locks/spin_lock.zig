const std = @import("std");

pub const Lock = extern struct {
    pub const name = "spinlock";

    locked: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn init(self: *Lock) void {
        self.* = .{};
    }

    pub fn deinit(self: *Lock) void {
        self.* = undefined;
    }

    pub fn acquire(self: *Lock) void {
        if (self.locked.fetchOr(1, .acquire) & 1 == 1) {
            self.acquireSlow();
        }
    }

    fn acquireSlow(self: *Lock) void {
        @branchHint(.unlikely);

        var unique: u32 = 0;
        var prng = std.Random.DefaultPrng.init(@intFromPtr(&unique));

        while (true) {
            while (self.locked.load(.monotonic) > 0) {
                for (0..prng.random().uintAtMost(u32, 128)) |_| std.atomic.spinLoopHint();
            }
            _ = self.locked.cmpxchgStrong(0, 1, .acquire, .monotonic) orelse return;
        }
    }

    pub fn release(self: *Lock) void {
        self.locked.store(0, .release);
    }
};
