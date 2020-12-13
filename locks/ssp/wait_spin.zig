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

const ssp = @import("./ssp.zig");
const atomic = ssp.atomic;

pub const WaitSpin = struct {
    iter: u3 = 0,

    pub fn reset(self: *WaitSpin) void {
        self.* = WaitSpin{};
    }

    pub fn trySpin(self: *WaitSpin) bool {
        if (self.iter > 4) {
            atomic.spinLoopHint();
            return false;
        }

        self.iter += 1;

        var spin = @as(usize, 1) << self.iter;
        while (spin > 0) : (spin -= 1)
            atomic.spinLoopHint();

        return true;
    }
};