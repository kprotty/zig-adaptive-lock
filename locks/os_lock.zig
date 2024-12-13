const std = @import("std");
const builtin = @import("builtin");

pub const Lock = switch (builtin.os.tag) {
    .windows => SRWLock,
    else => PthreadLock,
};

const SRWLock = extern struct {
    pub const name = "SRWLOCK";

    srwlock: std.os.windows.SRWLOCK = std.os.windows.SRWLOCK_INIT,

    pub fn init(self: *@This()) void {
        self.* = .{};
    }

    pub fn deinit(self: *@This()) void {
        self.* = undefined;
    }

    pub fn acquire(self: *@This()) void {
        std.os.windows.kernel32.AcquireSRWLockExclusive(&self.srwlock);
    }

    pub fn release(self: *@This()) void {
        std.os.windows.kernel32.ReleaseSRWLockExclusive(&self.srwlock);
    }
};

const PthreadLock = extern struct {
    pub const name = "pthread_mutex_t";

    mutex: std.c.pthread_mutex_t = .{},

    pub fn init(self: *@This()) void {
        self.* = .{};
    }

    pub fn deinit(self: *@This()) void {
        std.debug.assert(std.c.pthread_mutex_destroy(&self.mutex) == .SUCCESS);
    }

    pub fn acquire(self: *@This()) void {
        std.debug.assert(std.c.pthread_mutex_lock(&self.mutex) == .SUCCESS);
    }

    pub fn release(self: *@This()) void {
        std.debug.assert(std.c.pthread_mutex_unlock(&self.mutex) == .SUCCESS);
    }
};
