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
    else
        void;

const WindowsLock = extern struct {
    pub const name = "CRITICAL_SECTION";

    cs: std.os.windows.CRITICAL_SECTION,

    pub fn init(self: *Lock) void {
        std.os.windows.kernel32.InitializeCriticalSection(&self.cs);
    }

    pub fn deinit(self: *Lock) void {
        std.os.windows.kernel32.DeleteCriticalSection(&self.cs);
    }

    pub fn acquire(self: *Lock) void {
        std.os.windows.kernel32.EnterCriticalSection(&self.cs);
    }

    pub fn release(self: *Lock) void {
        std.os.windows.kernel32.LeaveCriticalSection(&self.cs);
    }
};

const PosixLock = extern struct {
    pub const name = "pthread_mutex_t";

    mutex: std.c.pthread_mutex_t,

    pub fn init(self: *Lock) void {
        self.mutex = .{};
    }

    pub fn deinit(self: *Lock) void {
        _ = std.c.pthread_mutex_destroy(&self.mutex);
    }

    pub fn acquire(self: *Lock) void {
        std.debug.assert(std.c.pthread_mutex_lock(&self.mutex) == 0);
    }

    pub fn release(self: *Lock) void {
        std.debug.assert(std.c.pthread_mutex_unlock(&self.mutex) == 0);
    }
};
