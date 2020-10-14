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

//! Wrappers for [`core::sync`] which allow a central place to substitute platform atomics and shared mutability.

#[cfg(feature = "loom")]
pub(crate) use loom::{
    cell::UnsafeCell,
    sync::atomic::{fence, spin_loop_hint, AtomicU8, AtomicUsize, Ordering},
};

#[cfg(not(feature = "loom"))]
pub(crate) use if_core::*;

#[cfg(not(feature = "loom"))]
mod if_core {
    pub(crate) use core::sync::atomic::{fence, spin_loop_hint, Ordering};

    #[cfg_attr(feature = "nightly", cfg(target_has_atomic = "ptr"))]
    #[cfg(target_atomic_usize)]
    pub(crate) use core::sync::atomic::AtomicUsize;

    #[cfg_attr(feature = "nightly", cfg(target_has_atomic = "8"))]
    #[cfg(target_atomic_u8)]
    pub(crate) use core::sync::atomic::AtomicU8;

    #[derive(Debug, Default)]
    pub(crate) struct UnsafeCell<T>(core::cell::UnsafeCell<T>);

    impl<T> UnsafeCell<T> {
        pub(crate) const fn new(value: T) -> Self {
            Self(core::cell::UnsafeCell::new(value))
        }

        pub(crate) fn with<F>(&self, f: impl FnOnce(*const T) -> F) -> F {
            f(self.0.get())
        }

        pub(crate) fn with_mut<F>(&self, f: impl FnOnce(*mut T) -> F) -> F {
            f(self.0.get())
        }

        #[cfg(not(feature = "loom"))]
        pub(crate) fn into_inner(self) -> T {
            self.0.into_inner()
        }
    }
}
