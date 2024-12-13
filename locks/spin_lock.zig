const std = @import("std");

pub const Lock = extern struct {
    pub const name = "spin_lock";

    locked: std.atomic.Value(u32) = .{ .raw = 0 },

    pub fn init(self: *Lock) void {
        self.* = .{};
    }

    pub fn deinit(self: *Lock) void {
        self.* = undefined;
    }

    pub fn acquire(self: *Lock) void {
        while (self.locked.fetchOr(1, .acquire) & 1 > 0) {
            while (true) {
                std.atomic.spinLoopHint();
                if (self.locked.load(.monotonic) == 0) break;
            }
        }
    }

    pub fn release(self: *Lock) void {
        self.locked.store(0, .release);
    }
};

