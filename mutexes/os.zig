const std = @import("std");

pub const Mutex = switch (std.builtin.os.tag) {
    .windows => struct {
        pub const NAME = "SRWLOCK";

        inner: usize,

        extern "kernel32" fn AcquireSRWLockExclusive(ptr: *usize) callconv(.Stdcall) void;
        extern "kernel32" fn ReleaseSRWLockExclusive(ptr: *usize) callconv(.Stdcall) void;

        pub fn init(self: *Mutex) void {
            self.inner = 0;
        }

        pub fn deinit(self: *Mutex) void {
            self.* = undefined;
        }

        pub fn acquire(self: *Mutex) void {
            AcquireSRWLockExclusive(&self.inner);
        }

        pub fn release(self: *Mutex) void {
            ReleaseSRWLockExclusive(&self.inner);
        }
    },
    else => struct {
        // pub const NAME = "pthread_mutex_t";

        // inner: std.c.pthread_mutex_t,

        // pub fn init() Mutex {
        //     return Mutex{ .inner = std.c.PTHREAD_MUTEX_INITIALIZER };
        // }

        // pub fn deinit(self: *Mutex) void {
        //     _ = std.c.pthread_mutex_destroy(&self.inner);
        //     self.* = undefined;
        // }

        // pub fn acquire(self: *Mutex) void {
        //     _ = std.c.pthread_mutex_lock(&self.inner);
        // }

        // pub fn release(self: *Mutex) void {
        //     _ = std.c.pthread_mutex_unlock(&self.inner);
        // }
    },
};