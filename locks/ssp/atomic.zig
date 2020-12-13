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

pub fn spinLoopHint() void {
    switch (builtin.arch) {
        .i386, .x86_64 => asm volatile("pause"),
        .arm, .aarch64 => asm volatile("yield"),
        else => unreachable,
    }
}

pub const Ordering = enum {
    unordered,
    relaxed,
    consume,
    acquire,
    release,
    acq_rel,
    seq_cst,

    fn toBuiltin(comptime self: Ordering) builtin.AtomicOrder {
        return switch (self) {
            .unordered => .Unordered,
            .relaxed => .Monotonic,
            .consume => .Acquire,
            .acquire => .Acquire,
            .release => .Release,
            .acq_rel => .AcqRel,
            .seq_cst => .SeqCst,
        };
    }
};

pub fn fence(comptime ordering: Ordering) void {
    @fence(comptime ordering.toBuiltin());
}

pub fn compilerFence(comptime ordering: Ordering) void {
    switch (ordering) {
        .unordered => @compileError("Unordered memory ordering can only be on atomic variables"),
        .relaxed => @compileError("Relaxed memory ordering can only be on atomic variables"),
        .consume => @compileError("Consume memory ordering can only be on atomic variables"),
        else => asm volatile("" ::: "memory"),
    }
}

pub fn load(ptr: anytype, comptime ordering: Ordering) @TypeOf(ptr.*) {
    return @atomicLoad(@TypeOf(ptr.*), ptr, comptime ordering.toBuiltin());
}

pub fn store(ptr: anytype, value: @TypeOf(ptr.*), comptime ordering: Ordering) void {
    return @atomicStore(@TypeOf(ptr.*), ptr, value, comptime ordering.toBuiltin());
}

pub fn swap(ptr: anytype, value: @TypeOf(ptr.*), comptime ordering: Ordering) @TypeOf(ptr.*) {
    return atomicRmw(@TypeOf(ptr.*), ptr, .Xchg, value, ordering);
}

pub fn fetchAdd(ptr: anytype, value: @TypeOf(ptr.*), comptime ordering: Ordering) @TypeOf(ptr.*) {
    return atomicRmw(@TypeOf(ptr.*), ptr, .Add, value, ordering);
}

pub fn fetchSub(ptr: anytype, value: @TypeOf(ptr.*), comptime ordering: Ordering) @TypeOf(ptr.*) {
    return atomicRmw(@TypeOf(ptr.*), ptr, .Sub, value, ordering);
}

pub fn fetchAnd(ptr: anytype, value: @TypeOf(ptr.*), comptime ordering: Ordering) @TypeOf(ptr.*) {
    return atomicRmw(@TypeOf(ptr.*), ptr, .And, value, ordering);
}

pub fn fetchOr(ptr: anytype, value: @TypeOf(ptr.*), comptime ordering: Ordering) @TypeOf(ptr.*) {
    return atomicRmw(@TypeOf(ptr.*), ptr, .Or, value, ordering);
}

inline fn atomicRmw(comptime T: type, ptr: *T, comptime op: builtin.AtomicRmwOp, value: T, comptime ordering: Ordering) T {
    return @atomicRmw(T, ptr, op, value, comptime ordering.toBuiltin());
}

pub fn compareAndSwap(ptr: anytype, cmp: @TypeOf(ptr.*), xchg: @TypeOf(ptr.*), comptime success: Ordering, comptime failure: Ordering) ?@TypeOf(ptr.*) {
    return @cmpxchgStrong(@TypeOf(ptr.*), ptr, cmp, xchg, comptime success.toBuiltin(), comptime failure.toBuiltin());
}

pub fn tryCompareAndSwap(ptr: anytype, cmp: @TypeOf(ptr.*), xchg: @TypeOf(ptr.*), comptime success: Ordering, comptime failure: Ordering) ?@TypeOf(ptr.*) {
    return @cmpxchgStrong(@TypeOf(ptr.*), ptr, cmp, xchg, comptime success.toBuiltin(), comptime failure.toBuiltin());
}