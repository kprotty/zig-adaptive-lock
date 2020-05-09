const std = @import("std");

pub const supports_pthread = switch (std.builtin.os.tag) {
    .macosx,
    .tvos,
    .watchos,
    .ios,
    .freebsd,
    .kfreebsd,
    .netbsd,
    .openbsd,
    .dragonfly,
    .solaris,
    .minix,
    .linux => true,
    else => false,
};

const RawAutoResetEvent = 
    if (std.builtin.os.tag == .windows)
        @import("./os_windows.zig").AutoResetEvent
    else if (std.builtin.os.tag == .linux)
        @import("./os_linux.zig").AutoResetEvent
    else if (std.builtin.link_libc and supports_pthread)
        @import("./os_posix.zig").AutoResetEvent
    else
        @import("./os_none.zig").AutoResetEvent;

pub const OsAutoResetEvent = struct {
    raw: RawAutoResetEvent,

    pub fn init(self: *OsAutoResetEvent) void {
        self.raw.init();
    }

    pub fn deinit(self: *OsAutoResetEvent) void {
        self.raw.deinit();
    }

    pub fn wait(self: *OsAutoResetEvent) void {
        self.raw.wait();
    }

    pub fn set(self: *OsAutoResetEvent) void {
        self.raw.set();
    }

    pub fn yield(contended: bool, iteration: usize) bool {
        if (!(contended and iteration < 15))
            return false;

        var i = @as(usize, 1) << @intCast(u4, iteration);
        while (i != 0) : (i -= 1) {
            switch (std.builtin.arch) {
                .i386, .x86_64 => asm volatile("pause" ::: "memory"),
                .arm, .aarch64 => asm volatile("yield" ::: "memory"),
                else => {},
            }
        }
        return true;
    }
};
