const std = @import("std");
const builtin = @import("builtin");
const Atomic = std.atomic.Atomic;
const assert = std.debug.assert;
const os = std.os;

fn FutexLock(comptime lock_name: []const u8, comptime Futex: type) type {
    return extern struct {
        pub const name = lock_name;

        state: Atomic(u32) = Atomic(u32).init(unlocked),

        const unlocked = 0;
        const locked = 1;
        const contended = 2;

        const Lock = @This();

        pub fn init(self: *Lock) void {
            self.* = .{};
        }

        pub fn deinit(self: *Lock) void {
            self.* = .{};
        }

        pub fn acquire(self: *Lock) void {
            var state = self.state.tryCompareAndSwap(unlocked, locked, .Acquire, .Monotonic) orelse return;

            if (state == contended) {
                Futex.wait(&self.state, contended);
            }

            while (self.state.swap(contended, .Acquire) != unlocked) {
                Futex.wait(&self.state, contended);
            }
        }

        pub fn release(self: *Lock) void {
            if (self.state.swap(unlocked, .Release) == contended) {
                Futex.wake(&self.state, 1);
            }
        }
    };
}

pub const NativeFutexLock = FutexLock("native-futex", struct {
    pub fn wait(ptr: *const Atomic(u32), expect: u32) void {
        // TODO: change to std.Thread.Futex.wait(ptr, expect);
        std.Thread.Futex.wait(ptr, expect, null) catch unreachable;
    }

    pub fn wake(ptr: *const Atomic(u32), max_wake: u32) void {
        std.Thread.Futex.wake(ptr, max_wake);
    }
});

pub const PosixFutexLock = FutexLock("posix-futex", struct {
    pub fn wait(ptr: *const Atomic(u32), expect: u32) void {
        PosixImpl.wait(ptr, expect, null) catch unreachable;
    }

    pub fn wake(ptr: *const Atomic(u32), max_wake: u32) void {
        PosixImpl.wake(ptr, max_wake);
    }
});

const cache_line = switch (builtin.cpu.arch) {
    // x86_64: Starting from Intel's Sandy Bridge, the spatial prefetcher pulls in pairs of 64-byte cache lines at a time.
    // - https://www.intel.com/content/dam/www/public/us/en/documents/manuals/64-ia-32-architectures-optimization-manual.pdf
    // - https://github.com/facebook/folly/blob/1b5288e6eea6df074758f877c849b6e73bbb9fbb/folly/lang/Align.h#L107
    //
    // aarch64: Some big.LITTLE ARM archs have "big" cores with 128-byte cache lines:
    // - https://www.mono-project.com/news/2016/09/12/arm64-icache/
    // - https://cpufun.substack.com/p/more-m1-fun-hardware-information
    //
    // powerpc64: PPC has 128-byte cache lines
    // - https://github.com/golang/go/blob/3dd58676054223962cd915bb0934d1f9f489d4d2/src/internal/cpu/cpu_ppc64x.go#L9
    .x86_64, .aarch64, .powerpc64 => 128,

    // These platforms reportedly have 32-byte cache lines
    // - https://github.com/golang/go/blob/3dd58676054223962cd915bb0934d1f9f489d4d2/src/internal/cpu/cpu_arm.go#L7
    // - https://github.com/golang/go/blob/3dd58676054223962cd915bb0934d1f9f489d4d2/src/internal/cpu/cpu_mips.go#L7
    // - https://github.com/golang/go/blob/3dd58676054223962cd915bb0934d1f9f489d4d2/src/internal/cpu/cpu_mipsle.go#L7
    // - https://github.com/golang/go/blob/3dd58676054223962cd915bb0934d1f9f489d4d2/src/internal/cpu/cpu_mips64x.go#L9
    // - https://github.com/golang/go/blob/3dd58676054223962cd915bb0934d1f9f489d4d2/src/internal/cpu/cpu_riscv64.go#L7
    .arm, .mips, .mips64, .riscv64 => 32,

    // This platform reportedly has 256-byte cache lines
    // - https://github.com/golang/go/blob/3dd58676054223962cd915bb0934d1f9f489d4d2/src/internal/cpu/cpu_s390x.go#L7
    .s390x => 256,

    // Other x86 and WASM platforms have 64-byte cache lines.
    // The rest of the architectures are assumed to be similar.
    // - https://github.com/golang/go/blob/dda2991c2ea0c5914714469c4defc2562a907230/src/internal/cpu/cpu_x86.go#L9
    // - https://github.com/golang/go/blob/3dd58676054223962cd915bb0934d1f9f489d4d2/src/internal/cpu/cpu_wasm.go#L7
    else => 64,
};

/// Modified version of linux's futex and Go's sema to implement userspace wait queues with pthread:
/// https://code.woboq.org/linux/linux/kernel/futex.c.html
/// https://go.dev/src/runtime/sema.go
const PosixImpl = struct {
    const Event = struct {
        cond: std.c.pthread_cond_t,
        mutex: std.c.pthread_mutex_t,
        state: enum { empty, waiting, notified },

        fn init(self: *Event) void {
            // Use static init instead of pthread_cond/mutex_init() since this is generally faster.
            self.cond = .{};
            self.mutex = .{};
            self.state = .empty;
        }

        fn deinit(self: *Event) void {
            // Some platforms reportedly give EINVAL for statically initialized pthread types.
            const rc = std.c.pthread_cond_destroy(&self.cond);
            assert(rc == .SUCCESS or rc == .INVAL);

            const rm = std.c.pthread_mutex_destroy(&self.mutex);
            assert(rm == .SUCCESS or rm == .INVAL);

            self.* = undefined;
        }

        fn wait(self: *Event, timeout: ?u64) error{Timeout}!void {
            assert(std.c.pthread_mutex_lock(&self.mutex) == .SUCCESS);
            defer assert(std.c.pthread_mutex_unlock(&self.mutex) == .SUCCESS);

            // Early return if the event was already set.
            if (self.state == .notified) {
                return;
            }

            // Compute the absolute timeout if one was specified.
            // POSIX requires that REALTIME is used by default for the pthread timedwait functions.
            // This can be changed with pthread_condattr_setclock, but it's an extension and may not be available everywhere.
            var ts: os.timespec = undefined;
            if (timeout) |timeout_ns| {
                os.clock_gettime(os.CLOCK.REALTIME, &ts) catch unreachable;
                ts.tv_sec +|= @intCast(@TypeOf(ts.tv_sec), timeout_ns / std.time.ns_per_s);
                ts.tv_nsec += @intCast(@TypeOf(ts.tv_nsec), timeout_ns % std.time.ns_per_s);

                if (ts.tv_nsec >= std.time.ns_per_s) {
                    ts.tv_sec +|= 1;
                    ts.tv_nsec -= std.time.ns_per_s;
                }
            }

            // Start waiting on the event - there can be only one thread waiting.
            assert(self.state == .empty);
            self.state = .waiting;

            while (true) {
                // Block using either pthread_cond_wait or pthread_cond_timewait if there's an absolute timeout.
                const rc = blk: {
                    if (timeout == null) break :blk std.c.pthread_cond_wait(&self.cond, &self.mutex);
                    break :blk std.c.pthread_cond_timedwait(&self.cond, &self.mutex, &ts);
                };

                // After waking up, check if the event was set.
                if (self.state == .notified) {
                    return;
                }

                assert(self.state == .waiting);
                switch (rc) {
                    .SUCCESS => {},
                    .TIMEDOUT => {
                        // If timed out, reset the event to avoid the set() thread doing an unnecessary signal().
                        self.state = .empty;
                        return error.Timeout;
                    },
                    .INVAL => unreachable, // cond, mutex, and potentially ts should all be valid
                    .PERM => unreachable, // mutex is locked when cond_*wait() functions are called
                    else => unreachable,
                }
            }
        }

        fn set(self: *Event) void {
            assert(std.c.pthread_mutex_lock(&self.mutex) == .SUCCESS);
            defer assert(std.c.pthread_mutex_unlock(&self.mutex) == .SUCCESS);

            // Make sure that multiple calls to set() were not done on the same Event.
            const old_state = self.state;
            assert(old_state != .notified);

            // Mark the event as set and wake up the waiting thread if there was one.
            // This must be done while the mutex as the wait() thread could deallocate
            // the condition variable once it observes the new state, potentially causing a UAF if done unlocked.
            self.state = .notified;
            if (old_state == .waiting) {
                assert(std.c.pthread_cond_signal(&self.cond) == .SUCCESS);
            }
        }
    };

    const Treap = StdTreap(usize, std.math.order);
    const Waiter = struct {
        node: Treap.Node,
        prev: ?*Waiter,
        next: ?*Waiter,
        tail: ?*Waiter,
        is_queued: bool,
        event: Event,
    };

    // An unordered set of Waiters
    const WaitList = struct {
        top: ?*Waiter = null,
        len: usize = 0,

        fn push(self: *WaitList, waiter: *Waiter) void {
            waiter.next = self.top;
            self.top = waiter;
            self.len += 1;
        }

        fn pop(self: *WaitList) ?*Waiter {
            const waiter = self.top orelse return null;
            self.top = waiter.next;
            self.len -= 1;
            return waiter;
        }
    };

    const WaitQueue = struct {
        fn insert(treap: *Treap, address: usize, waiter: *Waiter) void {
            // prepare the waiter to be inserted.
            waiter.next = null;
            waiter.is_queued = true;

            // Find the wait queue entry associated with the address.
            // If there isn't a wait queue on the address, this waiter creates the queue.
            var entry = treap.getEntryFor(address);
            const entry_node = entry.node orelse {
                waiter.prev = null;
                waiter.tail = waiter;
                entry.set(&waiter.node);
                return;
            };

            // There's a wait queue on the address; get the queue head and tail.
            const head = @fieldParentPtr(Waiter, "node", entry_node);
            const tail = head.tail orelse unreachable;

            // Push the waiter to the tail by replacing it and linking to the previous tail.
            head.tail = waiter;
            tail.next = waiter;
            waiter.prev = tail;
        }

        fn remove(treap: *Treap, address: usize, max_waiters: usize) WaitList {
            // Find the wait queue associated with this address and get the head/tail if any.
            var entry = treap.getEntryFor(address);
            var queue_head = if (entry.node) |node| @fieldParentPtr(Waiter, "node", node) else null;
            const queue_tail = if (queue_head) |head| head.tail else null;

            // Once we're done updating the head, fix it's tail pointer and update the treap's queue head as well.
            defer entry.set(blk: {
                const new_head = queue_head orelse break :blk null;
                new_head.tail = queue_tail;
                break :blk &new_head.node;
            });

            var removed = WaitList{};
            while (removed.len < max_waiters) {
                // dequeue and collect waiters from their wait queue.
                const waiter = queue_head orelse break;
                queue_head = waiter.next;
                removed.push(waiter);

                // When dequeueing, we must mark is_queued as false.
                // This ensures that a waiter which calls tryRemove() returns false.
                assert(waiter.is_queued);
                waiter.is_queued = false;
            }

            return removed;
        }

        fn tryRemove(treap: *Treap, address: usize, waiter: *Waiter) bool {
            if (!waiter.is_queued) {
                return false;
            }

            queue_remove: {
                // Find the wait queue associated with the address.
                var entry = blk: {
                    // A waiter without a previous link means it's the queue head that's in the treap so we can avoid lookup.
                    if (waiter.prev == null) {
                        assert(waiter.node.key == address);
                        break :blk treap.getEntryForExisting(&waiter.node);
                    }
                    break :blk treap.getEntryFor(address);
                };

                // The queue head and tail must exist if we're removing a queued waiter.
                const head = @fieldParentPtr(Waiter, "node", entry.node orelse unreachable);
                const tail = head.tail orelse unreachable;

                // A waiter with a previous link is never the head of the queue.
                if (waiter.prev) |prev| {
                    assert(waiter != head);
                    prev.next = waiter.next;

                    // A waiter with both a previous and next link is in the middle.
                    // We only need to update the surrounding waiter's links to remove it.
                    if (waiter.next) |next| {
                        assert(waiter != tail);
                        next.prev = waiter.prev;
                        break :queue_remove;
                    }

                    // A waiter with a previous but no next link means it's the tail of the queue.
                    // In that case, we need to update the head's tail reference.
                    assert(waiter == tail);
                    head.tail = waiter.prev;
                    break :queue_remove;
                }

                // A waiter with no previous link means it's the queue head of queue.
                // We must replace (or remove) the head waiter reference in the treap.
                assert(waiter == head);
                entry.set(blk: {
                    const new_head = waiter.next orelse break :blk null;
                    new_head.tail = head.tail;
                    break :blk &new_head.node;
                });
            }

            // Mark the waiter as successfully removed.
            waiter.is_queued = false;
            return true;
        }
    };

    const BucketMutex = WordLock;

    const PosixLock = struct {
        mutex: std.c.pthread_mutex_t = .{},

        fn lock(self: *PosixLock) void {
            assert(std.c.pthread_mutex_lock(&self.mutex) == .SUCCESS);
        }

        fn unlock(self: *PosixLock) void {
            assert(std.c.pthread_mutex_unlock(&self.mutex) == .SUCCESS);
        }
    };

    const WordLock = struct {
        state: Atomic(usize) = Atomic(usize).init(0),

        const locked: usize = 1;
        const queue_locked: usize = 2;
        const waiter_mask: usize = ~(locked | queue_locked);

        fn lock(self: *WordLock) void {
            if (self.lockFast(0)) return;
            self.lockSlow();
        }

        inline fn lockFast(self: *WordLock, state: usize) bool {
            if (builtin.target.cpu.arch.isX86()) {
                return self.state.bitSet(@ctz(usize, locked), .Acquire) == 0;
            }

            return self.state.tryCompareAndSwap(state, state | locked, .Acquire, .Monotonic) == null;
        }

        fn lockSlow(self: *WordLock) void {
            @setCold(true);

            var spin: usize = 0;
            var waiter: Waiter = undefined;
            var has_event: bool = false;
            var state = self.state.load(.Monotonic);
            
            while (true) {
                var backoff: usize = 0;
                while (state & locked == 0) {
                    if (self.lockFast(state)) {
                        if (has_event) waiter.event.deinit();
                        return;
                    }

                    var i: usize = backoff;
                    while (i > 0) : (i -= 1) std.atomic.spinLoopHint();

                    backoff = std.math.min(100, std.math.max(backoff, 1) * 2);
                    state = self.state.load(.Monotonic);
                }

                const head = @intToPtr(?*Waiter, state & waiter_mask);
                if (head == null and spin < 100) {
                    spin += 1;
                    std.atomic.spinLoopHint();
                    state = self.state.load(.Monotonic);
                    continue;
                }

                if (!has_event) {
                    has_event = true;
                    waiter.event.init();
                }

                waiter.prev = null;
                waiter.next = head;
                waiter.tail = if (head == null) &waiter else null;

                var new_state = @ptrToInt(&waiter) | (state & ~waiter_mask);
                if (head != null) {
                    new_state |= queue_locked;
                }

                state = self.state.tryCompareAndSwap(state, new_state, .Release, .Monotonic) orelse blk: {
                    if (head != null and (state & queue_locked == 0)) {
                        self.linkQueueOrUnpark(new_state);
                    }

                    waiter.event.wait(null) catch unreachable;
                    waiter.event.state = .empty;
                    spin = 0;
                    break :blk self.state.load(.Monotonic);
                };
            }
        }
    
        fn linkQueueOrUnpark(self: *WordLock, current_state: usize) void {
            @setCold(true);

            var state = current_state;
            while (true) {
                if (state & locked == 0) {
                    return self.unpark(state);
                }

                _ = self.getAndLinkQueue(state);

                const new_state = state & ~queue_locked;
                state = self.state.tryCompareAndSwap(state, new_state, .Release, .Monotonic) orelse return;
            }
        }
        
        const Queue = struct {
            head: *Waiter,
            tail: *Waiter,
        };

        fn getAndLinkQueue(self: *WordLock, state: usize) Queue {
            _ = self;
            std.atomic.fence(.Acquire);

            var queue: Queue = undefined;
            queue.head = @intToPtr(*Waiter, state & ~(locked | queue_locked));
            queue.tail = queue.head.tail orelse blk: {
                var current = queue.head;
                while (true) {
                    const next = current.next orelse unreachable;
                    next.prev = current;
                    current = next;

                    if (current.tail) |tail| {
                        queue.head.tail = tail;
                        break :blk tail;
                    }
                }
            };
            return queue;
        }

        fn unlock(self: *WordLock) void {
            const state = self.state.fetchSub(locked, .Release);

            if ((state & waiter_mask != 0) and (state & queue_locked == 0)) {
                self.unlockSlow();
            }
        }

        fn unlockSlow(self: *WordLock) void {
            @setCold(true);

            var state = self.state.load(.Monotonic);
            while (true) {
                if ((state & waiter_mask == 0) or (state & (locked | queue_locked) != 0)) {
                    return;
                }

                const new_state = state | queue_locked;
                state = self.state.tryCompareAndSwap(state, new_state, .Monotonic, .Monotonic) orelse {
                    return self.unpark(new_state);
                };
            }
        }

        noinline fn unpark(self: *WordLock, current_state: usize) void {
            var state = current_state;
            while (true) {
                while (state & locked != 0) {
                    const new_state = state & ~queue_locked;
                    state = self.state.tryCompareAndSwap(state, new_state, .Release, .Monotonic) orelse return;
                }

                const queue = self.getAndLinkQueue(state);

                if (queue.tail.prev) |new_tail| {
                    queue.head.tail = new_tail;
                    _ = self.state.fetchSub(queue_locked, .Release);
                    return queue.tail.event.set();
                }

                const new_state = 0;
                state = self.state.tryCompareAndSwap(state, new_state, .Release, .Monotonic) orelse {
                    return queue.head.event.set();
                };
            }
        }
    };

    const Bucket = struct {
        mutex: BucketMutex align(cache_line) = .{},
        pending: Atomic(usize) align(cache_line) = Atomic(usize).init(0),
        treap: Treap align(cache_line) = .{},

        // Global array of buckets that addresses map to.
        // Bucket array size is pretty much arbitrary here, but it must be a power of two for fibonacci hashing.
        var buckets = [_]Bucket{.{}} ** @bitSizeOf(usize);

        // https://github.com/Amanieu/parking_lot/blob/1cf12744d097233316afa6c8b7d37389e4211756/core/src/parking_lot.rs#L343-L353
        fn from(address: usize) *Bucket {
            // The upper `@bitSizeOf(usize)` bits of the fibonacci golden ratio.
            // Hashing this via (h * k) >> (64 - b) where k=golden-ration and b=bitsize-of-array
            // evenly lays out h=hash values over the bit range even when the hash has poor entropy (identity-hash for pointers).
            const max_multiplier_bits = @bitSizeOf(usize);
            const fibonacci_multiplier = 0x9E3779B97F4A7C15 >> (64 - max_multiplier_bits);

            const max_bucket_bits = @ctz(usize, buckets.len);
            comptime assert(std.math.isPowerOfTwo(buckets.len));

            const index = (address *% fibonacci_multiplier) >> (max_multiplier_bits - max_bucket_bits);
            return &buckets[index];
        }
    };

    const Address = struct {
        fn from(ptr: *const Atomic(u32)) usize {
            // Get the alignment of the pointer.
            const alignment = @alignOf(Atomic(u32));
            comptime assert(std.math.isPowerOfTwo(alignment));

            // Make sure the pointer is aligned,
            // then cut off the zero bits from the alignment to get the unique address.
            const addr = @ptrToInt(ptr);
            assert(addr & (alignment - 1) == 0);
            return addr >> @ctz(usize, alignment);
        }
    };

    fn wait(ptr: *const Atomic(u32), expect: u32, timeout: ?u64) error{Timeout}!void {
        const address = Address.from(ptr);
        const bucket = Bucket.from(address);

        // Announce that there's a waiter in the bucket before checking the ptr/expect condition.
        // If the announcement is reordered after the ptr check, the waiter could deadlock:
        //
        // - T1: checks ptr == expect which is true
        // - T2: updates ptr to != expect
        // - T2: does Futex.wake(), sees no pending waiters, exits
        // - T1: bumps pending waiters (was reordered after the ptr == expect check)
        // - T1: goes to sleep and misses both the ptr change and T2's wake up
        //
        // SeqCst as Acquire barrier to ensure the announcement happens before the ptr check below.
        // SeqCst as shared modification order to form a happens-before edge with the fence(.SeqCst)+load() in wake().
        var pending = bucket.pending.fetchAdd(1, .SeqCst);
        assert(pending < std.math.maxInt(usize));

        // If the wait gets cancelled, remove the pending count we previously added.
        // This is done outside the mutex lock to keep the critical section short in case of contention.
        var cancelled = false;
        defer if (cancelled) {
            pending = bucket.pending.fetchSub(1, .Monotonic);
            assert(pending > 0);
        };

        var waiter: Waiter = undefined;
        {
            bucket.mutex.lock();
            defer bucket.mutex.unlock();

            cancelled = ptr.load(.Monotonic) != expect;
            if (cancelled) {
                return;
            }

            waiter.event.init();
            WaitQueue.insert(&bucket.treap, address, &waiter);
        }

        defer {
            assert(!waiter.is_queued);
            waiter.event.deinit();
        }

        waiter.event.wait(timeout) catch {
            // If we fail to cancel after a timeout, it means a wake() thread dequeued us and will wake us up.
            // We must wait until the event is set as that's a signal that the wake() thread wont access the waiter memory anymore.
            // If we return early without waiting, the waiter on the stack would be invalidated and the wake() thread risks a UAF.
            defer if (!cancelled) waiter.event.wait(null) catch unreachable;

            bucket.mutex.lock();
            defer bucket.mutex.unlock();

            cancelled = WaitQueue.tryRemove(&bucket.treap, address, &waiter);
            if (cancelled) {
                return error.Timeout;
            }
        };
    }

    fn wake(ptr: *const Atomic(u32), max_waiters: u32) void {
        const address = Address.from(ptr);
        const bucket = Bucket.from(address);

        // Quick check if there's even anything to wake up.
        // The change to the ptr's value must happen before we check for pending waiters.
        // If not, the wake() thread could miss a sleeping waiter and have it deadlock:
        //
        // - T2: p = has pending waiters (reordered before the ptr update)
        // - T1: bump pending waiters
        // - T1: if ptr == expected: sleep()
        // - T2: update ptr != expected
        // - T2: p is false from earlier so doesn't wake (T1 missed ptr update and T2 missed T1 sleeping)
        //
        // What we really want here is a Release load, but that doesn't exist under the C11 memory model.
        // We could instead do `bucket.pending.fetchAdd(0, Release) == 0` which achieves effectively the same thing,
        // but the RMW operation unconditionally stores which invalidates the cache-line for others causing unnecessary contention.
        //
        // Instead we opt to do a full-fence + load instead which avoids taking ownership of the cache-line.
        // fence(SeqCst) effectively converts the ptr update to SeqCst and the pending load to SeqCst: creating a Store-Load barrier.
        //
        // The pending count increment in wait() must also now use SeqCst for the update + this pending load
        // to be in the same modification order as our load isn't using Release/Acquire to guarantee it.
        std.atomic.fence(.SeqCst);
        if (bucket.pending.load(.Monotonic) == 0) {
            return;
        }

        // Keep a list of all the waiters notified and wake then up outside the mutex critical section.
        var notified = WaitList{};
        defer if (notified.len > 0) {
            const pending = bucket.pending.fetchSub(notified.len, .Monotonic);
            assert(pending >= notified.len);

            while (notified.pop()) |waiter| {
                assert(!waiter.is_queued);
                waiter.event.set();
            }
        };

        bucket.mutex.lock();
        defer bucket.mutex.unlock();

        // Another pending check again to avoid the WaitQueue lookup if not necessary.
        if (bucket.pending.load(.Monotonic) > 0) {
            notified = WaitQueue.remove(&bucket.treap, address, max_waiters);
        }
    }
};

const Order = std.math.Order;
fn StdTreap(comptime Key: type, comptime compareFn: anytype) type {
    return struct {
        const Self = @This();

        // Allow for compareFn to be fn(anytype, anytype) anytype
        // which allows the convenient use of std.math.order.
        fn compare(a: Key, b: Key) Order {
            return compareFn(a, b);
        }

        root: ?*Node = null,
        prng: Prng = .{},

        /// A customized pseudo random number generator for the treap.
        /// This just helps reducing the memory size of the treap itself
        /// as std.rand.DefaultPrng requires larger state (while producing better entropy for randomness to be fair).
        const Prng = struct {
            xorshift: usize = 0,

            fn random(self: *Prng, seed: usize) usize {
                // Lazily seed the prng state
                if (self.xorshift == 0) {
                    self.xorshift = seed;
                }

                // Since we're using usize, decide the shifts by the integer's bit width.
                const shifts = switch (@bitSizeOf(usize)) {
                    64 => .{ 13, 7, 17 },
                    32 => .{ 13, 17, 5 },
                    16 => .{ 7, 9, 8 },
                    else => @compileError("platform not supported"),
                };

                self.xorshift ^= self.xorshift >> shifts[0];
                self.xorshift ^= self.xorshift << shifts[1];
                self.xorshift ^= self.xorshift >> shifts[2];

                assert(self.xorshift != 0);
                return self.xorshift;
            }
        };

        /// A Node represents an item or point in the treap with a uniquely associated key.
        pub const Node = struct {
            key: Key,
            priority: usize,
            parent: ?*Node,
            children: [2]?*Node,
        };

        /// Returns the smallest Node by key in the treap if there is one.
        /// Use `getEntryForExisting()` to replace/remove this Node from the treap.
        pub fn getMin(self: Self) ?*Node {
            var node = self.root;
            while (node) |current| {
                node = current.children[0] orelse break;
            }
            return node;
        }

        /// Returns the largest Node by key in the treap if there is one.
        /// Use `getEntryForExisting()` to replace/remove this Node from the treap.
        pub fn getMax(self: Self) ?*Node {
            var node = self.root;
            while (node) |current| {
                node = current.children[1] orelse break;
            }
            return node;
        }

        /// Lookup the Entry for the given key in the treap.
        /// The Entry act's as a slot in the treap to insert/replace/remove the node associated with the key.
        pub fn getEntryFor(self: *Self, key: Key) Entry {
            var parent: ?*Node = undefined;
            const node = self.find(key, &parent);

            return Entry{
                .key = key,
                .treap = self,
                .node = node,
                .context = .{ .inserted_under = parent },
            };
        }

        /// Get an entry for a Node that currently exists in the treap.
        /// It is undefined behavior if the Node is not currently inserted in the treap.
        /// The Entry act's as a slot in the treap to insert/replace/remove the node associated with the key.
        pub fn getEntryForExisting(self: *Self, node: *Node) Entry {
            assert(node.priority != 0);

            return Entry{
                .key = node.key,
                .treap = self,
                .node = node,
                .context = .{ .inserted_under = node.parent },
            };
        }

        /// An Entry represents a slot in the treap associated with a given key.
        pub const Entry = struct {
            /// The associated key for this entry.
            key: Key,
            /// A reference to the treap this entry is apart of.
            treap: *Self,
            /// The current node at this entry.
            node: ?*Node,
            /// The current state of the entry.
            context: union(enum) {
                /// A find() was called for this entry and the position in the treap is known.
                inserted_under: ?*Node,
                /// The entry's node was removed from the treap and a lookup must occur again for modification.
                removed,
            },

            /// Update's the Node at this Entry in the treap with the new node.
            pub fn set(self: *Entry, new_node: ?*Node) void {
                // Update the entry's node reference after updating the treap below.
                defer self.node = new_node;

                if (self.node) |old| {
                    if (new_node) |new| {
                        self.treap.replace(old, new);
                        return;
                    }

                    self.treap.remove(old);
                    self.context = .removed;
                    return;
                }

                if (new_node) |new| {
                    // A previous treap.remove() could have rebalanced the nodes
                    // so when inserting after a removal, we have to re-lookup the parent again.
                    // This lookup shouldn't find a node because we're yet to insert it..
                    var parent: ?*Node = undefined;
                    switch (self.context) {
                        .inserted_under => |p| parent = p,
                        .removed => assert(self.treap.find(self.key, &parent) == null),
                    }

                    self.treap.insert(self.key, parent, new);
                    self.context = .{ .inserted_under = parent };
                }
            }
        };

        fn find(self: Self, key: Key, parent_ref: *?*Node) ?*Node {
            var node = self.root;
            parent_ref.* = null;

            // basic binary search while tracking the parent.
            while (node) |current| {
                const order = compare(key, current.key);
                if (order == .eq) break;

                parent_ref.* = current;
                node = current.children[@boolToInt(order == .gt)];
            }

            return node;
        }

        fn insert(self: *Self, key: Key, parent: ?*Node, node: *Node) void {
            // generate a random priority & prepare the node to be inserted into the tree
            node.key = key;
            node.priority = self.prng.random(@ptrToInt(node));
            node.parent = parent;
            node.children = [_]?*Node{ null, null };

            // point the parent at the new node
            const link = if (parent) |p| &p.children[@boolToInt(compare(key, p.key) == .gt)] else &self.root;
            assert(link.* == null);
            link.* = node;

            // rotate the node up into the tree to balance it according to its priority
            while (node.parent) |p| {
                if (p.priority <= node.priority) break;

                const is_right = p.children[1] == node;
                assert(p.children[@boolToInt(is_right)] == node);

                const rotate_right = !is_right;
                self.rotate(p, rotate_right);
            }
        }

        fn replace(self: *Self, old: *Node, new: *Node) void {
            // copy over the values from the old node
            new.key = old.key;
            new.priority = old.priority;
            new.parent = old.parent;
            new.children = old.children;

            // point the parent at the new node
            const link = if (old.parent) |p| &p.children[@boolToInt(p.children[1] == old)] else &self.root;
            assert(link.* == old);
            link.* = new;

            // point the children's parent at the new node
            for (old.children) |child_node| {
                const child = child_node orelse continue;
                assert(child.parent == old);
                child.parent = new;
            }
        }

        fn remove(self: *Self, node: *Node) void {
            // rotate the node down to be a leaf of the tree for removal, respecting priorities.
            while (node.children[0] orelse node.children[1]) |_| {
                self.rotate(node, rotate_right: {
                    const right = node.children[1] orelse break :rotate_right true;
                    const left = node.children[0] orelse break :rotate_right false;
                    break :rotate_right (left.priority < right.priority);
                });
            }

            // node is a now a leaf; remove by nulling out the parent's reference to it.
            const link = if (node.parent) |p| &p.children[@boolToInt(p.children[1] == node)] else &self.root;
            assert(link.* == node);
            link.* = null;

            // clean up after ourselves
            node.key = undefined;
            node.priority = 0;
            node.parent = null;
            node.children = [_]?*Node{ null, null };
        }

        fn rotate(self: *Self, node: *Node, right: bool) void {
            // if right, converts the following:
            //      parent -> (node (target YY adjacent) XX)
            //      parent -> (target YY (node adjacent XX))
            //
            // if left (!right), converts the following:
            //      parent -> (node (target YY adjacent) XX)
            //      parent -> (target YY (node adjacent XX))
            const parent = node.parent;
            const target = node.children[@boolToInt(!right)] orelse unreachable;
            const adjacent = target.children[@boolToInt(right)];

            // rotate the children
            target.children[@boolToInt(right)] = node;
            node.children[@boolToInt(!right)] = adjacent;

            // rotate the parents
            node.parent = target;
            target.parent = parent;
            if (adjacent) |adj| adj.parent = node;

            // fix the parent link
            const link = if (parent) |p| &p.children[@boolToInt(p.children[1] == node)] else &self.root;
            assert(link.* == node);
            link.* = target;
        }
    };
}