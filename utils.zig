// Copyright (c) 2020 kprotty
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// 	http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

const std = @import("std");
const target = std.Target.current;
const arch = target.cpu.arch;
const os_tag = target.os.tag;

const Atomic = std.atomic.Atomic;
const Futex = std.Thread.Futex;

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

pub const is_posix = std.builtin.link_libc and (switch (os_tag) {
    .linux,
    .minix,
    .macos,
    .watchos,
    .tvos,
    .ios,
    .solaris,
    .aix,
    .openbsd,
    .kfreebsd,
    .freebsd,
    .netbsd,
    .dragonfly,
    .hermit,
    .haiku,
    .cloudabi,
    .fuchsia => true,
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
            else => _ = std.os.system.sched_yield(),
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

        var freq = Static.frequency.load(.Monotonic);
        if (freq == 0) {
            freq = std.os.windows.QueryPerformanceFrequency();
            Static.frequency.store(freq, .Monotonic);
        }

        var delta = Static.delta.load(.Monotonic);
        if (delta == 0) {
            delta = Static.delta.compareAndSwap(0, now, .Monotonic, .Monotonic) orelse now;
        }

        if (now < delta) now = delta;
        return ((now - delta) * std.time.ns_per_s) / freq;
    }

    if (is_darwin) {
        const now = std.os.darwin.mach_absolute_time();
        const Static = struct {
            var info: std.os.darwin.mach_timebase_info_data = undefined;
            var delta = Atomic(u64).init(0);
        };

        if (@atomicLoad(u32, &Static.info.numer, .Monotonic) == 0) {
            std.os.darwin.mach_timebase_info(&Static.info);
        }
        
        var delta = Static.delta.load(.Monotonic);
        if (delta == 0) {
            delta = Static.delta.compareAndSwap(0, now, .Monotonic, .Monotonic) orelse now;
        }

        var current = now - delta;
        if (info.numer != 1) current *= info.numer;
        if (info.denom != 1) current /= info.denom;
        return current;
    }

    var ts: std.os.timespec = undefined;
    std.os.clock_gettime(std.os.CLOCK_MONOTONIC, &ts) catch unreachable;
    return @intCast(u64, ts.tv_sec) * std.time.ns_per_s + @intCast(u64, ts.tv_nsec);
}

pub const SpinWait = struct {
    counter: u8 = 10,

    pub fn reset(self: *SpinWait) void {
        self.* = .{};
    }

    pub fn yield(self: *SpinWait) bool {
        if (self.counter == 0) return false;

        self.counter -= 1;
        switch (self.counter) {
            0 => yieldCpu(1),
            else => yieldThread(1),
        }

        return true;
    }
};

pub const Event = struct {
    state: Atomic(u32) = Atomic(u32).init(0),

    pub fn reset(self: *Event) void {
        self.* = .{};
    }

    pub fn wait(self: *Event) void {
        while (self.state.load(.Acquire) == 0) {
            Futex.wait(&self.state, 0, null) catch unreachable;
        }
    }

    pub fn notify(self: *Event) void {
        self.state.store(1, .Release);
        Futex.wake(&self.state, 1);
    }
};