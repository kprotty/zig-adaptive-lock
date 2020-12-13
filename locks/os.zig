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
const utils = @import("../utils.zig");

pub const Lock = 
    if (utils.is_windows)
        extern struct {
            pub const name = "SRWLOCK";

            srwlock: SRWLOCK = SRWLOCK_INIT,

            pub fn init(self: *Lock) void {
                self.* = Lock{};
            }

            pub fn deinit(self: *Lock) void {
                self.* = undefined;
            }

            pub fn acquire(self: *Lock) void {
                AcquireSRWLockExclusive(&self.srwlock);
            }

            pub fn release(self: *Lock) void {
                ReleaseSRWLockExclusive(&self.srwlock);
            }

            const SRWLOCK = usize;
            const PSRWLOCK = *SRWLOCK;
            const SRWLOCK_INIT: SRWLOCK = 0;

            extern "kernel32" fn AcquireSRWLockExclusive(p: PSRWLOCK) callconv(std.os.windows.WINAPI) void;
            extern "kernel32" fn ReleaseSRWLockExclusive(p: PSRWLOCK) callconv(std.os.windows.WINAPI) void;
        }
    else if (utils.is_posix)
        extern struct {
            pub const name = "pthread_mutex_t";

            mutex: pthread_mutex_t,

            pub fn init(self: *Lock) void {
                std.debug.assert(pthread_mutex_init(&self.mutex, null) == 0);
            }

            pub fn deinit(self: *Lock) void {
                std.debug.assert(pthread_mutex_destroy(&self.mutex) == 0);
            }

            pub fn acquire(self: *Lock) void {
                std.debug.assert(pthread_mutex_lock(&self.mutex) == 0);
            }

            pub fn release(self: *Lock) void {
                std.debug.assert(pthread_mutex_unlock(&self.mutex) == 0);
            }

            const pthread_mutex_t = pthread_t;
            const pthread_mutexattr_t = pthread_t;
            const pthread_t = extern struct {
                _opaque: [64]u8 align(16),
            };

            extern "c" fn pthread_mutex_init(p: *pthread_mutex_t, attr: ?*const pthread_mutexattr_t) callconv(.C) c_int;
            extern "c" fn pthread_mutex_destroy(p: *pthread_mutex_t) callconv(.C) c_int;
            extern "c" fn pthread_mutex_lock(p: *pthread_mutex_t) callconv(.C) c_int;
            extern "c" fn pthread_mutex_unlock(p: *pthread_mutex_t) callconv(.C) c_int;
        }
    else if (utils.is_linux)
        extern struct {
            pub const name = "futex";

            const futex = @import("./futex.zig");
            const InnerLock = futex.FutexLock(futex.LinuxFutex);

            inner: InnerLock,

            pub fn init(self: *Lock) void {
                self.inner.init();
            }

            pub fn deinit(self: *Lock) void {
                self.inner.deinit();
            }

            pub fn acquire(self: *Lock) void {
                self.inner.acquire();
            }

            pub fn release(self: *Lock) void {
                self.inner.release();
            }
        }
    else
        @compileError("OS does not provide a default lock");
