const std = @import("std");

pub const Mutex = struct {
    pub const NAME = "std.Mutex";

    inner: std.Mutex,

    pub fn init(self: *Mutex) void {
        self.inner = std.Mutex.init();
    }

    pub fn deinit(self: *Mutex) void {
        self.inner.deinit();
    }

    pub fn acquire(self: *Mutex) void {
        _ = self.inner.acquire();
    }

    pub fn release(self: *Mutex) void {
        const held = std.Mutex.Held{ .mutex = &self.inner };
        held.release();
    }
};