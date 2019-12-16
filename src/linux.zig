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
    i: i32,
    b: struct {
        lock: u8,
        waiting: u8,
    },

    pub fn init() @This() {
        return @This(){ .i = 0 };
    }

    pub fn deinit(self: *@This()) void {
        self.* = undefined;
    }

    pub fn acquire(self: *@This()) Held {
        if (@atomicRmw(u8, &self.b, .Xchg, 1, .Acquire) != 0)
            self.acquireSlow();
        return Held{ .mutex = self };
    }

    fn acquireSlow(self: *@This()) void {
        @setCold(true);

        var spin: u32 = 40;
        while (spin != 0) : (spin -= 1) {
            if (@atomicRmw(u8, &self.b, .Xchg, 1, .Acquire) == 0)
                return;
            std.os.sched_yield() catch unreachable;
        }

        var waiting = @atomicLoad()
    }

    pub const Held = struct {
        mutex: *_Mutex,

        pub fn release(self: Held) void {
            @atomicStore(u8, &self.mutex.b, 0, .Release);
            if (@atomicLoad(i32, &self.mutex.i, .Monotonic) >= WAIT)
                _ = linux.futex_wake(&self.mutex.i, linux.FUTEX_WAKE | linux.FUTEX_PRIVATE_FLAG, 1);
        }
    };
};