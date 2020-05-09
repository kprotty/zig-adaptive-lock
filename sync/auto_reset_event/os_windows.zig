const std = @import("std");
const windows = std.os.windows;

const State = enum(u32) {
    Empty,
    Waiting,
    Notified,
};

pub const AutoResetEvent = struct {
    state: State,

    pub fn init(self: *AutoResetEvent) void {
        self.state = .Empty;
    }

    pub fn deinit(self: *AutoResetEvent) void {
        defer self.* = undefined;
        if (std.debug.runtime_safety) {
            if (@atomicLoad(State, &self.state, .Monotonic) == .Waiting)
                std.debug.panic("AutoResetEvent.deinit() with active waiter", .{});
        }
    }

    pub fn set(self: *AutoResetEvent) void {
        var state = @atomicLoad(State, &self.state, .Monotonic);
        if (state == .Empty) {
            state = @cmpxchgWeak(
                State,
                &self.state,
                .Empty,
                .Notified,
                .Release,
                .Monotonic,
            ) orelse return;
        }

        if (state == .Notified)
            return;

        @atomicStore(State, &self.state, .Empty, .Release);
        const status = windows.ntdll.NtReleaseKeyedEvent(
            getEventHandle() orelse return,
            @ptrCast(windows.PVOID, &self.state),
            windows.FALSE,
            null,
        );
        std.debug.assert(status == .SUCCESS);
    }

    pub fn wait(self: *AutoResetEvent) void {
        var state = @atomicLoad(State, &self.state, .Acquire);

        if (state == .Empty) {
            state = @cmpxchgWeak(
                State,
                &self.state,
                .Empty,
                .Waiting,
                .Acquire,
                .Acquire,
            ) orelse {
                const status = windows.ntdll.NtWaitForKeyedEvent(
                    getEventHandle() orelse return,
                    @ptrCast(windows.PVOID, &self.state),
                    windows.FALSE,
                    null,
                );
                std.debug.assert(status == .SUCCESS);
                return;
            };
        }

        @atomicStore(State, &self.state, .Empty, .Monotonic);
    }

    fn getEventHandle() ?windows.HANDLE {
        const Static = struct { var value: ?windows.HANDLE = null; };
        const event_handle = &Static.value;

        if (@atomicLoad(?windows.HANDLE, event_handle, .Acquire)) |handle|
            return handle;
        
        var handle: windows.HANDLE = undefined;
        const access = windows.GENERIC_READ | windows.GENERIC_WRITE;
        if (windows.ntdll.NtCreateKeyedEvent(&handle, access, null, 0) != .SUCCESS)
            return null;

        const new_handle = @cmpxchgWeak(
            ?windows.HANDLE,
            event_handle,
            null,
            handle,
            .Release,
            .Acquire,
        ) orelse return handle;
        windows.CloseHandle(handle);
        return new_handle;
    }
};
