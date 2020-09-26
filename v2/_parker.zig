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

pub const OsParker = extern struct {
    inner: Os.Parker,

    pub fn init() OsParker {
        return OsParker{
            .inner = Os.Parker.init(),
        };
    }

    pub fn deinit(self: *OsParker) void {
        self.inner.deinit();
    }

    pub fn prepare(self: *OsParker) void {
        self.inner.prepare();
    }

    pub fn park(self: *OsParker) void {
        std.debug.assert(self.inner.park(null));
    }

    pub fn parkUntil(self: *OsParker, deadline: *Instant) bool {
        return self.inner.park(deadline.timestamp);
    }

    pub fn unpark(self: *OsParker) void {
        self.inner.unpark();
    }

    pub const Lock = Os.Lock;

    pub const Instant = extern struct {
        timestamp: u64,

        pub fn init(self: *Instant) void {
            self.timestamp = nanotime();
        }

        pub fn deinit(self: *Instant) void {
            self.* = undefined;
        }

        pub fn difference(self: *Instant, other: *Instant) ?u64 {
            if (self.timestamp < other.timestamp)
                return null;
            return self.timestamp - other.timestamp;
        }

        pub fn advance(self: *Instant, duration: u64) void {
            self.timestamp += duration;
        }

        var last: u64 = 0;
        var last_lock = Lock{};

        fn nanotime() u64 {
            if (Os.Time.is_actually_monotonic) 
                return Os.Time.nanotime();
            if (@sizeOf(usize) >= @sizeOf(u64))
                return nanotimeAtomic();
            
            last_lock.acquire();
            defer last_lock.release();

            const now = Os.Time.nanotime();
            if (now <= last)
                return last;

            last = now;
            return now;
        }

        fn nanotimeAtomic() u64 {
            var last_now = @atomicLoad(u64, &last, .Monotonic);
            const now = Os.Time.nanotime();

            while (true) {
                if (last_now >= now)
                    return last_now;
                last_now = @cmpxchgWeak(
                    u64,
                    &last,
                    last_now,
                    now,
                    .Monotonic,
                    .Monotonic,
                ) orelse return now;
            }
        }
    };
};

const Os = switch (std.builtin.os.tag) {
    .linux => switch (std.builtin.link_libc) {
        true => Posix,
        else => Linux,
    },
    .windows => Windows,
    .macosx,
    .watchos,
    .ios,
    .tvos,
    .openbsd,
    .freebsd,
    .kfreebsd,
    .netbsd,
    .dragonfly,
    .minix,
    .haiku,
    .fuchsia,
    .aix,
    .hermit => Posix,
    else => @compileError("OS not supported"),
};

const Windows = struct {
    const windows = std.os.windows;

    pub const Time = struct {
        pub const is_actually_monotonic = false;

        var frequency: u64 = 0;
        var freq_state: FreqState = .uninit;

        const FreqState = enum(usize) {
            uninit,
            storing,
            init,
        };

        fn getFrequency() u64 {
            if (@sizeOf(usize) >= @sizeOf(u64))
                return getFrequencyAtomic();
            if (@atomicLoad(FreqState, &freq_state, .Acquire) == .init)
                return frequency;
            return getFrequencySlow();
        }

        fn getFrequencySlow() u64 {
            @setCold(true);

            const freq = windows.QueryPerformanceFrequency();
            _ = @cmpxchgStrong(
                FreqState,
                &freq_state,
                .uninit,
                .storing,
                .Acquire,
                .Monotonic,
            ) orelse {
                frequency = freq;
                @atomicStore(FreqState, &freq_state, .init, .Release);
            };
            return freq;
        }

        fn getFrequencyAtomic() u64 {
            const freq = @atomicLoad(u64, &frequency, .Monotonic);
            if (freq != 0)
                return freq;
            return getFrequencyAtomicSlow();
        }

        fn getFrequencyAtomicSlow() u64 {
            @setCold(true);

            const freq = windows.QueryPerformanceFrequency();
            @atomicStore(u64, &frequency, freq, .Monotonic);
            return freq;
        }

        pub fn nanotime() u64 {
            const freq = getFrequency();
            const counter = windows.QueryPerformanceCounter();
            return @divFloor(counter *% std.time.ns_per_s, freq);
        }
    };

    const Lock = extern struct {
        srwlock: SRWLOCK = SRWLOCK_INIT,

        const SRWLOCK = usize;
        const SRWLOCK_INIT: SRWLOCK = 0;

        extern "kernel32" fn AcquireSRWLockExclusive(
            srwlock: *SRWLOCK,
        ) callconv(.Stdcall) void;

        extern "kernel32" fn ReleaseSRWLockExclusive(
            srwlock: *SRWLOCK,
        ) callconv(.Stdcall) void;

        pub fn acquire(self: *Lock) void {
            AcquireSRWLockExclusive(&self.srwlock);
        }

        pub fn release(self: *Lock) void {
            ReleaseSRWLockExclusive(&self.srwlock);
        }
    };

    const Parker = extern struct {
        state: State,
        thread_id: windows.DWORD,

        extern "NtDll" fn NtAlertThreadByThreadId(
            thread_id: windows.PVOID,
        ) callconv(.Stdcall) windows.NTSTATUS;

        extern "NtDll" fn NtWaitForAlertByThreadId(
            thread_id: windows.PVOID,
            timeout: ?*windows.LARGE_INTEGER,
        ) callconv(.Stdcall) windows.NTSTATUS;

        const State = extern enum(usize) {
            empty,
            waiting,
            notified,
        };

        fn init() Parker {
            return Parker{
                .state = .empty,
                .thread_id = undefined,
            };
        }

        fn deinit(self: *Parker) void {
            self.* = undefined;
        }

        fn prepare(self: *Parker) void {
            switch (self.state) {
                .empty => {
                    self.thread_id = windows.kernel32.GetCurrentThreadId();
                    self.state = .waiting;
                },
                .waiting => {},
                .notified => self.state = .waiting,
            }
        }

        fn park(self: *Parker, deadline: ?u64) bool {
            const thread_id = @intToPtr(windows.PVOID, self.thread_id);

            while (true) {
                switch (@atomicLoad(State, &self.state, .Acquire)) {
                    .empty => unreachable,
                    .waiting => {},
                    .notified => return true,
                }

                var ts: windows.LARGE_INTEGER = undefined;
                var ts_ptr: ?*windows.LARGE_INTEGER = null;

                if (deadline) |deadline_ns| {
                    const now = OsParker.Instant.nanotime();
                    if (now >= deadline_ns)
                        return false;

                    ts = @intCast(windows.LARGE_INTEGER, deadline_ns - now);
                    ts = -@divFloor(ts, 100);
                    ts_ptr = &ts;
                }

                switch (NtWaitForAlertByThreadId(thread_id, ts_ptr)) {
                    .SUCCESS => {},
                    .ALERTED => {},
                    .TIMEOUT => {},
                    .USER_APC => {},
                    else => |status| {
                        std.debug.warn("NtWaitForAlertByThreadId: {}\n", .{status});
                        std.debug.dumpCurrentStackTrace(null);
                    }
                }
            }
        }

        fn unpark(self: *Parker) void {
            const thread_id = @intToPtr(windows.PVOID, self.thread_id);

            @atomicStore(State, &self.state, .notified, .Release);

            switch (NtAlertThreadByThreadId(thread_id)) {
                .SUCCESS => {},
                else => |status| {
                    std.debug.warn("NtAlertThreadByThreadId: {}\n", .{status});
                    std.debug.dumpCurrentStackTrace(null);
                },
            } 
        }
    };
};