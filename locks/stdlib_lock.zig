const std = @import("std");
const utils = @import("../utils.zig");
const Atomic = std.atomic.Value;

pub const Lock = struct {
    pub const name = "stdlib lock";

    mutex: std.Thread.Mutex = .{},

    pub fn init(self: *Lock) void {
        self.* = Lock{};
    }

    pub fn deinit(self: *Lock) void {
        self.* = undefined;
    }

    pub fn acquire(self: *Lock) void {
        self.mutex.lock();
    }

    pub fn release(self: *Lock) void {
        self.mutex.unlock();
    }
};
