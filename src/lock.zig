const std = @import("std");
const windows = std.os.windows;

pub const Mutex = struct {
    state: u32,

    pub fn init() @This() {
        return @This(){ .state = 0 };
    }

    pub fn deinit(self: *@This()) void {
        self.* = undefined;
    }

    pub const Held = struct {
        mutex: *Mutex,

        pub fn release(self: Held) void {
            return self.mutex.release();
        }
    };

    const WAKE = 1 << 8;
    const WAIT = 1 << 9;

    pub fn acquire(self: *@This()) Held {
        if (@atomicRmw(u8, @ptrCast(*u8, &self.state), .Xchg, 1, .Acquire) != 0)
            self.acquireSlow();
        return Held{ .mutex = self };
    }

    fn acquireSlow(self: *@This()) void {
        @setCold(true);
        const handle = getEventHandle() orelse unreachable;
        while (true) : (std.SpinLock.yield(1)) {
            const state = @atomicLoad(u32, &self.state, .Monotonic);
            if ((state & 1) == 0) {
                if (@atomicRmw(u8, @ptrCast(*u8, &self.state), .Xchg, 1, .Acquire) == 0)
                    return;
            } else if (@cmpxchgWeak(u32, &self.state, state, (state + WAIT) | 1, .Monotonic, .Monotonic) == null) {
                _ = windows.ntdll.NtWaitForKeyedEvent(handle, @ptrCast(*const c_void, &self.state), windows.FALSE, null);
                _ = @atomicRmw(u32, &self.state, .Sub, WAKE, .Monotonic);
            }
        }
    }

    fn release(self: *@This()) void {
        const handle = getEventHandle() orelse unreachable;
        @atomicStore(u8, @ptrCast(*u8, &self.state), 0, .Release);
        while (true) : (std.SpinLock.yield(1)) {
            const state = @atomicLoad(u32, &self.state, .Monotonic);
            if (
                state < WAIT or
                state & 1 != 0 or
                state & WAKE != 0
            ) return;
            if (@cmpxchgWeak(u32, &self.state, state, state - WAIT + WAKE, .Release, .Monotonic) == null) {
                _ = windows.ntdll.NtReleaseKeyedEvent(handle, @ptrCast(*const c_void, &self.state), windows.FALSE, null);
                return;
            }
        }
    }

    var event_handle: usize = EMPTY;
    const EMPTY = ~@as(usize, 0);
    const LOADING = EMPTY - 1;

    fn getEventHandle() ?windows.HANDLE {
        var handle = @atomicLoad(usize, &event_handle, .Monotonic);
        while (true) {
            switch (handle) {
                EMPTY => {
                    handle = @atomicRmw(usize, &event_handle, .Xchg, LOADING, .Monotonic);
                    if (handle == LOADING)
                        continue;
                    const handle_ptr = @ptrCast(*windows.HANDLE, &handle);
                    const access_mask = windows.GENERIC_READ | windows.GENERIC_WRITE;
                    if (windows.ntdll.NtCreateKeyedEvent(handle_ptr, access_mask, null, 0) != 0)
                        handle = 0;
                    @atomicStore(usize, &event_handle, handle, .Monotonic);
                    return @intToPtr(?windows.HANDLE, handle);
                },
                LOADING => {
                    std.SpinLock.yield(400);
                    handle = @atomicLoad(usize, &event_handle, .Monotonic);
                },
                else => {
                    return @intToPtr(?windows.HANDLE, handle);
                },
            }
        }
    }
};