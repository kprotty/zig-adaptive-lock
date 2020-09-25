const std = @import("std");

pub const AutoResetEvent = struct {
    const pthread_t = extern struct {
        _opaque: [64]u8 align(16),
    };

    extern "c" fn pthread_cond_init(p: *pthread_t, a: usize) callconv(.C) c_int;
    extern "c" fn pthread_cond_destroy(p: *pthread_t) callconv(.C) c_int;
    extern "c" fn pthread_cond_wait(noalias p: *pthread_t, noalias m: *pthread_t) callconv(.C) c_int;
    extern "c" fn pthread_cond_signal(p: *pthread_t) callconv(.C) c_int;

    extern "c" fn pthread_mutex_init(p: *pthread_t, a: usize) callconv(.C) c_int;
    extern "c" fn pthread_mutex_destroy(p: *pthread_t) callconv(.C) c_int;
    extern "c" fn pthread_mutex_lock(p: *pthread_t) callconv(.C) c_int;
    extern "c" fn pthread_mutex_unlock(p: *pthread_t) callconv(.C) c_int;

    state: State,
    cond: pthread_t,
    mutex: pthread_t,

    const State = enum(i32) {
        empty,
        waiting,
        notified,
    };

    pub fn init(self: *AutoResetEvent) void {
        self.state = .empty;
        _ = pthread_cond_init(&self.cond, 0);
        _ = pthread_mutex_init(&self.mutex, 0);
    }

    pub fn deinit(self: *AutoResetEvent) void {
        _ = pthread_cond_destroy(&self.cond);
        _ = pthread_mutex_destroy(&self.mutex);
    }

    pub fn set(self: *AutoResetEvent) void {
        _ = pthread_mutex_lock(&self.mutex);
        defer _ = pthread_mutex_unlock(&self.mutex);

        const state = self.state;
        self.state = .notified;
        switch (state) {
            .empty => {},
            .waiting => _ = pthread_cond_signal(&self.cond),
            .notified => unreachable,
        }
    }

    pub fn wait(self: *AutoResetEvent) void {
        _ = pthread_mutex_lock(&self.mutex);
        defer _ = pthread_mutex_unlock(&self.mutex);

        if (self.state != .notified) {
            std.debug.assert(self.state == .empty);
            self.state = .waiting;
            while (self.state == .waiting)
                _ = pthread_cond_wait(&self.cond, &self.mutex);
        }

        self.state = .empty;
    }
};