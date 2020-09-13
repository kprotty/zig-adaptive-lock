const std = @import("std");

pub const Mutex = struct {
    pub const NAME = "ticket lock";

    ticket: usize,
    // _cache_line_pad: [256]u8,
    owner: usize,

    pub fn init(self: *Mutex) void {
        self.ticket = 0;
        self.owner = 0;
    }

    pub fn deinit(self: *Mutex) void {
        self.* = undefined;
    }

    pub fn acquire(self: *Mutex) void {
        const ticket = @atomicRmw(
            usize,
            &self.ticket,
            .Add,
            1,
            .Monotonic,
        );
        
        while (true) : (std.SpinLock.loopHint(1)) {
            const owner = @atomicLoad(
                usize,
                &self.owner,
                .Acquire,
            );

            if (owner == ticket) {
                return;
            }
        }
    }

    pub fn release(self: *Mutex) void {
        @atomicStore(
            usize,
            &self.owner,
            self.owner + 1,
            .Release,
        );
    }
};