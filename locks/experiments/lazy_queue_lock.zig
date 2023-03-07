const std = @import("std");
const assert = std.debug.assert;
const Atomic = std.atomic.Atomic;

const Event = struct {
    is_set: Atomic(u32) = Atomic(u32).init(0),

    fn wait(event: *const Event) void {
        while (event.is_set.load(.Acquire) == 0) 
            std.Thread.Futex.wait(&event.is_set, 0);
    }

    fn set(event: *Event) void {
        event.is_set.store(1, .Release);
        std.Thread.Futex.wake(&event.is_set, 1);
    }
};

const Link = struct {
    fn get(link: anytype) @TypeOf(link.*.?) {
        if (@atomicLoad(@TypeOf(link.*), link, .Acquire)) |value| return value;

        var event = Event{};
        if (@atomicRmw(@TypeOf(link.*), link, .Xchg, @intToPtr(@TypeOf(link.*), @ptrToInt(&event)), .Release)) |value| {
            @ptrCast(*Atomic(@TypeOf(link.*)), link).fence(.Acquire);
            return value;
        }

        event.wait();
        return link.* orelse unreachable;
    }

    fn set(link: anytype, value: @TypeOf(link.*.?)) void {
        if (@atomicRmw(@TypeOf(link.*), link, .Xchg, value, .Release)) |ptr| {
            @ptrCast(*Atomic(@TypeOf(link.*)), link).fence(.Acquire);
            @ptrCast(*Event, ptr).set();
        }
    }
};

pub const Lock = struct {
    state: Atomic(?*Waiter) = Atomic(?*Waiter).init(null),

    const locked = @intToPtr(*Waiter, @alignOf(Waiter));
    const Waiter = struct {
        head: ?*Waiter = null,
        tail: ?*Waiter = null,
        next: ?*Waiter = null,
        prev: ?*Waiter = null,
        event: Event = .{},
    };

    pub const name = "lazy_qlock";

    pub fn init(self: *Lock) void {
        self.* = .{};
    }

    pub fn deinit(self: *Lock) void {
        self.* = undefined;
    }

    pub fn acquire(self: *Lock) void {
        _ = self.state.tryCompareAndSwap(null, locked, .Acquire, .Monotonic) orelse return;
        self.acquireSlow();
    }

    fn acquireSlow(self: *Lock) void {
        @setCold(true);

        var spin: u32 = 32;
        while (spin > 0) : (spin -= 1) {
            var state = self.state.load(.Monotonic);
            if (state == null) state = self.state.compareAndSwap(null, locked, .Acquire, .Monotonic) orelse return;
            if (state != locked) break;
            
            switch (spin) {
                0 => std.Thread.yield() catch {},
                else => std.atomic.spinLoopHint(),
            }
        }

        var waiter = Waiter{};
        while (true) {
            const head = &waiter;
            assert(head.prev == null);

            var tail = waiter.tail orelse &waiter;
            assert(tail.next == null);

            if (self.state.swap(tail, .Release)) |prev| {
                Link.set(&head.prev, prev);
                waiter.event.wait();
                waiter.event = Event{};
                continue;
            }

            if (head == tail) {
                const state = self.state.compareAndSwap(tail, locked, .Acquire, .Acquire) orelse return;
                tail = state orelse unreachable;
                head.prev = locked;

                assert(find_head(tail) == head);
                assert(tail.next == null);
                assert(head.prev == locked);
            }

            const next = head.next orelse unreachable;
            assert(next.prev == head);
            next.prev = locked;

            assert(tail.head == head);
            tail.head = next;
            return;
        }
    }

    pub fn release(self: *Lock) void {
        const state = self.state.swap(null, .Release) orelse unreachable;
        if (state != locked) self.releaseSlow(state);
    }

    fn releaseSlow(self: *Lock, tail: *Waiter) void {
        @setCold(true);

        self.state.fence(.Acquire);
        assert(tail.next == null);

        const head = find_head(tail);
        assert(head.prev == locked);

        head.tail = tail;
        head.prev = null;
        head.event.set();
    }

    fn find_head(tail: *Waiter) *Waiter {
        assert(tail.next == null);
        var current = tail;
        while (true) {
            current = current.head orelse current;

            const prev = Link.get(&current.prev);
            if (prev == locked) {
                tail.head = current;
                return current;
            }

            assert(prev.next == null);
            prev.next = current;
            current = prev;
        }
    }
};