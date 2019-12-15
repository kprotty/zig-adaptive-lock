const std = @import("std");
const linux = std.os.linux;

pub const Mutex = extern union {
    key: i32,

    const UNLOCKED = 0;
    const LOCKED = 1;
    const BLOCKED = 2;

    pub fn init() @This() {
        return @This(){ .key = UNLOCKED };
    }

    pub fn deinit(self: *@This()) void {
        self.* = undefined;
    }

    pub fn acquire(self: *@This()) Held {
        const key = @atomicRmw(i32, &self.key, .Xchg, LOCKED, .Acquire);
        if (key != UNLOCKED)
            self.acquireSlow(key);
        return Held{ .mutex = self };
    }

    fn acquireSlow(self: *@This(), key: i32) void {
        @setCold(true);
        var wait = key;

        while (true) {
            for (@as([4]void, undefined)) |_| {
                var state = @atomicLoad(i32, &self.key, .Monotonic);
                while (state == UNLOCKED)
                    state = @cmpxchgWeak(i32, &self.key, UNLOCKED, wait, .Acquire, .Monotonic) orelse return;
                std.SpinLock.yield(30);
            }
            for (@as([1]void, undefined)) |_| {
                var state = @atomicLoad(i32, &self.key, .Monotonic);
                while (state == UNLOCKED)
                    state = @cmpxchgWeak(i32, &self.key, UNLOCKED, wait, .Acquire, .Monotonic) orelse return;
                std.os.sched_yield() catch unreachable;
            }
            if (@atomicRmw(i32, &self.key, .Xchg, BLOCKED, .Acquire) == UNLOCKED)
                return;
            wait = BLOCKED;
            _ = linux.futex_wait(&self.key, linux.FUTEX_WAIT | linux.FUTEX_PRIVATE_FLAG, BLOCKED, null);
        }
    }

    pub const Held = struct {
        mutex: *Mutex,

        pub fn release(self: Held) void {
            if (@atomicRmw(i32, &self.mutex.key, .Xchg, UNLOCKED, .Release) == BLOCKED)
                _ = linux.futex_wake(&self.mutex.key, linux.FUTEX_WAKE | linux.FUTEX_PRIVATE_FLAG, 1);
        }
    };
};

pub const _Mutex = extern union {
    u: i32,
    b: struct {
        locked: u8,
        contended: u8,
    },

    pub fn init() @This() {
        return @This(){ .u = 0 };
    }

    pub fn deinit(self: *@This()) void {
        self.* = undefined;
    }

    pub fn acquire(self: *@This()) Held {
        if (@atomicRmw(u8, &self.b.locked, .Xchg, 1, .Acquire) != 0)
            self.acquireSlow();
        return Held{ .mutex = self };
    }

    fn acquireSlow(self: *@This()) void {
        @setCold(true);

        for (@as([40]void, undefined)) |_| {
            if (@atomicRmw(u8, &self.b.locked, .Xchg, 1, .Acquire) == 0)
                return;
            std.os.sched_yield() catch unreachable;
        }

        while (@atomicRmw(i32, &self.u, .Xchg, 257, .Acquire) & 1 != 0) {
            const rc = linux.futex_wait(&self.u, linux.FUTEX_WAIT | linux.FUTEX_PRIVATE_FLAG, 257, null);
            switch (linux.getErrno(rc)) {
                0, linux.EAGAIN, linux.EINTR => continue,
                else => unreachable,
            }
        }
    }

    pub const Held = struct {
        mutex: *_Mutex,

        pub fn release(self: Held) void {
            if (@atomicLoad(i32, &self.mutex.u, .Monotonic) == 1) {
                _ = @cmpxchgWeak(i32, &self.mutex.u, 1, 0, .Release, .Monotonic) orelse return;
            }
            self.mutex.releaseSlow();
        }
    };

    fn releaseSlow(self: *@This()) void {
        @setCold(true);
        
        @atomicStore(u8, &self.b.locked, 0, .Release);
        for (@as([40]void, undefined)) |_| {
            if (@atomicLoad(u8, &self.b.locked, .Monotonic) != 0)
                return;
            std.os.sched_yield() catch unreachable;
        }

        @atomicStore(u8, &self.b.contended, 0, .Monotonic);
        _ = linux.futex_wake(&self.u, linux.FUTEX_WAKE | linux.FUTEX_PRIVATE_FLAG, 1);
    }
};