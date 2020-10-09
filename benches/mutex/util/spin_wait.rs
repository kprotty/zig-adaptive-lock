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

pub struct SpinWait(usize);

impl SpinWait {
    pub const fn new() -> Self {
        Self(0)
    }

    pub fn reset(&mut self) {
        self.0 = 0;
    }

    pub fn yield_now(&mut self) -> bool {
        if self.0 > 10 {
            return false;
        }

        self.0 += 1;
        if self.0 <= 3 {
            (0..(1 << self.0)).for_each(|_| std::sync::atomic::spin_loop_hint());
        } else {
            #[cfg(windows)]
            unsafe { super::sys::Sleep(0) };
            #[cfg(not(windows))]
            std::thread::yield_now();
        }

        true
    }
}