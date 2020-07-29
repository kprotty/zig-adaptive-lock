const std = @import("std");
const linux = std.os.linux;

pub const AutoResetEvent = struct {
    state: State,

    const State = enum(i32) {
        empty,
        waiting,
        notified,
    };

    pub fn init(self: *AutoResetEvent) void {
        self.state = .empty;
    }

    pub fn deinit(self: *AutoResetEvent) void {
        self.* = undefined;
    }

    pub fn set(self: *AutoResetEvent) void {
        if (@cmpxchgStrong(
            State,
            &self.state,
            .empty,
            .notified,
            .Release,
            .Monotonic,
        )) |_| {
            @atomicStore(State, &self.state, .empty, .Release);
            _ = linux.futex_wake(
                @ptrCast(*const i32, &self.state),
                linux.FUTEX_WAKE | linux.FUTEX_PRIVATE_FLAG,
                1,
            );
        }
    }

    pub fn wait(self: *AutoResetEvent) void {
        defer @atomicStore(State, &self.state, .empty, .Monotonic);
        if (@cmpxchgStrong(
            State,
            &self.state,
            .empty,
            .waiting,
            .Acquire,
            .Acquire,
        ) == null) {
            while (true) {
                _ = linux.futex_wait(
                    @ptrCast(*const i32, &self.state),
                    linux.FUTEX_WAIT | linux.FUTEX_PRIVATE_FLAG,
                    @as(i32, @enumToInt(State.waiting)),
                    null,
                );
                if (@atomicLoad(State, &self.state, .Acquire) != .waiting)
                    break;
            }
        }
    }
};