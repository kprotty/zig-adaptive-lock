const std = @import("std");
const parker = @import("./parker.zig");
const assert = std.debug.assert;

pub const SpinLock = struct {
    lock: u8, // TODO: use a bool or enum

    pub const Held = struct {
        spinlock: *SpinLock,

        pub fn release(self: Held) void {
            // TODO: @atomicStore() https://github.com/ziglang/zig/issues/2995
            assert(@atomicRmw(u8, &self.spinlock.lock, .Xchg, 0, .Release) == 1);
        }
    };

    pub fn init() SpinLock {
        return SpinLock{ .lock = 0 };
    }

    pub fn acquire(self: *SpinLock) Held {
        var spin = parker.Spin.Backoff.init();
        while (@atomicRmw(u8, &self.lock, .Xchg, 1, .Acquire) != 0)
            spin.backoff();
        return Held{ .spinlock = self };
    }
};

test "spinlock" {
    var lock = SpinLock.init();
    const held = lock.acquire();
    defer held.release();
}