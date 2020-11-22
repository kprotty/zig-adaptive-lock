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

pub struct Lock(Mutex<()>);

unsafe impl super::Lock for Lock {
    const NAME: &'static str = "safe_parker";

    fn new() -> Self {
        Self(Mutex::new(()))
    }

    fn with(&self, f: impl FnOnce()) {
        let guard = self.0.lock();
        f();
        std::mem::drop(guard);
    }
}

///////////////////////////////////////////////////////////////////////////////

use std::{
    mem::drop,
    ops::{Deref, DerefMut},
    thread::{self, Thread},
    time::{Instant, Duration},
    collections::VecDeque,
    sync::{Arc, Mutex as StdMutex, MutexGuard as StdMutexGuard},
    sync::atomic::{AtomicU8, AtomicBool, spin_loop_hint, Ordering},
};

struct Waiter {
    acquired: AtomicBool,
    notified: AtomicBool,
    thread: Thread,
}

#[derive(Default)]
struct Queue {
    waiters: VecDeque<Arc<Waiter>>,
    times_out: Option<Instant>,
    xorshift: u32,
}

const UNLOCKED: u8 = 0;
const LOCKED: u8 = 1;
const PARKED: u8 = 2;

pub struct Mutex<T> {
    state: AtomicU8,
    value: StdMutex<T>,
    queue: StdMutex<Queue>,
}

impl<T> Mutex<T> {
    pub fn new(value: T) -> Self {
        Self {
            state: AtomicU8::new(UNLOCKED),
            value: StdMutex::new(value),
            queue: StdMutex::new(Queue::default()),
        }
    }

    #[inline]
    fn locked(&self) -> MutexGuard<'_, T> {
        MutexGuard {
            mutex: self,
            guard: Some(self.value.lock().unwrap()),
        }
    }

    #[inline]
    #[allow(unused)]
    pub fn try_lock(&self) -> Option<MutexGuard<'_, T>> {
        let mut state = UNLOCKED;
        loop {
            if state & LOCKED != 0 {
                return None;
            }
            match self.state.compare_exchange_weak(
                state,
                state | LOCKED,
                Ordering::Acquire,
                Ordering::Relaxed,
            ) {
                Ok(_) => return Some(self.locked()),
                Err(e) => state = e,
            }
        }
    }

    #[inline]
    pub fn lock(&self) -> MutexGuard<'_, T> {
        if self
            .state
            .compare_exchange_weak(UNLOCKED, LOCKED, Ordering::Acquire, Ordering::Relaxed)
            .is_err()
        {
            self.lock_slow();
        }
        self.locked()
    }

    #[inline]
    fn unlock(&self) {
        if self
            .state
            .compare_exchange(LOCKED, UNLOCKED, Ordering::Release, Ordering::Relaxed)
            .is_err()
        {
            self.unlock_slow();
        }
    }

    #[cold]
    fn lock_slow(&self) {
        let mut spin = 0;
        let mut waiter = None;
        let mut state = self.state.load(Ordering::Relaxed);

        loop {
            if state & LOCKED == 0 {
                match self.state.compare_exchange_weak(
                    state,
                    state | LOCKED,
                    Ordering::Acquire,
                    Ordering::Relaxed,
                ) {
                    Ok(_) => return,
                    Err(e) => state = e,
                }
                continue;
            }

            if state & PARKED == 0 {
                if spin < 5 {
                    spin += 1;
                    if spin <= 3 {
                        (0..(1 << spin)).for_each(|_| spin_loop_hint());
                    } else {
                        thread::sleep(Duration::from_nanos(1 << spin));
                    }
                    state = self.state.load(Ordering::Relaxed);
                    continue;
                }

                if let Err(e) = self.state.compare_exchange_weak(
                    state,
                    state | PARKED,
                    Ordering::Relaxed,
                    Ordering::Relaxed,
                ) {
                    state = e;
                    continue;
                }
            }

            let mut queue = self.queue.lock().unwrap();
            if self.state.load(Ordering::Relaxed) != (LOCKED | PARKED) {
                drop(queue);
            } else {
                let waiter_ref = loop {
                    if let Some(waiter_ref) = waiter.as_ref() {
                        break waiter_ref;
                    }
                    waiter = Some(Arc::new(Waiter {
                        acquired: AtomicBool::new(false),
                        notified: AtomicBool::new(false),
                        thread: thread::current(),
                    }));
                };

                waiter_ref.notified.store(false, Ordering::Relaxed);
                queue.waiters.push_back(waiter_ref.clone());
                drop(queue);
                
                while !waiter_ref.notified.load(Ordering::Acquire) {
                    thread::park();
                }

                if waiter_ref.acquired.load(Ordering::Relaxed) {
                    return;
                }
            }

            spin = 0;
            state = self.state.load(Ordering::Relaxed);
        }
    }

    #[cold]
    fn unlock_slow(&self) {
        let mut queue = self.queue.lock().unwrap();

        let waiter = queue.waiters.pop_front();
        if let Some(waiter) = waiter.as_ref() {

            let be_fair = match queue.times_out {
                None => {
                    queue.times_out = Some(Instant::now() + Duration::from_millis(1));
                    queue.xorshift = (self as *const _ as usize) as u32;
                    false
                },
                Some(times_out) => {
                    let now = Instant::now();
                    now > times_out && {
                        queue.times_out = Some(now + Duration::new(0, {
                            queue.xorshift ^= queue.xorshift << 13;
                            queue.xorshift ^= queue.xorshift >> 17;
                            queue.xorshift ^= queue.xorshift << 5;
                            queue.xorshift % 1_000_000
                        }));
                        true
                    }
                },
            };

            waiter.acquired.store(be_fair, Ordering::Relaxed);
            if be_fair && queue.waiters.len() == 0 {
                self.state.store(LOCKED, Ordering::Relaxed);
            } else if !be_fair {
                self.state.store(PARKED, Ordering::Release);
            }
        } else {
            self.state.store(UNLOCKED, Ordering::Release);
        }

        drop(queue);

        if let Some(waiter) = waiter {
            let thread = waiter.thread.clone();
            waiter.notified.store(true, Ordering::Release);
            thread.unpark();
        }
    }
}

pub struct MutexGuard<'a, T> {
    mutex: &'a Mutex<T>,
    guard: Option<StdMutexGuard<'a, T>>,
}

impl<'a, T> Drop for MutexGuard<'a, T> {
    fn drop(&mut self) {
        drop(self.guard.take());
        self.mutex.unlock();
    }
}

impl<'a, T> Deref for MutexGuard<'a, T> {
    type Target = T;

    fn deref(&self) -> &T {
        &*self.guard.as_ref().unwrap()
    }
}

impl<'a, T> DerefMut for MutexGuard<'a, T> {
    fn deref_mut(&mut self) -> &mut T {
        &mut *self.guard.as_mut().unwrap()
    }
}

