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

pub const Event = 
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
    const State = extern enum(u32) {
        empty,
        waiting,
        notified,
    };

    state: State,

    pub fn init(self: *Windows) void {
        self.state = .empty;
    }

    pub fn deinit(self: *Windows) void {
        self.* = undefined;
    }

    pub fn wait(self: *Windows) void {
        defer @atomicStore(State, &self.state, .empty, .Monotonic);
        switch (@atomicRmw(State, &self.state, .Xchg, .waiting, .Acquire)) {
            .empty => self.block(),
            .waiting => unreachable, // multiple waiters on the same event
            .notified => {},
        }
    }

    pub fn notify(self: *Windows) void {
        switch (@atomicRmw(State, &self.state, .Xchg, .notified, .Acquire)) {
            .empty => {},
            .waiting => self.unblock(),
            .notified => unreachable, // multiple notifications on the same event
        }
    }

    fn block(self: *Windows) void {
        @setCold(true);
        const handle = getHandle() orelse {
            while (@atomicLoad(State, &self.state, .Acquire) == .waiting)
                sync.spinLoopHint(1);
            return;
        };

        const key = @ptrCast(*align(4) const c_void, &self.state);
        const status = NtWaitForKeyedEvent(handle, key, windows.FALSE, null);
        std.debug.assert(status == .SUCCESS);
    }

    fn unblock(self: *Windows) void {
        @setCold(true);
        const handle = getHandle() orelse return;

        const key = @ptrCast(*align(4) const c_void, &self.state);
        const status = NtReleaseKeyedEvent(handle, key, windows.FALSE, null);
        std.debug.assert(status == .SUCCESS);
    }

    var event_state = EventState.uninit;
    var event_handle: ?windows.HANDLE = undefined;

    const EventState = enum(u8) {
        uninit,
        initing,
        init,
    };

    fn getHandle() ?windows.HANDLE {
        if (@atomicLoad(EventState, &event_state, .Acquire) == .init)
            return event_handle;
        return getHandleSlow();
    }

    fn getHandleSlow() ?windows.HANDLE {
        @setCold(true);

        var state = @atomicLoad(EventState, &event_state, .Acquire);
        while (true) {
            switch (state) {
                .uninit => {
                    state = @cmpxchgWeak(
                        EventState,
                        &event_state,
                        .uninit,
                        .initing,
                        .Acquire,
                        .Acquire,
                    ) orelse break;
                },
                .initing => {
                    windows.kernel32.Sleep(0);
                    state = @atomicLoad(EventState, &event_state, .Acquire);
                },
                .init => {
                    return event_handle;
                }
            }
        }

        const access_mask = windows.GENERIC_READ | windows.GENERIC_WRITE;
        if (NtCreateKeyedEvent(&event_handle, access_mask, null, 0) != .SUCCESS)
            event_handle = null;
        
        @atomicStore(EventState, &event_state, .init, .Release);
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

const Posix = extern struct {
    updated: bool,
    cond: pthread_t,
    mutex: pthread_t,

    pub fn init(self: *Posix) void {
        self.updated = false;
        _ = pthread_cond_init(&self.cond, 0);
        _ = pthread_mutex_init(&self.mutex, 0);
    }

    pub fn deinit(self: *Posix) void {
        _ = pthread_cond_destroy(&self.cond);
        _ = pthread_mutex_destroy(&self.mutex);
    }

    pub fn wait(self: *Posix) void {
        _ = pthread_mutex_lock(&self.mutex);
        defer _ = pthread_mutex_unlock(&self.mutex);

        if (self.updated) {
            self.updated = false;
            return;
        }

        self.updated = true;
        while (self.updated) {
            _ = pthread_cond_wait(&self.cond, &self.mutex);
        }
    }

    pub fn notify(self: *Posix) void {
        const wake = blk: {
            _ = pthread_mutex_lock(&self.mutex);
            defer _ = pthread_mutex_unlock(&self.mutex);
            
            if (self.updated) {
                self.updated = false;
                break :blk true;
            }

            self.updated = true;
            break :blk false;
        };

        if (wake) {
            _ = pthread_cond_signal(&self.cond);
        }
    }

    const pthread_t = extern struct {
        _opaque: [64]u8 align(16),
    };

    extern "c" fn pthread_cond_init(p: *pthread_t, a: usize) callconv(.C) c_int;
    extern "c" fn pthread_cond_destroy(p: *pthread_t) callconv(.C) c_int;
    extern "c" fn pthread_cond_signal(p: *pthread_t) callconv(.C) c_int;
    extern "c" fn pthread_cond_wait(noalias p: *pthread_t, noalias m: *pthread_t) callconv(.C) c_int;

    extern "c" fn pthread_mutex_init(p: *pthread_t, a: usize) callconv(.C) c_int;
    extern "c" fn pthread_mutex_destroy(p: *pthread_t) callconv(.C) c_int;
    extern "c" fn pthread_mutex_lock(p: *pthread_t) callconv(.C) c_int;
    extern "c" fn pthread_mutex_unlock(p: *pthread_t) callconv(.C) c_int;
};