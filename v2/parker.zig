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

pub const OsParker = extern struct {
    inner: Os.Parker,

    pub fn init() OsParker {
        return OsParker{
            .inner = Os.Parker.init(),
        };
    }

    pub fn deinit(self: *OsParker) void {
        self.inner.deinit();
    }

    pub fn prepare(self: *OsParker) void {
        self.inner.prepare();
    }

    pub fn park(self: *OsParker) void {
        self.inner.park();
    }

    pub fn unpark(self: *OsParker) void {
        self.inner.unpark();
    }
};

const Os = switch (std.builtin.os.tag) {
    .linux => switch (std.builtin.link_libc) {
        true => Posix,
        else => Linux,
    },
    .windows => Windows,
    .macosx,
    .watchos,
    .ios,
    .tvos,
    .openbsd,
    .freebsd,
    .kfreebsd,
    .netbsd,
    .dragonfly,
    .minix,
    .haiku,
    .fuchsia,
    .aix,
    .hermit => Posix,
    else => @compileError("OS not supported"),
};

const Windows = struct {
    const windows = std.os.windows;

    pub const Parker = extern struct {
        state: State,
        thread_id: windows.DWORD,

        extern "NtDll" fn NtAlertThreadByThreadId(
            thread_id: windows.PVOID,
        ) callconv(.Stdcall) windows.NTSTATUS;

        extern "NtDll" fn NtWaitForAlertByThreadId(
            thread_id: windows.PVOID,
            timeout: ?*windows.LARGE_INTEGER,
        ) callconv(.Stdcall) windows.NTSTATUS;

        const State = extern enum(usize) {
            empty,
            waiting,
            notified,
        };

        pub fn init() Parker {
            return Parker{
                .state = .empty,
                .thread_id = undefined,
            };
        }

        pub fn deinit(self: *Parker) void {
            self.* = undefined;
        }

        pub fn prepare(self: *Parker) void {
            switch (self.state) {
                .empty => {
                    self.thread_id = windows.kernel32.GetCurrentThreadId();
                    self.state = .waiting;
                },
                .waiting => {},
                .notified => self.state = .waiting,
            }
        }

        pub fn park(self: *Parker) void {
            const thread_id = @intToPtr(windows.PVOID, self.thread_id);

            while (true) {
                switch (@atomicLoad(State, &self.state, .Acquire)) {
                    .empty => unreachable,
                    .waiting => {},
                    .notified => return,
                }

                switch (NtWaitForAlertByThreadId(thread_id, null)) {
                    .SUCCESS => {},
                    .ALERTED => {},
                    .TIMEOUT => {},
                    .USER_APC => {},
                    else => unreachable,
                }
            }
        }

        pub fn unpark(self: *Parker) void {
            const thread_id = @intToPtr(windows.PVOID, self.thread_id);

            @atomicStore(State, &self.state, .notified, .Release);

            switch (NtAlertThreadByThreadId(thread_id)) {
                .SUCCESS => {},
                else => unreachable,
            } 
        }
    };
};

const Windows = struct {
    pub const Parker = extern struct {
        state: State,
        cond: pthread_t,
        mutex: pthread_t,
    
        const State = enum {
            empty,
            waiting,
            notified,
        };

        pub fn init() Parker {
            return Parker{
                .state = .empty,
                .cond = undefined,
                .mutex = undefined,
            };
        }

        pub fn deinit(self: *Parker) void {
            self.* = undefined;
        }

        pub fn prepare(self: *Parker) void {
            switch (self.state) {
                .empty => {
                    self.thread_id = windows.kernel32.GetCurrentThreadId();
                    self.state = .waiting;
                },
                .waiting => {},
                .notified => self.state = .waiting,
            }
        }

        pub fn park(self: *Parker) void {
            const thread_id = @intToPtr(windows.PVOID, self.thread_id);

            while (true) {
                switch (@atomicLoad(State, &self.state, .Acquire)) {
                    .empty => unreachable,
                    .waiting => {},
                    .notified => return,
                }

                switch (NtWaitForAlertByThreadId(thread_id, null)) {
                    .SUCCESS => {},
                    .ALERTED => {},
                    .TIMEOUT => {},
                    .USER_APC => {},
                    else => unreachable,
                }
            }
        }

        pub fn unpark(self: *Parker) void {
            const thread_id = @intToPtr(windows.PVOID, self.thread_id);

            @atomicStore(State, &self.state, .notified, .Release);

            switch (NtAlertThreadByThreadId(thread_id)) {
                .SUCCESS => {},
                else => unreachable,
            } 
        }
    };
};