const std = @import("std");

pub const Lock = extern struct {
    pub const name = "mcs spin";

    const Node = extern struct {
        next: std.atomic.Value(?*Node) = .{ .raw = null },
        ready: std.atomic.Value(bool) = .{ .raw = false },
    };

    tail: std.atomic.Value(?*Node) = .{ .raw = null },

    pub fn init(self: *Lock) void {
        self.* = .{};
    }

    pub fn deinit(self: *Lock) void {
        self.* = undefined;
    }

    threadlocal var tls_node: Node = undefined;

    pub fn acquire(self: *Lock) void {
        const node = &tls_node;
        node.* = .{};
        if (self.tail.swap(node, .acq_rel)) |prev| {
            @branchHint(.unlikely);
            prev.next.store(node, .release);
            while (!node.ready.load(.acquire)) std.atomic.spinLoopHint();
        }
    }

    pub fn release(self: *Lock) void {
        const node = &tls_node;
        _ = self.tail.cmpxchgStrong(node, null, .release, .monotonic) orelse {
            @branchHint(.likely);
            return;
        };

        const next = while (true) : (std.atomic.spinLoopHint()) {
            break node.next.load(.acquire) orelse continue;
        };

        next.ready.store(true, .release);
    }
};

