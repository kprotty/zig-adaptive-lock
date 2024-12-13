const std = @import("std");
const builtin = @import("builtin");

pub const Lock = switch (builtin.os.tag) {
    .windows => CriticalSectionLock,
    .linux => FutexPILock,
    .macos => OsUnfairLock,
    else => void,
};

const CriticalSectionLock = extern struct {
    pub const name = "CRITICAL_SECTION";

    cs: std.os.windows.CRITICAL_SECTION,

    pub fn init(self: *Lock) void {
        std.os.windows.kernel32.InitializeCriticalSection(&self.cs);
    }

    pub fn deinit(self: *Lock) void {
        std.os.windows.kernel32.DeleteCriticalSection(&self.cs);
    }

    pub fn acquire(self: *Lock) void {
        std.os.windows.kernel32.EnterCriticalSection(&self.cs);
    }

    pub fn release(self: *Lock) void {
        std.os.windows.kernel32.LeaveCriticalSection(&self.cs);
    }
};

const OsUnfairLock = extern struct {
    pub const name = "os_unfair_lock";

    oul: u32 = 0,

    pub fn init(self: *Lock) void {
        self.* = .{};
    }

    pub fn deinit(self: *Lock) void {
        self.* = undefined;
    }

    extern "c" fn os_unfair_lock_lock(o: *u32) void;
    extern "c" fn os_unfair_lock_unlock(o: *u32) void;

    pub fn acquire(self: *Lock) void {
        os_unfair_lock_lock(&self.oul);
    }

    pub fn release(self: *Lock) void {
        os_unfair_lock_unlock(&self.oul);
    }
};

const FutexPILock = extern struct {
    pub const name = "FUTEX_LOCK_PI";

    state: std.atomic.Value(u32) = .{ .raw = 0 },

    pub fn init(self: *@This()) void {
        self.* = .{};
    }

    pub fn deinit(self: *@This()) void {
        self.* = undefined;
    }

    const FUTEX_WAITERS = 0x80000000;

    pub fn acquire(self: *@This()) void {
        const tid = std.Thread.getCurrentId();
        var state = self.state.cmpxchgStrong(0, tid, .acquire, .monotonic) orelse {
            @branchHint(.likely);
            return;
        };

        var spin: u32 = 100;
        while (true) : (state = self.state.load(.acquire)) {
            if (state == 0) {
                state = self.state.cmpxchgStrong(0, tid, .acquire, .monotonic) orelse return;
            }

            if (spin > 0 and state & FUTEX_WAITERS == 0) {
                std.atomic.spinLoopHint();
                spin -= 1;
                continue;
            }

            switch (std.posix.errno(std.os.linux.syscall4(
                .futex,
                @intFromPtr(&self.state),
                std.os.linux.FUTEX.PRIVATE_FLAG | std.os.linux.FUTEX.LOCK_PI,
                undefined,
                0,
            ))) {
                .SUCCESS => return,
                .AGAIN => continue,
                else => unreachable,
            }
        }
    }

    pub fn release(self: *@This()) void {
        const tid = std.Thread.getCurrentId();
        _ = self.state.cmpxchgStrong(tid, 0, .release, .monotonic) orelse {
            @branchHint(.likely);
            return;
        };

        std.debug.assert(std.posix.errno(std.os.linux.syscall4(
            .futex,
            @intFromPtr(&self.state),
            std.os.linux.FUTEX.PRIVATE_FLAG | std.os.linux.FUTEX.UNLOCK_PI,
            undefined,
            0,
        )) == .SUCCESS);
    }
};


    
    
