// Copyright (c) 2020 kprotty
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// 	http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

const std = @import("std");
const sync = @import("./sync.zig");

const is_posix = switch (std.builtin.os.tag) {
    .linux,
    .minix,
    .macosx,
    .watchos,
    .tvos,
    .ios,
    .solaris,
    .aix,
    .openbsd,
    .kfreebsd,
    .freebsd,
    .netbsd,
    .dragonfly,
    .hermit,
    .haiku,
    .cloudabi,
    .fuchsia => true,
    else => false,
};

pub const Continuation = 
    if (std.builtin.os.tag == .windows)
        Windows
    else if (std.builtin.link_libc and is_posix)
        Posix
    else if (std.builtin.os.tag == .linux)
        Linux
    else
        @compileError("OS not supported");

const Windows = extern struct {
    const windows = std.os.windows;

    is_waiting: bool align(4),

    pub fn init(self: *Windows) void {
        self.* = undefined;
    }

    pub fn deinit(self: *Windows) void {
        self.* = undefined;
    }

    pub fn block(self: *Windows, caller: anytype) void {
        self.is_waiting = true;

        if (!caller.shouldBlock(self)) {
            return;
        }

        const handle = getHandle() orelse {
            while (@atomicLoad(bool, &self.is_waiting, .Acquire))
                sync.spinLoopHint(1);
            return;
        };

        const key = @ptrCast(*align(4) const c_void, &self.is_waiting);
        const status = NtWaitForKeyedEvent(handle, key, windows.FALSE, null);
        std.debug.assert(status == .SUCCESS);
    }

    pub fn unblock(self: *Windows) void {
        const handle = getHandle() orelse {
            @atomicStore(bool, &self.is_waiting, false, .Release);
            return;
        };

        const key = @ptrCast(*align(4) const c_void, &self.is_waiting);
        const status = NtReleaseKeyedEvent(handle, key, windows.FALSE, null);
        std.debug.assert(status == .SUCCESS);
    }

    var event_state = State.uninit;
    var event_handle: ?windows.HANDLE = undefined;

    const State = enum(u8) {
        uninit,
        initing,
        init,
    };

    fn getHandle() ?windows.HANDLE {
        if (@atomicLoad(State, &event_state, .Acquire) == .init)
            return event_handle;
        return getHandleSlow();
    }

    fn getHandleSlow() ?windows.HANDLE {
        @setCold(true);

        var state = @atomicLoad(State, &event_state, .Acquire);
        while (true) {
            switch (state) {
                .uninit => {
                    state = @cmpxchgWeak(
                        State,
                        &event_state,
                        .uninit,
                        .initing,
                        .Acquire,
                        .Acquire,
                    ) orelse break;
                },
                .initing => {
                    windows.kernel32.Sleep(0);
                    state = @atomicLoad(State, &event_state, .Acquire);
                },
                .init => {
                    return event_handle;
                }
            }
        }

        const access_mask = windows.GENERIC_READ | windows.GENERIC_WRITE;
        if (NtCreateKeyedEvent(&event_handle, access_mask, null, 0) != .SUCCESS)
            event_handle = null;
        
        @atomicStore(State, &event_state, .init, .Release);
        return event_handle;
    }

    extern "NtDll" fn NtCreateKeyedEvent(
        KeyedEventHandle: *?windows.HANDLE,
        DesiredAccess: windows.ACCESS_MASK,
        ObjectAttributes: ?windows.PVOID,
        Flags: windows.ULONG,
    ) callconv(.Stdcall) windows.NTSTATUS;

    extern "NtDll" fn NtWaitForKeyedEvent(
        EventHandle: ?windows.HANDLE,
        Key: *align(4) const c_void,
        Alertable: windows.BOOLEAN,
        Timeout: ?*windows.LARGE_INTEGER,
    ) callconv(.Stdcall) windows.NTSTATUS;

    extern "NtDll" fn NtReleaseKeyedEvent(
        EventHandle: ?windows.HANDLE,
        Key: *align(4) const c_void,
        Alertable: windows.BOOLEAN,
        Timeout: ?*windows.LARGE_INTEGER,
    ) callconv(.Stdcall) windows.NTSTATUS;
};