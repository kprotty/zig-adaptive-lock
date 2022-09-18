const std = @import("std");
const os = std.os;
const assert = std.debug.assert;
const Atomic = std.atomic.Atomic;

const builtin = @import("builtin");
const Event = if (builtin.target.os.tag == .windows)
    WindowsEvent
else if (builtin.target.os.tag == .netbsd)
    NetBsdEvent
else
    FutexEvent;

const WindowsEvent = struct {
    tid: Atomic(os.windows.DWORD) = Atomic(os.windows.DWORD).init(0),

    extern "NtDll" fn NtWaitForAlertByThreadId(addr: usize, timeout: ?*const os.windows.LARGE_INTEGER) callconv(os.windows.WINAPI) os.windows.NTSTATUS;
    extern "NtDll" fn NtAlertThreadByThreadId(tid: os.windows.DWORD) callconv(os.windows.WINAPI) os.windows.NTSTATUS;

    fn wait(event: *Event) void {
        @setCold(true);

        // var i: usize = 10;
        // while (i > 0) : (i -= 1) {
        //     if (event.tid.load(.Acquire) == 1) return;
        //     std.atomic.spinLoopHint();
        // }

        const tid = os.windows.kernel32.GetCurrentThreadId();
        assert(tid != 0);

        if (event.tid.swap(tid, .Acquire) == 1) {
            return;
        }

        while (true) {
            _ = NtWaitForAlertByThreadId(0, null);
            if (event.tid.load(.Acquire) == 1) return;
        }
    }

    fn set(event: *Event) void {
        @setCold(true);
        
        const tid = event.tid.swap(1, .Release);
        if (tid != 0) {
            _ = NtAlertThreadByThreadId(tid);
        }
    }
};

// TODO: lwp_self/lwp_park/lwp_unpark
const NetBsdEvent = FutexEvent;

const FutexEvent = struct {
    state: Atomic(u32) = Atomic(u32).init(empty),

    const empty = 0;
    const waiting = 1;
    const notified = 2;

    fn wait(event: *Event) void {
        @setCold(true);

        if (event.state.swap(waiting, .Acquire) == notified) {
            return;
        }

        while (true) {
            std.Thread.Futex.wait(&event.state, waiting);
            if (event.state.load(.Acquire) == notified) return;
        }
    }

    fn set(event: *Event) void {
        @setCold(true);

        if (event.state.swap(notified, .Release) == waiting) {
            std.Thread.Futex.wake(&event.state, 1);
        }
    }
};

pub const Lock = struct {
    state: Atomic(usize) = Atomic(usize).init(unlocked),

    const unlocked = 0;
    const locked_bit = 1 << 0;
    const node_mask = ~@as(usize, locked_bit);

    const Node = struct {
        event: Event,
        next: ?*Node,
    };

    pub const name = "stack_lock";

    pub fn init(self: *Lock) void {
        self.* = .{};
    }

    pub fn deinit(self: *Lock) void {
        self.* = undefined;
    }

    pub fn acquire(self: *Lock) void {
        if (self.acquireFast()) return;
        self.acquireSlow();
    }

    inline fn acquireFast(self: *Lock) bool {
        const locked_bit_index = @ctz(@as(usize, locked_bit));
        return self.state.bitSet(locked_bit_index, .Acquire) == 0;
    }

    fn acquireSlow(self: *Lock) void {
        @setCold(true);

        const spin_bound = 8;
        const backoff_bound = 32;

        var spin: usize = 0;
        var backoff: usize = 0;
        var node: Node = undefined;

        while (true) {
            blk: {
                const state = self.state.load(.Monotonic);
                if (state & locked_bit == 0) {
                    if (self.acquireFast()) return;
                    break :blk;
                }

                const head = @intToPtr(?*Node, state & node_mask);
                if (head == null and spin < spin_bound) {
                    std.atomic.spinLoopHint();
                    spin += 1;
                    continue;
                }

                const new_state = @ptrToInt(&node) | (state & ~node_mask);
                node.event = .{};
                node.next = head;
                
                _ = self.state.tryCompareAndSwap(state, new_state, .Release, .Monotonic) orelse {
                    node.event.wait();
                    backoff = 0;
                    spin = 0;
                    continue;
                };
            }

            backoff = std.math.min(backoff_bound, std.math.max(1, backoff * 2));
            var iter = backoff;
            while (iter > 0) : (iter -= 1) std.atomic.spinLoopHint();
        }
    }

    pub fn release(self: *Lock) void {
        const state = self.state.compareAndSwap(locked_bit, unlocked, .Release, .Monotonic) orelse return;
        self.releaseSlow(state);
    }

    fn releaseSlow(self: *Lock, current_state: usize) void {
        @setCold(true);

        var state = current_state;
        while (true) {
            self.state.fence(.Acquire);
            const node = @intToPtr(*Node, state & node_mask);

            const new_state = @ptrToInt(node.next);
            state = self.state.tryCompareAndSwap(state, new_state, .Release, .Monotonic) orelse {
                return node.event.set();
            };
        }
    }
};