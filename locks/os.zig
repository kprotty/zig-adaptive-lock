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
const sync = @import("../sync/sync.zig");
const spinLoopHint = sync.spinLoopHint;

pub const Lock = struct {
    pub const name = OsLock.name;

    inner: OsLock,

    pub fn init(self: *Lock) void {
        self.inner.init();
    }

    pub fn deinit(self: *Lock) void {
        self.inner.deinit();
    }

    pub fn withLock(self: *Lock, context: anytype) void {
        self.inner.acquire();
        context.run();
        self.inner.release();
    }
};

const OsLock =
    if (std.builtin.os.tag == .windows)
        struct {
            const name = "SRWLOCK";

            srwlock: usize,

            fn init(self: *OsLock) void {
                self.srwlock = 0;
            }

            fn deinit(self: *OsLock) void {
                self.* = undefined;
            }

            fn acquire(self: *OsLock) void {
                AcquireSRWLockExclusive(&self.srwlock);
            }

            fn release(self: *OsLock) void {
                ReleaseSRWLockExclusive(&self.srwlock);
            }

            extern "kernel32" fn AcquireSRWLockExclusive(p: *usize) callconv(.Stdcall) void;
            extern "kernel32" fn ReleaseSRWLockExclusive(p: *usize) callconv(.Stdcall) void;
        }
    else if (std.builtin.link_libc)
        struct {
            const name = "pthread_mutex_t";

            mutex: pthread_t, 

            fn init(self: *OsLock) void {
                _ = pthread_mutex_init(&self.mutex, 0);
            }

            fn deinit(self: *OsLock) void {
                _ = pthread_mutex_destroy(&self.mutex);
            }

            fn acquire(self: *OsLock) void {
                _ = pthread_mutex_lock(&self.mutex);
            }

            fn release(self: *OsLock) void {
                _ = pthread_mutex_unlock(&self.mutex);
            }

            const pthread_t = extern struct {
                _opaque: [64]u8 align(16),
            };

            extern "c" fn pthread_mutex_init(p: *pthread_t, a: usize) callconv(.C) c_int;
            extern "c" fn pthread_mutex_destroy(p: *pthread_t) callconv(.C) c_int;
            extern "c" fn pthread_mutex_lock(p: *pthread_t) callconv(.C) c_int;
            extern "c" fn pthread_mutex_unlock(p: *pthread_t) callconv(.C) c_int;
        }
    else if (std.builtin.os.tag == .linux)
        @compileError("TODO: linux system lock without libc")
    else
        @compileError("OS not supported");
