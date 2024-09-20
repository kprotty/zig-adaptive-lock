// Copyright (c) 2020 kprotty
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

const std = @import("std");
const Atomic = std.atomic.Value;
const utils = @import("../utils.zig");

pub const Lock =
    if (utils.is_windows)
    WindowsLock
else if (utils.is_darwin)
    DarwinLock
else if (utils.is_linux)
    LinuxLock
else
    void;

const DarwinLock = extern struct {
    pub const name = "os_unfair_lock";

    oul: std.os.darwin.os_unfair_lock,

    pub fn init(self: *Lock) void {
        self.oul = std.os.darwin.OS_UNFAIR_LOCK_INIT;
    }

    pub fn deinit(self: *Lock) void {
        self.* = undefined;
    }

    pub fn acquire(self: *Lock) void {
        std.os.darwin.os_unfair_lock_lock(&self.oul);
    }

    pub fn release(self: *Lock) void {
        std.os.darwin.os_unfair_lock_unlock(&self.oul);
    }
};

const WindowsLock = extern struct {
    pub const name = "SRWLOCK";

    srwlock: std.os.windows.SRWLOCK = std.os.windows.SRWLOCK_INIT,

    pub fn init(self: *Lock) void {
        self.* = Lock{};
    }

    pub fn deinit(self: *Lock) void {
        self.* = undefined;
    }

    pub fn acquire(self: *Lock) void {
        std.os.windows.kernel32.AcquireSRWLockExclusive(&self.srwlock);
    }

    pub fn release(self: *Lock) void {
        std.os.windows.kernel32.ReleaseSRWLockExclusive(&self.srwlock);
    }
};

const LinuxLock = extern struct {
    pub const name = "FUTEX.LOCK_PI";

    state: Atomic(u32) = Atomic(u32).init(UNLOCKED),

    const UNLOCKED = 0;
    const FUTEX_WAITERS = 0x80000000;

    pub fn init(self: *Lock) void {
        self.* = Lock{};
    }

    pub fn deinit(self: *Lock) void {
        self.* = undefined;
    }

    threadlocal var tls_tid: u32 = 0;

    pub fn acquire(self: *Lock) void {
        if (!self.acquireFast()) {
            self.acquireSlow();
        }
    }

    inline fn acquireFast(self: *Lock) bool {
        const tid = tls_tid;
        return tid != 0 and self.state.cmpxchgWeak(
            UNLOCKED,
            tid,
            .acquire,
            .monotonic,
        ) == null;
    }

    fn acquireSlow(self: *Lock) void {
        @setCold(true);

        var tid = tls_tid;
        if (tid == 0) {
            tid = @bitCast(std.os.linux.gettid());
            tls_tid = tid;
        }

        var spin: u8 = 10;
        while (spin > 0) : (spin -= 1) {
            const state = self.state.load(.monotonic);
            if (state & FUTEX_WAITERS != 0) break;
            if (state != UNLOCKED) continue;
            if (self.state.cmpxchgWeak(UNLOCKED, tid, .acquire, .monotonic) == null) return;
        }

        while (true) {
            if (self.state.load(.monotonic) == 0) {
                _ = self.state.cmpxchgStrong(
                    UNLOCKED,
                    tid,
                    .acquire,
                    .monotonic,
                ) orelse return;
            }

            const rc = std.os.linux.syscall4(
                .futex,
                @intFromPtr(&self.state),
                std.os.linux.FUTEX.PRIVATE_FLAG | std.os.linux.FUTEX.LOCK_PI,
                undefined,
                @as(usize, 0),
            );

            switch (std.posix.errno(rc)) {
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
        const tid = tls_tid;
        std.debug.assert(tid != 0);

        _ = self.state.cmpxchgStrong(
            tid,
            UNLOCKED,
            .release,
            .monotonic,
        ) orelse return;

        return self.releaseSlow();
    }

    fn releaseSlow(self: *Lock) void {
        @setCold(true);

        while (true) {
            const rc = std.os.linux.syscall4(
                .futex,
                @intFromPtr(&self.state),
                std.os.linux.FUTEX.PRIVATE_FLAG | std.os.linux.FUTEX.UNLOCK_PI,
                undefined,
                @as(usize, 0),
            );

            switch (std.posix.errno(rc)) {
                .SUCCESS => return,
                .INVAL => unreachable,
                .PERM => unreachable,
                else => unreachable,
            }
        }
    }
};
