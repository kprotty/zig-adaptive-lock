const std = @import("std");
const windows = std.os.windows;

const SPIN = 40;
const IS_FAIR = true;

pub const NewMutex = struct {
    state: usize,

    const MUTEX_LOCK: usize = 1 << 0;
    const QUEUE_LOCK: usize = 1 << 1;
    const QUEUE_MASK: usize = ~(MUTEX_LOCK | QUEUE_LOCK);

    const Node = struct {
        prev: ?*Node,
        next: ?*Node,
        tail: ?*Node,
        event: std.ResetEvent,
    };

    pub fn init() @This() {
        return @This(){ .state = 0 };
    }

    pub fn deinit(self: *@This()) void {
        self.* = undefined;
    }

    pub const Held = struct {
        mutex: *NewMutex,

        pub fn release(self: Held) void {
            const state = @atomicRmw(usize, &self.mutex.state, .Sub, MUTEX_LOCK, .Release);
            if ((state & QUEUE_LOCK == 0) and (state & QUEUE_MASK != 0))
                self.mutex.releaseSlow(IS_FAIR);
        }
    };

    fn releaseSlow(self: *@This(), comptime is_fair: bool) void {
        @setCold(true);

        var state = @atomicLoad(usize, &self.state, .Monotonic);
        while (true) {
            if ((state & QUEUE_LOCK != 0) or (state & QUEUE_MASK == 0))
                return;
            state = @cmpxchgWeak(usize, &self.state, state, state | QUEUE_LOCK, .Acquire, .Monotonic) orelse break;
        }
        
        outer: while (true) {
            const wake_node = node: {
                if (!is_fair) {
                    if (state & MUTEX_LOCK != 0) {
                        state = @cmpxchgWeak(usize, &self.state, state, state & ~QUEUE_LOCK, .Release, .Acquire) orelse return;
                        continue;
                    } else {
                        const head = @intToPtr(*Node, state & QUEUE_MASK);
                        const new_state = @ptrToInt(head.next);
                        state = @cmpxchgWeak(usize, &self.state, state, new_state, .Release, .Acquire) orelse break :node head;
                        continue;
                    }

                } else {
                    const head = @intToPtr(*Node, state & QUEUE_MASK);
                    var current = head;
                    while (current.tail == null) {
                        const next = current.next.?;
                        next.prev = current;
                        current = next;
                    }
                    const tail = current.tail.?;
                    head.tail = tail;

                    if (state & MUTEX_LOCK != 0) {
                        state = @cmpxchgWeak(usize, &self.state, state, state & ~QUEUE_LOCK, .Release, .Acquire) orelse return;
                        continue;
                    }

                    if (tail.prev) |prev| {
                        head.tail = prev;
                        _ = @atomicRmw(usize, &self.state, .And, ~QUEUE_LOCK, .Release);
                    } else {
                        while (true) {
                            state = @cmpxchgWeak(usize, &self.state, state, state & MUTEX_LOCK, .Release, .Acquire) orelse break;
                            if (state & QUEUE_MASK == 0) continue;
                            continue :outer;
                        }
                    }
                    break :node tail;
                }
            };

            wake_node.event.set();
            return;
        }
    }

    pub fn acquire(self: *@This()) Held {
        if (@cmpxchgStrong(usize, &self.state, 0, MUTEX_LOCK, .Acquire, .Monotonic) != null)
            self.acquireSlow();
        return Held{ .mutex = self };
    }

    fn acquireSlow(self: *@This()) void {
        @setCold(true);

        var spin: usize = SPIN;
        var state = @atomicLoad(usize, &self.state, .Monotonic);
        while (spin != 0) : (spin -= 1) {
            if (state & MUTEX_LOCK == 0) {
                state = @cmpxchgWeak(usize, &self.state, state, state | MUTEX_LOCK, .Acquire, .Monotonic) orelse return;
            } else if (state & QUEUE_MASK == 0) {
                std.SpinLock.loopHint(1);
                state = @atomicLoad(usize, &self.state, .Monotonic);
            } else {
                break;
            }
        }

        var node = Node{
            .prev = null,
            .next = null,
            .tail = null,
            .event = std.ResetEvent.init(),
        };
        defer node.event.deinit();

        while (true) {
            if (state & MUTEX_LOCK == 0) {
                state = @cmpxchgWeak(usize, &self.state, state, state | MUTEX_LOCK, .Acquire, .Monotonic) orelse return;
            } else if (state & QUEUE_MASK == 0 and spin != 0) {
                spin -= 1;
                std.SpinLock.loopHint(1);
                state = @atomicLoad(usize, &self.state, .Monotonic);
            } else {
                if (@intToPtr(?*Node, state & QUEUE_MASK)) |head| {
                    node.tail = null;
                    node.next = head;
                } else {
                    node.tail = &node;
                    node.next = null;
                }

                const new_state = @ptrToInt(&node) | (state & ~QUEUE_MASK);
                if (@cmpxchgWeak(usize, &self.state, state, new_state, .Release, .Monotonic)) |s| {
                    state = s;
                    continue;
                }

                node.event.wait();
                node.prev = null;
                node.next = null;
                node.tail = null;
                node.event.reset();
                spin = SPIN;
                state = @atomicLoad(usize, &self.state, .Monotonic);
            }
        }        
    }
};

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

pub const SrwLock = struct {
    data: [2]usize,

    pub fn init() @This() {
        return @This(){ .data = .{0, 0} };
    }

    pub fn deinit(self: *@This()) void {
        self.* = undefined;
    }

    pub fn acquire(self: *@This()) Held {
        AcquireSRWLockExclusive(@ptrToInt(self));
        return Held{ .mutex = self };
    }

    pub const Held = struct {
        mutex: *SrwLock,

        pub fn release(self: Held) void {
            ReleaseSRWLockExclusive(@ptrToInt(self.mutex));
        }
    };

    extern "kernel32" stdcallcc fn AcquireSRWLockExclusive(ptr: usize) void;
    extern "kernel32" stdcallcc fn ReleaseSRWLockExclusive(ptr: usize) void;
};