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
        WindowsLock
    else if (utils.is_posix)
        PosixLock
    else if (utils.is_linux)
        LinuxLock
    else
        @compileError("OS does not provide a default lock");

const WindowsLock = extern struct {
    pub const name = "SRWLOCK";

    srwlock: std.os.windows.SRWLOCK = std.os.windows.SRWLOCK_INIT,

    pub fn init(self: *Lock) void {
        self.* = Lock{};
    }

    pub fn deinit(self: *Lock) void {
        self.* = undefined;
    }

    pub fn acquire(self: *Lock) void {
        std.os.windows.kernel32.AcquireSRWLockExclusive(&self.srwlock);
    }

    pub fn release(self: *Lock) void {
        std.os.windows.kernel32.ReleaseSRWLockExclusive(&self.srwlock);
    }
};

const PosixLock = extern struct {
    pub const name = "pthread_mutex_t";

    mutex: std.c.pthread_mutex_t,

    pub fn init(self: *Lock) void {
        std.debug.assert(std.c.pthread_mutex_init(&self.mutex, null) == 0);
    }

    pub fn deinit(self: *Lock) void {
        std.debug.assert(std.c.pthread_mutex_destroy(&self.mutex) == 0);
    }

    pub fn acquire(self: *Lock) void {
        std.debug.assert(std.c.pthread_mutex_lock(&self.mutex) == 0);
    }

    pub fn release(self: *Lock) void {
        std.debug.assert(std.c.pthread_mutex_unlock(&self.mutex) == 0);
    }
};

const LinuxLock = extern struct {
    pub const name = "futex";

    state: Atomic(u32) = Atomic(u32).init(0),

    const Atomic = std.atomic.Atomic;
    const Futex = std.Thread.Futex;

    pub fn init(self: *Lock) void {
        self.* = .{};
    }

    pub fn deinit(self: *Lock) void {
        self.* = undefined;
    }

    pub fn acquire(self: *Lock) void {
        if (self.state.tryCompareAndSwap(0, 1, .Acquire, .Monotonic) == null) {
            return;
        }

        while (self.state.swap(2, .Acquire) != 0) {
            Futex.wait(&self.state, 2, null) catch unreachable;
        }
    }

    pub fn release(self: *Lock) void {
        if (self.state.swap(0, .Release) == 2) {
            Futex.wake(&self.state, 1);
        }
    }
};