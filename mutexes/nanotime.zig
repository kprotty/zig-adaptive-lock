const std = @import("std");

pub const nanotime = Time.nanotime;

const Time = struct {
    fn nanotime() u64 {
        if (@sizeOf(usize) < @sizeOf(u64))
            return nanotime32();
        return nanotime64();
    }

    var last_time: u64 = 0;
    var last_lock = std.Mutex{};

    fn nanotime32() u64 {
        const now = Os.nanotime();
        if (Os.is_monotonic)
            return now;

        const held = last_lock.acquire();
        defer held.release();

        if (last_time >= now) {
            return last_time;
        } else {
            last_time = now;
            return now;
        }
    }

    fn nanotime64() u64 {
        const now = Os.nanotime();
        if (Os.is_monotonic)
            return now;

        var last = @atomicLoad(u64, &last_time, .Monotonic);
        while (true) {
            if (last >= now)
                return now;
            last = @cmpxchgWeak(
                u64,
                &last_time,
                last,
                now,
                .Monotonic,
                .Monotonic,
            ) orelse return now;
        }
    }

    const Os = 
        if (std.builtin.os.tag == .windows)
            struct {
                pub const is_monotonic = false;

                var freq: u64 = undefined;
                var freq_state: usize = 0;

                fn getFreq() u64 {
                    if (@atomicLoad(usize, &freq_state, .Acquire) == 2)
                        return freq;
                    return getFreqSlow();
                }

                fn getFreqSlow() u64 {
                    const f = std.os.windows.QueryPerformanceFrequency();
                    if (@cmpxchgStrong(usize, &freq_state, 0, 1, .Acquire, .Monotonic) == null) {
                        freq = f;
                        @atomicStore(usize, &freq_state, 2, .Release);
                    }
                    return f;
                }

                fn nanotime() u64 {
                    const c = std.os.windows.QueryPerformanceCounter();
                    return (c *% std.time.ns_per_s) / getFreq();
                }
            }
        else if (std.builtin.os.tag == .linux or std.builtin.link_libc)
            struct {
                pub const is_monotonic = !(std.builtin.os.tag == .linux and (
                    std.builtin.arch == .arm or
                    .arch == .aarch64 or
                    .arch == .s390x
                ));

                fn nanotime() u64 {
                    var ts: std.os.timespec = undefined;
                    std.os.clock_gettime(std.os.CLOCK_MONOTONIC, &ts) catch unreachable;
                    return @intCast(u64, ts.tv_sec) * std.time.ns_per_s + @intCast(u64, ts.tv_nsec);
                }
            }
        else if (std.Target.current.isDarwin())
            struct {
                pub const is_monotonic = true;

                var freq: std.os.darwin.mach_timebase_info_data = undefined;
                var freq_state: usize = 0;

                fn getFreq() std.os.darwin.mach_timebase_info_data {
                    if (@atomicLoad(usize, &freq_state, .Acquire) == 2)
                        return freq;
                    return getFreqSlow();
                }

                fn getFreqSlow() std.os.darwin.mach_timebase_info_data {
                    var f: std.os.darwin.mach_timebase_info_data = undefined;
                    std.os.darwin.mach_timebase_info(&f);
                    if (@cmpxchgStrong(usize, &freq_state, 0, 1, .Acquire, .Monotonic) == null) {
                        freq = f;
                        @atomicStore(usize, &freq_state, 2, .Release);
                    }
                    return f;
                }

                fn nanotime() u64 {
                    const f = getFreq();
                    const c = std.os.darwin.mach_absolute_time();
                    return (c *% f.numer) / f.denom;
                }
            }
        
        else 
            @compileError("timers not supported");
};