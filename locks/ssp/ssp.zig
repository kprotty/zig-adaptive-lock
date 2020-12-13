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

// SSP: Slim Synchronization Primitives

pub const atomic = @import("./atomic.zig");
pub const WaitSpin = @import("./wait_spin.zig").WaitSpin;
pub const WaitEvent = @import("./wait_event.zig").WaitEvent;
pub const WaitQueue = @import("./wait_queue.zig").WaitQueue;

pub const Mutex = @import("./mutex.zig").Mutex;
