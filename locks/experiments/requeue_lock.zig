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
        const backoff_bound = 32;
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
        _ = self.state.compareAndSwap(locked_bit, unlocked, .Release, .Monotonic) orelse return;
        self.releaseSlow();
    }

    fn releaseSlow(self: *Lock) void {
        @setCold(true);

        var state = self.state.swap(unlocked, .AcqRel);
        const head = @intToPtr(*Node, state & node_mask);
        var tail = head;

        while (true) {
            tail = tail.tail orelse tail;
            const next = tail.next orelse break;
            next.prev = tail;
            tail = next;
        }

        const new_tail = tail.prev orelse {
            assert(head == tail);
            return tail.event.set();
        };

        state = unlocked;
        while (true) {
            var next_tail = new_tail;
            if (state & locked_bit != 0) {
                next_tail = tail;
            }

            const top = @intToPtr(?*Node, state & node_mask);
            next_tail.next = top;
            next_tail.tail = if (top == null) next_tail else null;

            head.prev = null;
            head.tail = next_tail;

            const new_state = @ptrToInt(head) | (state & ~node_mask);
            state = self.state.tryCompareAndSwap(state, new_state, .Release, .Monotonic) orelse {
                if (next_tail != tail) tail.event.set();
                return;
            };
        }
    }
};