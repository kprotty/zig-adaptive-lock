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
    const dequeue_bit = 1 << 1;
    const node_mask = ~@as(usize, locked_bit | dequeue_bit);

    const Node = struct {
        event: Event,
        prev: ?*Node,
        next: ?*Node,
        tail: ?*Node,
    };

    pub const name = "queue_lock";

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

        const spin_bound = 100;
        const backoff_bound = 1024;
        const node_alignment = comptime @intCast(u29, std.math.max(@alignOf(Node), ~node_mask + 1));

        var spin: usize = 0;
        var backoff: usize = 0;
        var state = self.state.load(.Monotonic);
        var node: Node align(node_alignment) = undefined;
        
        while (true) {
            while (state & locked_bit == 0) {
                if (self.acquireFast()) return;
                defer state = self.state.load(.Monotonic);

                backoff = std.math.min(backoff_bound, std.math.max(1, backoff * 2));
                for (@as([backoff_bound]u0, undefined)) |_| {
                    std.atomic.spinLoopHint();
                }
            }

            const head = @intToPtr(?*Node, state & node_mask);
            if (head == null and spin < spin_bound) {
                spin += 1;
                std.atomic.spinLoopHint();
                state = self.state.load(.Monotonic);
                continue;
            }

            node.event = .{};
            node.prev = null;
            node.next = head;
            node.tail = if (head == null) @ptrCast(*Node, &node) else null;
            
            const new_state = @ptrToInt(&node) | (state & ~node_mask);
            state = self.state.tryCompareAndSwap(state, new_state, .Release, .Monotonic) orelse blk: {
                spin = 0;
                backoff = 0;
                node.event.wait();
                break :blk self.state.load(.Monotonic);
            };
        }
    }

    pub fn release(self: *Lock) void {
        const state = self.state.fetchSub(locked_bit, .Release);
        assert(state & locked_bit != 0);

        if (state & node_mask != 0) {
            self.releaseSlow();
        }
    }

    fn releaseSlow(self: *Lock) void {
        @setCold(true);

        var state = self.state.load(.Monotonic);
        while (true) {
            if (state & node_mask == 0) return;
            if (state & (locked_bit | dequeue_bit) != 0) return;
            state = self.state.tryCompareAndSwap(state, state | dequeue_bit, .Acquire, .Monotonic) orelse break;
        }

        state |= dequeue_bit;
        while (true) {
            while (state & locked_bit != 0) {
                state = self.state.tryCompareAndSwap(state, state - dequeue_bit, .Release, .Monotonic) orelse return;
            }

            self.state.fence(.Acquire);
            const head = @intToPtr(*Node, state & node_mask);
            const tail = head.tail orelse blk: {
                var current = head;
                while (true) {
                    const next = current.next orelse unreachable;
                    next.prev = current;
                    current = next;

                    const tail = current.tail orelse continue;
                    head.tail = tail;
                    break :blk tail;
                }
            };

            if (tail.prev) |new_tail| {
                head.tail = new_tail;
                _ = self.state.fetchSub(dequeue_bit, .Release);
                return tail.event.set();
            }

            state = self.state.tryCompareAndSwap(state, unlocked, .Release, .Monotonic) orelse {
                return tail.event.set();
            };
        }
    }
};