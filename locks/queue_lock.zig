const std = @import("std");
const os = std.os;
const assert = std.debug.assert;
const Atomic = std.atomic.Atomic;

const builtin = @import("builtin");
const Event = if (builtin.target.os.tag == .windows)
    WindowsEvent
else if (builtin.taregt.os.tag == .netbsd)
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
    const queue_bit = 1 << 1;
    const pending_bit = 1 << 2;
    const node_mask = ~@as(usize, locked_bit | queue_bit | pending_bit);

    const Node = struct {
        event: Event align(~node_mask + 1),
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

        var spin: usize = 0;
        var backoff: usize = 0;
        var node: Node = undefined;
        var state = self.state.load(.Monotonic);

        while (true) {
            while (state & locked_bit == 0) {
                if (self.acquireFast()) return;
                backoff = std.math.min(backoff_bound, std.math.max(1, backoff * 2));

                var i = backoff;
                while (i > 0) : (i -= 1) std.atomic.spinLoopHint();
                state = self.state.load(.Monotonic);
            }

            if (state & pending_bit == 0 and spin < spin_bound) {
                spin += 1;
                std.atomic.spinLoopHint();
                state = self.state.load(.Monotonic);
                continue;
            }

            node.event = .{};
            node.prev = null;
            node.next = @intToPtr(?*Node, state & node_mask);
            node.tail = &node;
            
            var new_state = @ptrToInt(&node) | (state & ~node_mask) | pending_bit;
            if (node.next != null) {
                node.tail = null;
                new_state |= queue_bit;
            }

            state = self.state.tryCompareAndSwap(state, new_state, .Release, .Monotonic) orelse blk: {
                if ((state & queue_bit == 0) and (new_state & queue_bit != 0)) {
                    self.linkQueueOrUnblock(new_state);
                }

                spin = 0;
                backoff = 0;
                node.event.wait();
                break :blk self.state.load(.Monotonic);
            };
        }
    }

    fn linkQueueOrUnblock(self: *Lock, current_state: usize) void {
        var state = current_state;
        while (true) {
            assert(state & queue_bit != 0);
            assert(state & pending_bit != 0);

            if (state & locked_bit == 0) {
                return self.dequeueAndUnblock(state);
            }
            
            _ = self.getAndLinkQueue(state);
            state = self.state.tryCompareAndSwap(state, state - queue_bit, .Release, .Monotonic) orelse return;
        }
    }

    const Queue = struct {
        head: *Node,
        tail: *Node,
    };

    fn getAndLinkQueue(self: *Lock, state: usize) Queue {
        assert(state & queue_bit != 0);
        assert(state & pending_bit != 0);
        assert(state & node_mask != 0);
        self.state.fence(.Acquire);

        var queue: Queue = undefined;
        queue.head = @intToPtr(*Node, state & node_mask);
        queue.tail = queue.head.tail orelse blk: {
            var current = queue.head;
            while (true) {
                const next = current.next orelse unreachable;
                next.prev = current;
                current = next;

                if (current.tail) |tail| {
                    queue.head.tail = tail;
                    break :blk tail;
                }
            }
        };

        return queue;
    }

    pub fn release(self: *Lock) void {
        const state = self.state.fetchSub(locked_bit, .Release);
        assert(state & locked_bit != 0);

        if (state & (queue_bit | pending_bit) == pending_bit) {
            self.releaseSlow();
        }
    }

    fn releaseSlow(self: *Lock) void {
        @setCold(true);

        var state = self.state.load(.Monotonic);
        while (state & (locked_bit | queue_bit | pending_bit) == pending_bit) {
            const new_state = state | queue_bit;
            state = self.state.tryCompareAndSwap(state, new_state, .Acquire, .Monotonic) orelse {
                return self.dequeueAndUnblock(new_state);
            };
        }
    }

    fn dequeueAndUnblock(self: *Lock, current_state: usize) void {
        var state = current_state;
        while (true) {
            while (state & locked_bit != 0) {
                state = self.state.tryCompareAndSwap(state, state - queue_bit, .Release, .Monotonic) orelse return;
            }

            const queue = self.getAndLinkQueue(state);

            if (queue.tail.prev) |new_tail| {
                queue.head.tail = new_tail;
                _ = self.state.fetchSub(queue_bit, .Release);
                return queue.tail.event.set();
            }

            const new_state = state & ~(node_mask | queue_bit | pending_bit);
            state = self.state.tryCompareAndSwap(state, new_state, .Release, .Monotonic) orelse {
                return queue.tail.event.set();
            };
        }
    }
};