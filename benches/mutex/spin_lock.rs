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

use super::util::SpinWait;
use std::sync::atomic::{AtomicBool, Ordering};

pub struct Lock(AtomicBool);

unsafe impl super::Lock for Lock {
    const NAME: &'static str = "spin_lock";

    fn new() -> Self {
        Self(AtomicBool::new(false))
    }

    fn with(&self, f: impl FnOnce()) {
        self.acquire();
        f();
        self.release();
    }
}

impl Lock {
    fn acquire(&self) {
        let mut locked = false;
        let mut spin = SpinWait::new();

        loop {
            if !locked && !self.0.swap(true, Ordering::Acquire) {
                return;
            }

            if !spin.yield_now() {
                spin.reset();
                let _ = spin.yield_now();
            }

            locked = self.0.load(Ordering::Relaxed);
        }
    }

    fn release(&self) {
        self.0.store(false, Ordering::Release);
    }
}
