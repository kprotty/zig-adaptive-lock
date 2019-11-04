const std = @import("std");
const builtin = @import("builtin");
const parker = @import("../parker.zig");
const assert = std.debug.assert;

/// Asynchronous resumer backed by wait-free queue
/// https://gist.github.com/jeehoonkang/7064e13a43b77354163a391c7e4254d6
/// http://www.1024cores.net/home/lock-free-algorithms/queues/intrusive-mpsc-node-based-queue
pub const AsyncParker = struct {
    waiters: ResumeNode.Queue,

    pub fn init() @This() {
        return @This(){
            .waiters = ResumeNode.Queue{
                .head = null,
                .tail = null,
                .stub = ResumeNode{
                    .next = null,
                    .frame = undefined,
                },
            },
        };
    }

    pub fn deinit(self: *@This()) void {
        while (self.waiters.pop()) |waiter|
            resume waiter.frame;
    }

    pub fn wake(self: *@This(), ptr: *const u32) void {
        // TODO: intercept with std.event.Loop to ensure scheduler fairness
        if (self.waiters.pop()) |waiter|
            resume waiter.frame;
    }

    pub fn park(self: *@This(), ptr: *const u32, expected: u32) void {
        suspend {
            var node = ResumeNode{ .frame = @frame() };
            if (@atomicLoad(u32, ptr, .Acquire) == expected)
                resume @frame();
            self.waiters.push(&node);
        }
    }

    const ResumeNode = struct {
        next: ?*ResumeNode = null,
        frame: anyframe,

        pub const Queue = struct {
            head: ?*ResumeNode,
            tail: ?*ResumeNode,
            stub: ResumeNode,

            // TODO: @atomicStore() https://github.com/ziglang/zig/issues/2995
            inline fn atomicStore(ptr: var, node: *ResumeNode, comptime order: builtin.AtomicOrder) void {
                _ = @atomicRmw(@typeOf(ptr.*), ptr, .Xchg, node, order);
            }

            /// Push a node onto the queue.
            /// Can be called by multiple producer threads.
            pub fn push(self: *@This(), node: *ResumeNode) void {
                node.next = null;
                self.ensureInitialized();
                const prev = @atomicRmw(?*ResumeNode, &self.head, .Xchg, node, .AcqRel);
                // * thread can be suspended here causing a pop() to be inconsistent
                atomicStore(&prev.?.next, node, .Release);
            }

            /// Pop a node from the queue.
            /// Can only be called by the consumer thread.
            pub fn pop(self: *@This()) ?*ResumeNode {
                self.ensureInitialized();
                var tail = self.tail.?;
                var next = @atomicLoad(?*ResumeNode, &tail.next, .Acquire);
                if (tail == &self.stub) {
                    tail = next orelse return null;
                    self.tail = tail;
                    next = @atomicLoad(?*ResumeNode, &tail.next, .Acquire);
                }
                if (next != null) {
                    self.tail = next;
                    return tail;
                }
                const head = @atomicLoad(?*ResumeNode, &self.head, .Acquire);
                if (head != tail)
                    return null; // incosistent. pop() again when producer made progress at *
                self.push(&self.stub);
                next = @atomicLoad(?*ResumeNode, &tail.next, .Acquire);
                self.tail = next orelse return null;
                return tail;
            }

            fn ensureInitialized(self: *@This()) void {
                // guard the bottom code until self.head pointer is set
                const ptr = @ptrCast(*usize, &self.head);
                if (@atomicLoad(usize, ptr, .Monotonic) > 1)
                    return;
                if (@cmpxchgStrong(usize, ptr, 0, 1, .Acquire, .Monotonic) != null) {
                    while (@atomicLoad(usize, ptr, .Monotonic) == 1)
                        parker.Spin.yieldCpu();
                    return;
                }
                self.tail = &self.stub;
                atomicStore(&self.head, &self.stub, .Release);
            }
        };
    };
};