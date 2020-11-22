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

use std::sync::atomic::{AtomicBool, Ordering};

pub struct Lock {
    locked: AtomicBool,
}

unsafe impl super::Lock for Lock {
    const NAME: &'static str = "flume_lock";

    fn new() -> Self {
        Self {
            locked: AtomicBool::new(false),
        }
    }

    fn with(&self, f: impl FnOnce()) {
        self.acquire();
        let _ = f();
        self.release();
    }
}

impl Lock {
    fn acquire(&self) {
        let mut i = 4;
        loop {
            for _ in 0..10 {
                if !self.locked.swap(true, Ordering::Acquire) {
                    return;
                }
                std::thread::yield_now();
            }
            std::thread::sleep(std::time::Duration::from_nanos(1 << i));
            i += 1;
        }
    }

    fn release(&self) {
        self.locked.store(false, Ordering::Release);
    }
}
