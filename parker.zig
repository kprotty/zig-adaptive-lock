const std = @import("std");
const builtin = @import("builtin");
const time = std.time;
const linux = std.os.linux;
const windows = std.os.windows;
const assert = std.debug.assert;

usingnamespace @import("./parker/thread.zig");
usingnamespace @import("./parker/async.zig");

pub const Spin = struct {
    extern "kernel32" stdcallcc fn SwitchToThread() windows.BOOL;

    pub fn yieldCpu() void {
        switch (builtin.arch) {
            .i386, .x86_64 => asm volatile ("pause"
                :
                :
                : "memory"
            ),
            .arm, .aarch64 => asm volatile ("yield"),
            else => {},
        }
    }

    pub fn yieldThread() void {
        switch (builtin.os) {
            .windows => _ = SwitchToThread(),
            .linux => _ = linux.syscall0(linux.SYS_sched_yield),
            else => time.sleep((time.ns_per_s / time.us_per_s) * 1),
        }
    }

    pub const Backoff = struct {
        iteration: usize,

        pub fn init() @This() {
            return @This(){ .iteration = 0 };
        }

        pub fn backoff(self: *@This()) void {
            defer self.iteration +%= 1;
            if (self.iteration < 10) {
                yieldCpu();
            } else if (self.iteration < 20) {
                for (([30]void)(undefined)) |_| yieldCpu();
            } else if (self.iteration < 24) {
                yieldThread();
            } else if (self.iteration < 26) {
                time.sleep((time.ns_per_s / time.ms_per_s) * 1);
            } else {
                time.sleep((time.ns_per_s / time.ms_per_s) * 10);
            }
        }
    };
};


