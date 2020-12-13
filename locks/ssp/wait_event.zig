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

const builtin = @import("builtin");
const ssp = @import("./ssp.zig");
const atomic = ssp.atomic;

pub const WaitEvent = Event;

const Event = 
    if (builtin.os.tag == .windows)
        WindowsEvent
    else if (builtin.link_libc)
        PosixEvent
    else if (builtin.os.tag == .linux)
        LinuxEvent
    else 
        SpinEvent;

const SpinEvent = struct {
    notified: bool,

    fn prepare(self: *Event) void {
        self.notified = false;
    }

    fn wait(self: *Event, deadline: ?u64) bool {
        while (!atomic.load(&self.notified, .acquire))
            atomic.spinLoopHint();
        return true;
    }

    fn notify(self: *Event) void {
        atomic.store(&self.notified, true, .release);
    }

    fn nanotime() u64 {
        return 0;
    }
};

const WindowsEvent = SpinEvent;