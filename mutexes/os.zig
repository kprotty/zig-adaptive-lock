const std = @import("std");

pub const Mutex = switch (std.builtin.os.tag) {
    .windows => struct {
        inner: usize,

        extern "kernel32" fn AcquireSRWLockExclusive(ptr: *usize) callconv(.Stdcall) void;
        extern "kernel32" fn ReleaseSRWLockExclusive(ptr: *usize) callconv(.Stdcall) void;

        pub fn init() Mutex {
            return Mutex{ .inner = 0 };
        }

        pub fn deinit(self: *Mutex) void {
            self.* = undefined;
        }

        pub fn locked(self: *Mutex, critical_section: var) void {
            AcquireSRWLockExclusive(&self.inner);
            critical_section.run();
            ReleaseSRWLockExclusive(&self.mutex.inner);
        }
    },
    else => struct {
        inner: std.c.pthread_mutex_t,

        pub fn init() Mutex {
            return Mutex{ .inner = std.c.PTHREAD_MUTEX_INITIALIZER };
        }

        pub fn deinit(self: *Mutex) void {
            _ = std.c.pthread_mutex_destroy(&self.inner);
            self.* = undefined;
        }

        pub fn locked(self: *Mutex, critical_section: var) void {
            _ = std.c.pthread_mutex_lock(&self.inner);
            critical_section.run();
            _ = std.c.pthread_mutex_unlock(&self.inner);
        }
    },
};