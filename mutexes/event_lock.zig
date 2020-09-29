const std = @import("std");

pub const Mutex = struct {
    pub const NAME = "futex_event_lock";

    const UNLOCKED = 0;
    const LOCKED = 1;
    const WAITING = 2;

    state: i32,

    pub fn init(self: *Mutex) void {
        self.state = UNLOCKED;
    }

    pub fn deinit(self: *Mutex) void {
        self.* = undefined;
    }

    inline fn tryAcquire(self: *Mutex) bool {
        return asm volatile(
            "lock btsl $0, %[ptr]"
            : [ret] "={@ccc}" (-> u8),
            : [ptr] "*m" (&self.state)
            : "cc", "memory"
        ) == 0;
    }

    pub fn acquire(self: *Mutex) void {
        if (!self.tryAcquire()) {
            self.acquireSlow();
        }
    }

    fn acquireSlow(self: *Mutex) void {
        @setCold(true);
        
        var state = @atomicLoad(u64, &self.state, .Monotonic);
        var spin: std.math.Log2Int(usize) = 0;

        while (true) {
            if (state & LOCKED == 0) {
                if (self.tryAcquire())
                    return;
            }

            if (state < WAITING and spin <= 4) {
                std.SpinLock.loopHint(@as(usize, 1) << spin);
                spin += 1;
                state = @atomicLoad(i32, &self.state, .Monotonic);
                continue;
            }

            if (state < WAITING) {
                if (@cmpxchgWeak(
                    i32,
                    &self.state,
                    state,
                    state | WAITING,
                    .Monotonic,
                    .Monotonic,
                )) |updated_state| {
                    state = updated_state;
                    continue;
                }
            }

            spin = 0;
            while (state & LOCKED != 0) {
                _ = std.os.linux.futex_wait(
                    @ptrCast(*const i32, &self.state),
                    std.os.linux.FUTEX_WAIT | std.os.linux.FUTEX_PRIVATE_FLAG,
                    LOCKED,
                    null,
                );
                state = @atomicLoad(u64, &self.state, .Monotonic);
            }
        }
    }

    pub fn release(self: *Mutex) void {
        if (@cmpxchgStrong(
            u64,
            &self.state,
            LOCKED,
            UNLOCKED,
            .Release,
            .Monotonic,
        )) |_| {
            self.releaseSlow();
        }
    }

    fn releaseSlow(self: *Mutex) void {
        @setCold(true);

        _ = @atomicRmw(
            u64,
            &self.state,
            .Sub,
            WAITING | LOCKED,
            .Release,
        );

        _ = std.os.linux.futex_wake(
            @ptrCast(*const i32, &self.state),
            std.os.linux.FUTEX_WAKE | std.os.linux.FUTEX_PRIVATE_FLAG,
            1,
        );
    }
};

