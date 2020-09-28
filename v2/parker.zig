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

const Linux = struct {
    const linux = std.os.linux;

    pub const Parker = extern struct {
        state: State,
        
        const State = extern enum(i32) {
            waiting,
            notified,
        };

        pub fn init() Parker {
            return undefined;
        }

        pub fn deinit(self: *Parker) void {
            self.* = undefined;
        }

        pub fn prepare(self: *Parker) void {
            self.state = .waiting;
        }

        pub fn park(self: *Parker) void {
            while (@atomicLoad(State, &self.state, .Acquire) == .waiting) {
                _ = linux.futex_wait(
                    @ptrCast(*const i32, &self.state),
                    linux.FUTEX_WAIT | linux.FUTEX_PRIVATE_FLAG,
                    @enumToInt(State.waiting),
                    null,
                );
            }
        }

        pub fn unpark(self: *Parker) void {
            @atomicStore(State, &self.state, .notified, .Release);
            _ = linux.futex_wake(
                @ptrCast(*const i32, &self.state),
                linux.FUTEX_WAKE | linux.FUTEX_PRIVATE_FLAG,
                1,
            );
        }
    };
};


const Windows = struct {
    const windows = std.os.windows;

    pub const Parker = extern struct {
        key: i32,

        pub fn init() Parker {
            return undefined;
        }

        pub fn deinit(self: *Parker) void {
            self.* = undefined;
        }

        pub fn prepare(self: *Parker) void {
            self.key = 0;
        }

        pub fn park(self: *Parker) void {
            _ = NtWaitForKeyedEvent(
                null,
                &self.key,
                windows.FALSE,
                null,
            );
        }

        pub fn unpark(self: *Parker) void {
            _ = NtReleaseKeyedEvent(
                null,
                &self.key,
                windows.FALSE,
                null,
            );
        }

        pub extern "NtDll" fn NtWaitForKeyedEvent(
            handle: ?windows.HANDLE,
            key: *const i32,
            alertable: windows.BOOLEAN,
            timeout: ?*const windows.LARGE_INTEGER,
        ) callconv(.Stdcall) windows.NTSTATUS;

        pub extern "NtDll" fn NtReleaseKeyedEvent(
            handle: ?windows.HANDLE,
            key: *const i32,
            alertable: windows.BOOLEAN,
            timeout: ?*const windows.LARGE_INTEGER,
        ) callconv(.Stdcall) windows.NTSTATUS;
    };
};

const Posix = struct {
    const pthread_t = extern struct {
        _opaque: [64]u8 align(16),
    };

    extern "c" fn pthread_cond_init(p: *pthread_t, a: usize) callconv(.C) c_int;
    extern "c" fn pthread_cond_destroy(p: *pthread_t) callconv(.C) c_int;
    extern "c" fn pthread_cond_wait(noalias p: *pthread_t, noalias m: *pthread_t) callconv(.C) c_int;
    extern "c" fn pthread_cond_signal(p: *pthread_t) callconv(.C) c_int;

    extern "c" fn pthread_mutex_init(p: *pthread_t, a: usize) callconv(.C) c_int;
    extern "c" fn pthread_mutex_destroy(p: *pthread_t) callconv(.C) c_int;
    extern "c" fn pthread_mutex_lock(p: *pthread_t) callconv(.C) c_int;
    extern "c" fn pthread_mutex_unlock(p: *pthread_t) callconv(.C) c_int;

    pub const Parker = extern struct {
        state: State,
        cond: pthread_t,
        mutex: pthread_t,
    
        const State = extern enum {
            empty,
            waiting,
            sleeping,
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
            if (self.state != .empty) {
                _ = pthread_cond_destroy(&self.cond);
                _ = pthread_mutex_destroy(&self.mutex);
            }
        }

        pub fn prepare(self: *Parker) void {
            switch (self.state) {
                .empty => {
                    _ = pthread_cond_init(&self.cond, 0);
                    _ = pthread_mutex_init(&self.mutex, 0);
                    self.state = .waiting;
                },
                .waiting => {},
                .sleeping => self.state = .waiting,
                .notified => self.state = .waiting,
            }
        }

        pub fn park(self: *Parker) void {
            _ = pthread_mutex_lock(&self.mutex);
            defer _ = pthread_mutex_unlock(&self.mutex);

            if (self.state == .waiting)
                self.state = .sleeping;

            while (self.state != .notified)
                _ = pthread_cond_wait(&self.cond, &self.mutex);
        }

        pub fn unpark(self: *Parker) void {
            _ = pthread_mutex_lock(&self.mutex);
            defer _ = pthread_mutex_unlock(&self.mutex);

            
            switch (self.state) {
                .empty => @panic("state is empty"),
                .waiting => self.state = .notified,
                .sleeping => {
                    self.state = .notified;
                    _ = pthread_cond_signal(&self.cond);
                },
                .notified => {},
            }
        }
    };
};