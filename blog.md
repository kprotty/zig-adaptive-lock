Lets say you're writing your own synchronization primitives for whatever reason.
Could be that you made your own OS and pthread's API ain't looking too good.
Could be that you want something faster than what your platform's libc provides through pthread.
Could be that you're doing it for fun (the best reason), it doesn't matter.

In a perfect world, you just write a simple spin-lock and be done with it.
But scheduling isn't that easy and such naive solutions can have pretty bad or awkward consequences.
In this post I'll walk through designing and understanding what makes a good mutex.
I'll assume you know how atomic memory operations and their memory orderings word (pretty thicc assumption, I know).

# Spin Locks

You love to see 'em. First, let's start off with that spin-lock idea from before:
```rs
// Excuse the pseudo-code looking zig hybrid.
// CAS() = `compareAndSwap() ?T` which returns null on success and the current value on failure

locked: bool = false

lock():
    while CAS_WEAK(&locked, false, true, Acquire, Relaxed) != null:
        YIELD() // assume this is _mm_pause() instead of sched_yield(). Almost never do the latter.

unlock():
    STORE(&locked, false, Release)
```
I'm not going to go into atomics and their orderings, but this is a basic spin-lock.
For those who write something like this unironically, I'm glad you're reading.
For those who noticed that I should be spinning with `LOAD` instead of CAS, *the bottom of this post is for you*.
For those who didn't understand or realize why, there's an opportunity to learn some stuff here.

So we know that a spin-lock tries to switch the `locked` flag from false to true, and spins until it can, but what do the threads look like to the machine when this happens? Each thread is continuously doing a `CAS` hoping that it will acquire the Mutex. On x86, this is a `lock cmpxchg` instruction which unfortunately acts a lot like `lock inc` or `lock xadd` in reference counting. Why is this unfortunate? Well, we need to dig into how caching works.

## Cache Coherency

Each CPU core on modern systems abstractly has its own cache / fast-access view of memory.
When you do an operation that reads or writes to memory, it happens on the cache and that needs a way to communicate these local changes to other CPU core caches and to main memory. This process is generally referred to as "cache coherency"; the dance of maintaining a coherent view of memory across caches.

A good protocol which explains this is [M.E.S.I.](https://en.wikipedia.org/wiki/MESI_protocol). You can read more about it if you want, but I just want to touch on some of it for this to make sense. Basically, caches work with (generally, 64 byte) chunks of memory called "lines". CPU cores send messages to each other to communicate the state of lines in caches. Here's an ***extremely simplified*** example:

* CPU-1 (C1) reads the line from main memory into their cache and tells everyone else. No one else has it in their cache so it stores the line as `Exclusive` (E).
* C2 does the same and gets told that C1 also has the line. Now both C1 and C2 store the line as `Shared` (S).
* C1 writes to the line and updates its local line state to `Modified` (M). It then tells others about this (C2) which update their view of the line to `Invalid` (I)
* C2 tries to read the line but it's now Invalid instead of Shared. C2 must now wait for C1 to stop modifying then refetch the line from main memory again as Shared (ignore that snooping exists plz).
* C1 writes the new line value to main memory and moves its view of the line from Modified to Shared again. Others (C2) can now read the new value from main memory.

When one CPU core is the only one interacting with a line, reads and writes to it are basically free. It can just update its local cache and keep the line as `Modified` for as long as it wants. The problem comes when other CPU cores wanna take a peek while its writing. If the original core is not writing, then everyone can read from their local cache seeing `Shared` with no overhead. When even one core writes, other caches need to be `Invalid`ated while waiting for the writer to flush to main memory. This expensive "write-back" process is known as "contention".

## Contention

Let's go back to the spin-lock's `lock cmpxchg` from earlier. This x86 instruction, along with the others listed, are knows as *read-modify-write* (RMW) atomics; The last bit being the most important. CPUs that are waiting for the mutex holder to unlock are continuously writing to the same line. This generates a lot of needless contention by invaliding the lines from other cores, making them wait for this unnecessary write then refetch from main memory only to see the mutex still locked and repeat. 

Instead, [AMD recommends](https://gpuopen.com/gdc-presentations/2019/gdc-2019-s2-amd-ryzen-processor-software-optimization.pdf) (slide 46) that you should spin by `LOAD`ing the line instead of `CAS`'ing it. That way, waiting cores only invalidate other's caches when the mutex is unlocked and can be acquired. Each waiting core still pays the cost of refetching from main memory once it changes, but at least they only refetch when the mutex is unlocked or if a new core is just starting to lock. 

```rs
try_lock():
    return CAS_STRONG(&locked, false, true, Acquire, Relaxed) == null

lock():
    // Assume the mutex is unlocked. Proper mutex usage means this should be the average case
    if try_lock(): return

    do: 
        while not LOAD(&locked, Relaxed):
            YIELD()
    while not try_lock()
```

## Unbounded Spinning

But remember that we're designing a userspace Mutex here. And in userspace, we deal in threads not CPU cores. Many threads are queued up to run on a smaller amount of cores so just spinning like that can be pretty bad. There's a few reasons why you shouldn't use this sort of spin-lock, whether you're in userspace or even the kernel.

Kernel spin-locks at the CPU core level generally do more than just spin. They also have to disable hardware interrupts to avoid the spinning code being switched to an interrupt handler. If you're at the kernel level, you can also put the core to a deeper sleep state or choose to do other stuff while you're spinning. AFAIK, kernel spin-locks also prefer explicit queueing over single bools for reasons I'll get into later.

Userspace spin-locks suffer from accidental blocking. If the mutex lock owner was descheduled, the waiting thread will spin for its entire quota, never knowing that they themselves are preventing the lock owner from running on that core to actually unlock the mutex. You could say *"have `YIELD()` just reschedule the waiting thread"* but this assumes that 1) the lock owner is scheduled to the same core for rescheduling to give it a chance 2) that `YIELD()` will reach across cores to steal runnable threads if the lock owner isn't local and 3) that `YIELD()` will actually yield to your desired thread. 

The first isn't always true due to, uh oh, 2022 high core counts and sophisticated/non-deterministic OS scheduling heuristics. The second isn't currently true for Linux [`sched_yield`](https://elixir.bootlin.com/linux/latest/source/kernel/sched/core.c#L8257) or Windows' [`SwitchToThread`](https://docs.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-switchtothread). The third doesn't really fly as your program is likely sharing the entire machine with other programs or virtual machines in these times. Linus Torvalds goes into more passionate detail [here](https://www.realworldtech.com/forum/?threadid=189711&curpostid=189752).

Don't get me wrong, spinning *can* be a good thing for a Mutex when it comes to latency. If the lock owner releases it "soon" while there's someone spinning, they can acquire the mutex without having to go to sleep and get woken up (which are relatively expensive operations). The problem is "spinning for too long" or, in our worst case, spinning theoretically indefinitely / without bound.

What we want instead is a best of both worlds; Spin for a little bit assuming we can minimize acquire latency. Then, if that doesn't work, queue the thread onto the Mutex so the OS can schedule other threads (possibly the lock owner) on our CPU core. This is called ["adaptive spinning"](https://lwn.net/Articles/314512/) in the literature. Sketching that out, it would look something like this:

```rs
lock():
    if try_lock(): return

    for i in 0..SPIN_BOUND:
        YIELD()
        if try_lock(): return

    do:
        queue_thread_and_block_if_locked()
    while not try_lock()

unlock():
    STORE(&locked, false, Release)
    dequeue_thread_and_unblock_if_any()
```

# Queued Locks

Enter queued locks, or "making the implicit thread queueing explicit". These type of locks represent each waiting task (whether it's' a thread in userspace or a core in the kernel) as a linked list node waiting for the mutex to be unlocked. Why a linked lists? Well, having to dynamically heap allocate for a Mutex is kind of cringe. Also, managing such array buffers would require concurrency reclamation (read: GC) and synchronized access (read: [Yo dawg](https://knowyourmeme.com/memes/xzibit-yo-dawg), I heard you like locks. So I put a lock in your lock). Besides heap allocation, linked lists are also a good choice for representing unbounded, lock-free data structures. We'll use a [Treiber stack](https://en.wikipedia.org/wiki/Treiber_stack) for the thread queue.

We also need a way to put the thread to sleep and wake it up. This part relies fully on the platform (OS/runtime) we're running on. The abstraction we can use is an [`Event`](https://en.wikipedia.org/wiki/Event_(synchronization_primitive).) where the waiting thread calls `wait()` and the notifying thread calls `set()`. The waiter blocks until the event is set, returning early if it was already set. It only needs have a single-producer-single-consumer (SPSC) relationship as we'll see in a moment. There's various ways to implement the `Event`:

- On Linux, we'll use a local 32-bit integer + [`futex`](https://man7.org/linux/man-pages/man2/futex.2.html).
- On OpenBSD, FreeBSD, DragonflyBSD we can used the scuffed futex apis [`futex`](https://man.openbsd.org/futex.2), [`_umtx_op`](https://www.freebsd.org/cgi/man.cgi?query=_umtx_op&sektion=2&n=1), and [`umtx_sleep`](https://man.dragonflybsd.org/?command=umtx&section=2) respectively.
- On NetBSD, we can use [`lwp_park`](https://man.netbsd.org/_lwp_park.2)/[`lwp_unpark`](https://man.netbsd.org/_lwp_unpark.2) which are really nice for single-thread wait/wake mechanisms.
- On Windows, we *could* use [`WaitOnAddress`](https://docs.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-waitonaddress) but we're cool, fast, and instead use the undocumented (but documented by the entire internet) [`NtWaitForAlertByThreadId`](https://docs.rs/ntapi/latest/ntapi/ntpsapi/fn.NtWaitForAlertByThreadId.html)/[`NtAlertThreadByThreadId`](https://docs.rs/ntapi/latest/ntapi/ntpsapi/fn.NtAlertThreadByThreadId.html) that WaitOnAddress calls internally anyway.
- On pretty much everywhere else, the sync primitives kindof suck and were stuck making a binary semaphore using [`pthread_mutex_t`](https://pubs.opengroup.org/onlinepubs/007908799/xsh/pthread_mutex_lock.html)/[`pthread_cond_t`](https://pubs.opengroup.org/onlinepubs/007908799/xsh/pthread_cond_wait.html).
- On Darwin (macOS, iOS, giveUsFutexOS) we could be safe and stick with pthread or be cheeky/fast and use [`__ulock_wait2`](https://github.com/apple/darwin-xnu/blob/main/bsd/sys/ulock.h#L66-L67)/[`__ulock_wake`](https://github.com/apple/darwin-xnu/blob/main/bsd/sys/ulock.h#L68) while risking getting rejected from the AppStore for linking to undocumented APIs.

Let's combine this Event primitive with our treiber stack to create our first, lock-free, queued Mutex.

```rs
type Node:
    next: ?*Node = null
    event: Event = .{}

type Stack:
    top: ?*Node = null

    push(node: *Node):
        node.next = LOAD(&top, Relaxed)
        loop:
            node.next = CAS_WEAK(&top, node.next, node, Release, Relaxed) orelse return
    
    pop() ?*Node:
        node = LOAD(&top, Acquire)
        while node |n|:
            node = CAS_WEAK(&top, node, n.next, Acquire, Acquire) orelse break
        return node

waiters: Stack = .{}

lock():
    ...
    do:
        node = Node{}
        waiters.push(&node)
        node.event.wait()
    while not try_lock()

unlock():
    node = waiters.pop() // stack is single-consumer so pop before unlocking
    STORE(&locked, false, Release)
    if node |n| n.event.set()
```

Great, looks good! But there's an issue here. Remember that I named the queueing/blocking function `queue_thread_and_block_if_locked()`? We're missing that last part. A thread could fail the first try_lock(), go queue itself to block, the lock owner unlocks the Mutex while its queueing, then the thread blocks even when the Mutex is unlocked and now we have a dead-lock. We need to make sure that the queueing of the thread is atomic w.r.t. the Mutex being locked/unlocked and we can't do that with separate atomic variables here so we gotta get clever.

## Word-sized Atomics

If both states need to be atomic, let's just put them in the same atomic variable! The largest and most cross-platform atomic operations work on the machines pointer/word size (`usize`). So to get this to work, we need to encode both the `waiting` treiber stack and the `locked` state in the same `usize`.

One thing to know about memory is that all pointers have whats called an ["alignment"](https://en.wikipedia.org/wiki/Data_structure_alignment). Pointers themselves are canonically numbers which index into memory at the end of the day (I don't care what strict provenance has you believin'). These "numbers" tend to be a mutiple of some power of two thats dictated by their `type` in source code or the accesses needed to be performed by them. This power of two multiple is known as alignment. `0b1001` is aligned to 1 byte while `0b0010` is aligned to 2 bytes (theres N-1 `0` bits to the right of the farthest/lowest bit).

We can take advantage of this to squish together our states. If we designate the first/0th bit of the `usize` to represent the `locked` boolean, and have everything else represent the stack top Node pointer, this could work. We must just ensure that the Node's address is aligned to at least 2 bytes (so that the last bit in a Node's address is always 0 for the locked bit). 

Queueing and locking have now been combined into the same atomic step. When we unlock, we can choose to dequeue any amount of waiters we want before unlocking. This gives the guarantee to `Event` that only one thread (the lock holder trying to unlock) can call `set` to allow SPSC-usage optimizations. Our Mutex now looks like this:

```rs
type Node aligned_to_at_least(2):
    ...

state: usize = 0

const locked_bit = 0b1
const node_mask = ~locked_bit

try_lock():
    s = LOAD(&state, Relaxed)
    while s & locked_bit == 0:
        s = CAS_WEAK(&state, s, s | locked_bit, Acquire, Relaxed) orelse return true
    return false

lock():
    // fast path: assume mutex is unlocked
    s = CAS_WEAK(&state, 0, locked_bit, Acquire, Relaxed) orelse return

    // bounded spinning trying to acquire
    for i in 0..SPIN_BOUND:
        YIELD()
        s = LOAD(&state, Relaxed)
        while s & locked_bit == 0:
            s = CAS_WEAK(&state, s, s | locked_bit, Acquire, Relaxed) orelse return

    loop:
        // try to acquire if unlocked
        while s & locked_bit == 0:
            s = CAS_WEAK(&state, s, s | locked_bit, Acquire, Relaxed) orelse return 
        
        // try to queue & block if locked (fails if unlocked)
        node = Node{}
        node.next = ?*Node(s & node_mask)
        new_s = usize(&node) | (s & ~node_mask)
        s = CAS_WEAK(&state, s, new_s, Release, Relaxed) orelse blk:
            node.event.wait()
            break :blk LOAD(&state, Relaxed)

unlock():
    // fast path: assume no waiters
    s = CAS_WEAK(&state, locked_bit, 0, Release, Acquire) orelse return

    loop:
        top = *Node(s & node_mask)
        new_s = usize(top.next) | (s & ~locked_bit)
        s = CAS_WEAK(&state, s, new_s, Release, Acquire) orelse:
            return top.event.set()
```

----

At this point, we're basically done. You can now take this Mutex and ship it. After all, this is [what Golang did](https://github.com/golang/go/blob/master/src/runtime/lock_sema.go#L26-L129). This satisfies the goal of the blog post so this is a good point if you want to just click off or take a break. The following is only optimizations over this idea which I believe are the true bread and butter. But enough stalling.

----

## Optimizing Spinning: Shared Bound

Still reading? Great. Let's see what we can improve. We haven't bikeshed enough yet on optimizations and we can willingly/correctly ignore the phrase ["premature optimization is the root of all evil"](http://wiki.c2.com/?PrematureOptimization). The easiest one to tackle would be how we spin. Remember when I said spinning could be a good thing as long as it's bounded? We'll we're doing a bit too much of it at the moment (even without knowing what `SPIN_BOUND` is).

Imagine the following scenario: T1 locks the mutex. T2 tries to as well but can't and starts spinning. T2 queues itself on the Mutex and goes to sleep. T3 also tries to lock the mutex and starts spinning. You ask, T3, [*"why are you spinning?"*](https://knowyourmeme.com/memes/why-are-you-running). You could say "in case T1 unlocks soon", but if it does it'll likely have to compete with T2 that T1 will wake. I've found that, in practice, it's better to avoid spinning more than necessary for all threads. Let's add this micro-optimization:

```rs
lock():
    // fast path: assume mutex is unlocked
    s = CAS_WEAK(&state, 0, locked_bit, Acquire, Relaxed) orelse return
    spin = SPIN_BOUND

    loop:
        // try to acquire if unlocked
        while s & locked_bit == 0:
            s = CAS_WEAK(&state, s, s | locked_bit, Acquire, Relaxed) orelse return 

        // spin only if there's no one waiting
        if (spin > 0) and (s & node_mask == 0):
            spin -= 1
            YIELD()
            continue
        ...
```

Now, we only spin if there's no other thread waiting for the Mutex. This means that the total amount of time spent spinning is `SPIN_BOUND` but counted against all threads accessing the Mutex. This decreases cycles wasted with unnecessary spinning and reduces possible contention when theres an over-subscription of threads waiting on a locked Mutex.

## Optimizing Locking: Code Generation

That spinning optimization was just a small code restructure. In order to get any more wins, we gotta dig deep into what the Mutex actually looks like to the machine at runtime. The changes we're making now are in the realm of CPU execution. One is that we can make the fast paths more inline-able. The other is that we can avoid the fast path failing spuriously.

At the moment, we're using `CAS` with the expectation that the lock is zero'd for the fast path. While this is technically correct, it isn't optimal. The CAS can fail not only when the Mutex is locked, but also when a waiter get's queued. On platforms that support it, we can instead use atomics that only fail if the `locked_bit` is set:

```rs
lock_fast():
    // Assuming LLVM 15+ with optimizations, `OR(bit) & bit == 0` compiles to:
    // `lock bts` on x86
    // `ldseta` on aarch64/armv8 on 8.2+
    // `amoor.d.aq` on riscv64
    // some LL/SC loop but thats fine as we don't care about those archs for this sake.
    return OR(&state, locked_bit) & locked_bit == 0
```

These instructions are (effectively) wait-free: there's no retrying and it always makes progress. They also sometimes require less code for both setup and branching on the result than `CAS` which makes them perfect candidates for inlining by optimizing compilers. We can give the compiler even more hints to make sure the fast path is inlined:

```rs
@inline lock():
    if not lock_fast(0): lock_slow()

@cold lock_slow():
    spin = SPIN_BOUND
    loop:
        while s & locked_bit == 0:
            if lock_fast(s): return
            s = LOAD(&state, Relaxed)
        ...
```

## Optimizing Contention: Backoff

This optimization is optional and sort of a hit or miss. Basically, our goal is to improve the total throughput of the Mutex and one of the properties that affects this is contention on the `usize`. Contention increases in overhead the more atomic operations are being done on the same cache line in a smaller amount of time. So if we increase the time period between atomic operations which contend on a cache line, we thereby decrease contention to it.

Increased time between operations can be simulated by yielding a lot. We don't know exactly how many times to yield after a failed contended operation, but we know that it could help (especially for `CAS`). There's a wide variety of backoff methods from linear spinning (i.e. spin for N after every failed acquire), to exponential spinning, and even randomized spinning. [Amazon](https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/) wrote an interesting post about this. 

For now, we'll just stick with *simple exponential* as it provides some dynamism and works on the idea that "more failed attempts = it's really contended = delay longer". Make sure that the yields happen before any further atomic interaction, even a simple `LOAD`. Remember that loads to `Modified` lines then have to wait for the line owner to flush to memory (simplified). The backoff bound also shouldn't be shared across threads since the cost of contention is unique to each running CPU core. This is what it could look like:

```rs
@cold lock_slow():
    ...
    backoff = 1
    loop:
        while s & locked_bit == 0:
            if lock_fast(s): return

            backoff = min(backoff * 2, BACKOFF_BOUND)
            for i in 0..backoff:
                YIELD()

            s = LOAD(&state, Relaxed)
```

## Optimizing Unlocking: Queue Synchronization

At this point we're almost out of the realm for free/small wins. Profiling can't really help you here. Now, we sort of have to start re-evaluating the algorithmic properties of the Mutex to improve things. This is the coolest part IMO.

What I meant by "almost out of the realm" is that there's still a previous trick we can reuse. It's just tricky to actually reuse it; You may notice that the `unlock()` path still relies on a `CAS` loop that can spuriously fail and contend with threads that are getting queued up. This is still unfortunate. Let's have `unlock()` immediately let go of the `locked_bit` before it dequeues a Node to unblock:

```rs
@inline unlock():
    // SUB instead of AND(~locked_bit) as the former is wait-free on x86 (lock xadd)
    s = SUB(&state, locked_bit, Release)
    if s & node_mask != 0: unlock_slow()

@cold unlock_slow():
    // passing in the SUB() state doesn't help in practice & increases inline size
    s = LOAD(&state, Relaxed)
    ...
```

The unlock() path is now inline-able with a pretty small comparison check to jump to the slow path. This is great from an optimizing compiler's perspective. The mutex also isn't held longer than necessary from having to compete with threads enqueueing themselves to the top of the stack. Less time spent "locked" means another thread could grab it sooner and improve the throughput. Look's great! ... right? Well there's a reason this wasn't such an obvious/easily applicable optimization.

You may notice that dequeuing is no longer a single-consumer activity but can race between multiple threads! Consider the following:

`A M O G U S`

Now that you're paying attention, consider the following:

* Thread-1 (T1) locks the mutex and T2 gets queued.
* T1 unlocks the mutex and starts to pop from treiber stack.
* T3 locks the mutex, unlocks it, and dequeues T2 to wake it.
* T2 wakes, locks the mutex, and returns from lock().
* T1 tries to deref `top_node.next` where the node was T2 which already woke up and returned (UAF)

We can't be here having UAFs in our mutex. We risk getting called immoral on HN and Twitter. In order to safely dequeue without holding the `locked_bit`, we just have to synchronize the queue access with another bit that's acquired and released. Let's call it `queue_bit`.

```rs
const locked_bit = 0b01
const queue_bit  = 0b10
const node_mask  = ~(locked_bit | queue_bit)

// bump alignment as now 2 bits are in-use
type Node aligned_to_at_least(4):
    ...
```

When the mutex is unlocked, it'll try to grab the `queue_bit` to dequeue and unblock a thread. If the mutex gets locked again while we're trying to grab the `queue_bit`, we should just not. It'll be better if that mutex owner is the one to dequeue instead as it saves us going through all of that and lowers unnecessary contention. If the mutex gets locked while we're dequeueing, release the `queue_bit` for similar reasons. We now have this:

```rs
@inline unlock():
  s = SUB(&state, locked_bit, Release)
  if (s & node_mask != 0) and (s & queue_bit == 0):
    unlock_slow()

@cold unlock_slow():
    // grab queue_bit if its unset + theres something to dequeue + mutex not locked 
    s = LOAD(&state, Relaxed)
    loop:
        if (s & node_mask == 0) or (s & (locked_bit | queue_bit) != 0): return
        s = CAS_WEAK(&state, s, s | queue_bit, Acquire, Relaxed) orelse break

    // this is separated out for later
    dequeue_and_unblock(s | queue_bit)

dequeue_and_unblock(s):
    loop:
        while s & locked_bit != 0:
            s = CAS_WEAK(&state, s, s & ~queue_bit, Release, Acquire) orelse return
        
        node = *Node(s & node_mask)
        new_s = usize(node.next) | (s & ~(node_mask | queue_bit))
        s = CAS_WEAK(&state, s, new_s, Release, Acquire) orelse return node.event.set()
```

There's one more small inefficiency. The `unlock()` path now contains two comparisons instead of one. As I should say if I were machine woke, "Do Better". We can add another bit to the state which denotes "has node pointer" instead of just checking the `node_mask`. This bit will be set when a node is enqueued and unset with the last node is dequeued. Lets call it `pending_bit`.

```rs
const locked_bit  = 0b001
const queue_bit   = 0b010
const pending_bit = 0b100
const node_mask   = ~(locked_bit | queue_bit | pending_bit)

// alignment bumped again (Nodes are getting thicc)
type Node aligned_to_at_least(8):
    ...

@inline unlock():
  s = SUB(&state, locked_bit, Release)
  if s & (queue_bit | pending_bit) == pending_bit:
    unlock_slow()

@cold unlock_slow():
    s = LOAD(&state, Relaxed)
    loop:
        if s & (locked_bit | queue_bit | pending_bit) != pending_bit: return
        s = CAS_WEAK(&state, s, s | queue_bit, Acquire, Relaxed) orelse break
    dequeue_and_unblock(s | queue_bit)
```

Much better! 

## Optimizing Queueing: FIFO Ordering

## Optimizing Unblocking: Queue Scheduling

# Locking It Up

So, this has been quite the journey but I gotta be real with you; Don't actually use this thing if you can afford not to... While it's pretty competitive with all the optimizations we've done, the OS/platform developers generally do it better. The big 3 all do special optimizations that I can't hope to ever account for in such an abstract Mutex implementation:

A basic 3-state lock on Linux and the other BSDs that have `futex` can be faster than what we have here. Not only does it require less updates to the userspace atomic (which means less line contention), but queueing, thread blocking, and the synchronization of all that is handled by the kernel which can do it better than userspace since it works with cores and all. 

Darwin's `os_unfair_lock` uses thread ids instead of queues. Storing the thread id means they always know which thread currently holds the mutex lock. By deferring blocking and contention handling to the kernel via `__ulock_wait(UL_UNFAIR_LOCK)`, this allows it to handle [priority inversion](https://en.wikipedia.org/wiki/Priority_inversion), optimized thread queueing, and yielding to the lock owner directly if it was descheduled.

Windows' `SRWLOCK` is similar to our implementation but does so much more. The kernel maps a read-only chunk of memory to all user processes called [`KUSER_SHARED_DATA`](https://docs.microsoft.com/en-us/windows-hardware/drivers/ddi/ntddk/ns-ntddk-kuser_shared_data) which exposes useful, kernel-updated like `UnparkedProcessorCount` to know if theres other CPUs running to avoid spinning, `CyclesPerYield` to know the optimal amount of `YIELD()`s for backoff, `ProcessorFeatures` to know if the CPU supports spinning with optimized instructions like [`mwait`](https://www.felixcloutier.com/x86/mwait) that waits until timeout or memory is written/updated, and much more.

The main places I'd see this mutex being useful are if any of the following hold true:
* Blocking and unblocking threads is *really* expensive. This mutex tries it's hardest to avoid waking threads and only does so when it thinks the target has a chance of acquiring it.
* The synchronization primitives available for your platform are not performance optimized. I'm not naming names here, but ya'll know who you are..
* You are the platform author and want to try offering a scalable mutex without doing extra research. In that case, you can take the algorithm and plug in your own Event type which blocks and unblocks your notion of tasks/threads.

## Closing Notes

I've published the lock [here](#TODO) along with highly detailed benchmarks against OS provided locks to get an idea of how it performs in practice. I've also made a Rust crate called [usync](https://lib.rs/crates/usync) which implements a bunch of word-sized synchronization primitives including this one. Feel free to port the code to whatever language you prefer and/or plug in your own `Event` type to support your platform.

Meta Discussion: I tried out a new writing style this time! My previous posts were focused more about packing as much information as possible. This time, it was that but I added some personality (may or may not be a good thing). Let me know if you preferred this style or not. This also took about a week write/correct but about 1-2 years to experience/gather. Stuff this detailed will likely be a rarity but it was still fun to make. See you in liek a year.