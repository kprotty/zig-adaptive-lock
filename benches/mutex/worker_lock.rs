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

use std::{
    thread,
    ptr::{NonNull, null_mut},
    cell::Cell,
    mem::transmute,
    sync::atomic::{AtomicUsize, AtomicPtr, AtomicBool, Ordering},
};

struct Event {
    thread: Cell<Option<thread::Thread>>,
    is_set: AtomicBool,
}

struct Waiter {
    next: Cell<Option<NonNull<Self>>>,
    func: *mut dyn FnMut(),
    event: AtomicPtr<Event>,
}

pub struct Lock {
    state: AtomicUsize,
}

unsafe impl super::Lock for Lock {
    const NAME: &'static str = "worker_lock";

    fn new() -> Self {
        Self {
            state: AtomicUsize::new(0),
        }
    }

    fn with(&self, f: impl FnOnce()) {
        let mut f = Some(f);
        let mut f = move || (f.take().unwrap())();

        unsafe {
            let mut spin = 0;
            let mut state = 0;
            loop {
                if state == 0 {
                    match self.state.compare_exchange(0, 1, Ordering::Acquire, Ordering::Relaxed) {
                        Err(e) => state = e,
                        Ok(_) => break,
                    }
                }

                if state == 1 && spin < 100 {
                    spin += 1;
                    std::hint::spin_loop();
                    state = self.state.load(Ordering::Relaxed);
                    continue;
                }

                let waiter = Waiter {
                    next: Cell::new(NonNull::new((state & !1usize) as *mut Waiter)),
                    func: transmute(&mut f as *mut dyn FnMut()),
                    event: AtomicPtr::new(null_mut()),
                };

                if let Err(e) = self.state.compare_exchange_weak(
                    state,
                    &waiter as *const Waiter as usize,
                    Ordering::Release,
                    Ordering::Relaxed,
                ) {
                    state = e;
                    continue;
                }

                if waiter.event.load(Ordering::Acquire).is_null() {
                    let event = Event{
                        thread: Cell::new(Some(thread::current())),
                        is_set: AtomicBool::new(false),
                    };
            
                    if waiter.event.swap(&event as *const Event as *mut Event, Ordering::AcqRel).is_null() {
                        while !event.is_set.load(Ordering::Acquire) {
                            thread::park();
                        }
                    }
                }

                return;
            }

            f();
            
            let mut last = None;
            state = 1;

            loop {
                match self.state.compare_exchange(state, 0, Ordering::AcqRel, Ordering::Acquire) {
                    Ok(_) => break,
                    Err(e) => state = e,
                }

                let head = NonNull::new(state as *mut Waiter).unwrap();
                let tail = last;
                last = Some(head);

                let mut current = Some(head);
                while current != tail {
                    match current {
                        None => break,
                        Some(waiter) => {
                            current = waiter.as_ref().next.get();
                            (*waiter.as_ref().func)();

                            let event = waiter.as_ref().event.swap(NonNull::dangling().as_ptr(), Ordering::AcqRel);
                            if !event.is_null() {
                                unsafe {
                                    let thread = (*event).thread.take();
                                    (*event).is_set.store(true, Ordering::Release);
                                    thread.unwrap().unpark();
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

