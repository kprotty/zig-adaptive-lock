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
const Atomic = std.atomic.Atomic;
const utils = @import("../utils.zig");

pub const Lock = 
    if (utils.is_windows)
        WindowsLock
    else if (utils.is_darwin)
        DarwinLock
    else
        void;

const DarwinLock = extern struct {
    pub const name = "os_unfair_lock";

    oul: std.os.darwin.os_unfair_lock,

    pub fn init(self: *Lock) void {
        self.oul = std.os.darwin.OS_UNFAIR_LOCK_INIT;
    }

    pub fn deinit(self: *Lock) void {
        self.* = undefined;
    }

    pub fn acquire(self: *Lock) void {
        std.os.darwin.os_unfair_lock_lock(&self.oul);
    }

    pub fn release(self: *Lock) void {
        std.os.darwin.os_unfair_lock_unlock(&self.oul);
    }
};

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