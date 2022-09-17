const std = @import("std");
const builtin = @import("builtin");
const os = std.os;

pub const Lock = if (builtin.target.os.tag == .windows)
    SRWLock
else if (builtin.target.os.tag.isDarwin())
    DarwinLock
else if (builtin.link_libc)
    PosixLock
else if (builtin.target.os.tag == .linux)
    FutexLock
else
    @compileError("platform not supported");

const SRWLock = struct {
    srwlock: os.windows.SRWLOCK = .{},

    pub const name = "SRWLOCK";

    pub fn init(self: *Lock) void {
        self.* = .{};
    }

    pub fn deinit(self: *Lock) void {
        self.* = undefined;
    }

    pub fn acquire(self: *Lock) void {
        os.windows.kernel32.AcquireSRWLockExclusive(&self.srwlock);
    }

    pub fn release(self: *Lock) void {
        os.windows.kernel32.ReleaseSRWLockExclusive(&self.srwlock);
    }
};

const DarwinLock = struct {
    oul: os.darwin.os_unfair_lock = .{},

    pub const name = "os_unfair_lock";

    pub fn init(self: *Lock) void {
        self.* = .{};
    }

    pub fn deinit(self: *Lock) void {
        self.* = undefined;
    }

    pub fn acquire(self: *Lock) void {
        os.darwin.os_unfair_lock_lock(&self.oul);
    }

    pub fn release(self: *Lock) void {
        os.darwin.os_unfair_lock_unlock(&self.oul);
    }
};

const PosixLock = struct {
    mutex: std.c.pthread_mutex_t = .{},

    pub const name = "pthread_mutex_t";

    extern "c" fn pthread_mutex_init(m: *std.c.pthread_mutex_t) os.E;

    pub fn init(self: *Lock) void {
        std.debug.assert(pthread_mutex_init(&self.mutex) == .SUCCESS);
    }

    pub fn deinit(self: *Lock) void {
        std.debug.assert(std.c.pthread_mutex_destroy(&self.mutex) == .SUCCESS);
    }

    pub fn acquire(self: *Lock) void {
        std.debug.assert(std.c.pthread_mutex_lock(&self.mutex) == .SUCCESS);
    }

    pub fn release(self: *Lock) void {
        std.debug.assert(std.c.pthread_mutex_unlock(&self.mutex) == .SUCCESS);
    }
};

const FutexLock = struct {
    state: std.atomic.Atomic(u32) = std.atomic.Atomic(u32).init(unlocked),

    const unlocked = 0;
    const futex_waiters = 0x80000000;

    pub const name = "FUTEX_LOCK_PI";

    pub fn init(self: *Lock) void {
        self.* = .{};
    }

    pub fn deinit(self: *Lock) void {
        self.* = undefined;
    }

    threadlocal var tls_id: u32 = 0;

    pub fn acquire(self: *Lock) void {
        const tid = tls_id;
        if (tid != 0 and self.state.tryCompareAndSwap(unlocked, tid, .Acquire, .Monotonic) == null) return;
        self.acquireSlow();
    }

    fn acquireSlow(self: *Lock) void {
        @setCold(true);

        var tid = tls_id;
        if (tid == 0) {
            tid = @bitCast(u32, os.linux.gettid());
            tls_id = tid;
        }

        while (true) {
            if (self.state.load(.Monotonic) == unlocked) {
                _ = self.state.compareAndSwap(unlocked, tid, .Acquire, .Monotonic) orelse return;
            }

            const rc = os.linux.syscall4(
                .futex,
                @ptrToInt(&self.state),
                os.linux.FUTEX.PRIVATE_FLAG | os.linux.FUTEX.LOCK_PI,
                undefined,
                @as(usize, 0),
            );

            switch (os.linux.getErrno(rc)) {
                .SUCCESS => return,
                .AGAIN => continue,
                .NOSYS => unreachable,
                .DEADLK => unreachable,
                .FAULT => unreachable,
                .INVAL => unreachable,
                .PERM => unreachable,
                .NOMEM => @panic("kernel OOM"),
                else => unreachable,
            }
        }
    }

    pub fn release(self: *Lock) void {
        const tid = tls_id;
        _ = self.state.compareAndSwap(tid, unlocked, .Release, .Monotonic) orelse return;
        self.releaseSlow();
    }

    fn releaseSlow(self: *Lock) void {
        @setCold(true);

        const rc = os.linux.syscall4(
            .futex,
            @ptrToInt(&self.state),
            os.linux.FUTEX.PRIVATE_FLAG | os.linux.FUTEX.UNLOCK_PI,
            undefined,
            @as(usize, 0),
        );

        switch (os.linux.getErrno(rc)) {
            .SUCCESS => {},
            .INVAL => unreachable,
            .PERM => unreachable,
            else => unreachable,
        }
    }
};