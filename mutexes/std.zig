const std = @import("std");

pub const Mutex = struct {
    inner: std.Mutex,

    pub fn init() Mutex {
        return Mutex{ .inner = std.Mutex.init() };
    }

    pub fn deinit(self: *Mutex) void {
        self.inner.deinit();
    }

    pub fn locked(self: *Mutex, critical_section: var) void {
        const held = self.inner.acquire();
        critical_section.run();
        held.release();
    }
};