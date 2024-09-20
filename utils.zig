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
const target = @import("builtin").target;
const arch = target.cpu.arch;
const os_tag = target.os.tag;
const builtin = @import("builtin");

const Atomic = std.atomic.Value;

pub const Futex = std.Thread.Futex;

pub const is_x86 = switch (arch) {
    .i386, .x86_64 => true,
    else => false,
};

pub const is_arm = switch (arch) {
    .arm, .aarch64 => true,
    else => false,
};

pub const is_linux = os_tag == .linux;
pub const is_windows = os_tag == .windows;
pub const is_darwin = switch (os_tag) {
    .macos, .watchos, .tvos, .ios => true,
    else => false,
};

pub const is_posix = builtin.link_libc and (switch (os_tag) {
    .linux, .minix, .macos, .watchos, .tvos, .ios, .solaris, .aix, .openbsd, .kfreebsd, .freebsd, .netbsd, .dragonfly, .hermit, .haiku, .cloudabi, .fuchsia => true,
    else => false,
});

pub fn yieldCpu(iterations: usize) void {
    var i = iterations;
    while (i != 0) : (i -= 1) {
        std.atomic.spinLoopHint();
    }
}

pub fn yieldThread(iterations: usize) void {
    var i = iterations;
    while (i != 0) : (i -= 1) {
        switch (os_tag) {
            .windows => _ = std.os.windows.kernel32.SwitchToThread(),
            else => _ = std.Thread.yield() catch unreachable,
        }
    }
}

pub fn nanotime() u64 {
    if (is_windows) {
        var now = std.os.windows.QueryPerformanceCounter();
        const Static = struct {
            var delta = Atomic(u64).init(0);
            var frequency = Atomic(u64).init(0);
        };

        var freq = Static.frequency.load(.monotonic);
        if (freq == 0) {
            freq = std.os.windows.QueryPerformanceFrequency();
            Static.frequency.store(freq, .monotonic);
        }

        var delta = Static.delta.load(.monotonic);
        if (delta == 0) {
            delta = Static.delta.cmpxchgStrong(0, now, .monotonic, .monotonic) orelse now;
        }

        if (now < delta) now = delta;
        return ((now - delta) * std.time.ns_per_s) / freq;
    }

    if (is_darwin) {
        const now = std.os.darwin.mach_absolute_time();
        const Static = struct {
            var info: std.c.darwin.mach_timebase_info_data = .{ .numer = 0, .denom = 0 };
            var delta = Atomic(u64).init(0);
        };

        if (@atomicLoad(u32, &Static.info.numer, .monotonic) == 0) {
            std.c.darwin.mach_timebase_info(&Static.info);
        }

        var delta = Static.delta.load(.monotonic);
        if (delta == 0) {
            delta = Static.delta.cmpxchgStrong(0, now, .monotonic, .monotonic) orelse now;
        }

        var current = now - delta;
        if (Static.info.numer != 1) current *= Static.info.numer;
        if (Static.info.denom != 1) current /= Static.info.denom;
        return current;
    }

    var ts: std.c.timespec = undefined;
    std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts) catch unreachable;
    return @as(u64, @intCast(ts.tv_sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.tv_nsec));
}

pub const SpinWait = struct {
    counter: usize = 0,

    pub fn reset(self: *SpinWait) void {
        self.* = .{};
    }

    pub fn yield(self: *SpinWait) bool {
        if (self.counter >= 100) return false;
        self.counter += 1;
        yieldCpu(1);
        // switch (self.counter % 10) {
        //     0 => yieldThread(1),
        //     else => yieldCpu(1),
        // }
        return true;
        // if (self.counter >= 10) return false;
        // self.counter += 1;
        // if (self.counter <= 3) {
        //     yieldCpu(@as(usize, 1) << @intCast(u3, self.counter));
        // } else {
        //     yieldThread(1);
        // }
        // return true;
    }
};

pub const Event = switch (builtin.os.tag) {
    .linux, .macos, .ios, .tvos, .watchos => FutexEvent,
    .windows => WindowsEvent,
    else => PosixEvent,
};

const FutexEvent = struct {
    state: Atomic(u32) = Atomic(u32).init(0),

    pub fn deinit(self: *Event) void {
        self.* = undefined;
    }

    pub fn reset(self: *Event) void {
        self.state.raw = 0;
    }

    pub fn wait(self: *Event) void {
        while (self.state.load(.acquire) == 0) {
            Futex.wait(&self.state, 0, null) catch unreachable;
        }
    }

    pub fn notify(self: *Event) void {
        self.state.store(1, .release);
        Futex.wake(&self.state, 1);
    }
};

const PosixEvent = struct {
    cond: std.c.pthread_cond_t = .{},
    mutex: std.c.pthread_mutex_t = .{},
    state: enum { empty, waiting, notified },

    pub fn deinit(self: *Event) void {
        const rc = std.c.pthread_cond_destroy(&self.cond);
        std.debug.assert(rc == .SUCCESS or rc == .INVAL);

        const rm = std.c.pthread_mutex_destroy(&self.mutex);
        std.debug.assert(rm == .SUCCESS or rm == .INVAL);
    }

    pub fn reset(self: *Event) void {
        self.state = .empty;
    }

    pub fn wait(self: *Event) void {
        std.debug.assert(std.c.pthread_mutex_lock(&self.mutex) == .SUCCESS);
        defer std.debug.assert(std.c.pthread_mutex_unlock(&self.mutex) == .SUCCESS);

        if (self.state == .notified)
            return;

        self.state = .waiting;
        while (self.state == .waiting) {
            std.debug.assert(std.c.pthread_cond_wait(&self.cond, &self.mutex) == .SUCCESS);
        }
    }

    pub fn notify(self: *Event) void {
        std.debug.assert(std.c.pthread_mutex_lock(&self.mutex) == .SUCCESS);
        defer std.debug.assert(std.c.pthread_mutex_unlock(&self.mutex) == .SUCCESS);

        const state = self.state;
        self.state = .notified;

        if (state == .waiting) {
            std.debug.assert(std.c.pthread_cond_signal(&self.cond) == .SUCCESS);
        }
    }
};

const WindowsEvent = struct {
    thread_id: Atomic(usize) = Atomic(usize).init(0),

    extern "ntdll" fn NtAlertThreadByThreadId(
        thread_id: usize,
    ) callconv(std.os.windows.WINAPI) std.os.windows.NTSTATUS;

    extern "ntdll" fn NtWaitForAlertByThreadId(
        addr: usize,
        timeout: ?*std.os.windows.LARGE_INTEGER,
    ) callconv(std.os.windows.WINAPI) std.os.windows.NTSTATUS;

    pub fn deinit(self: *Event) void {
        self.* = undefined;
    }

    pub fn reset(self: *Event) void {
        self.thread_id.raw = 0;
    }

    pub fn wait(self: *Event) void {
        const tid: usize = std.os.windows.kernel32.GetCurrentThreadId();

        if (self.thread_id.cmpxchgStrong(0, tid, .acquire, .acquire)) |thread_id| {
            std.debug.assert(thread_id == std.math.maxInt(usize));
            return;
        }

        while (true) {
            const status = NtWaitForAlertByThreadId(@intFromPtr(&self.thread_id), null);
            if (status != .ALERTED) std.debug.panic("status={} tid={}", .{ status, tid });
            if (self.thread_id.load(.acquire) == std.math.maxInt(usize)) break;
        }
    }

    pub fn notify(self: *Event) void {
        const tid = self.thread_id.swap(std.math.maxInt(usize), .release);
        std.debug.assert(tid != @as(usize, @truncate(0xaaaaaaaaaaaaaaaa)));
        std.debug.assert(tid != std.math.maxInt(usize));

        if (tid != 0) {
            const status = NtAlertThreadByThreadId(tid);
            if (status != .SUCCESS) std.debug.panic("status={} tid={}", .{ status, tid });
        }
    }
};

const SpinEvent = struct {
    notified: Atomic(bool) = Atomic(bool).init(false),

    pub fn deinit(self: *Event) void {
        self.* = undefined;
    }

    pub fn reset(self: *Event) void {
        self.notified.raw = false;
    }

    pub fn wait(self: *Event) void {
        while (!self.notified.load(.acquire))
            std.atomic.spinLoopHint();
    }

    pub fn notify(self: *Event) void {
        self.notified.store(true, .release);
    }
};
