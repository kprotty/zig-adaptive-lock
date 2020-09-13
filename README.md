# zig-adaptive-lock
Benchmarking a faster std.Mutex implementation for Zig

Run `zig run bench.zig` to get a help screen for benchmarks.

### examples:
* benchmark locks for throughput using 1 thread:
    - `zig run bench.zig throughput -t=1`
* benchmark locks for throughput using 1, 3, 4, and 5 threads
    - `zig run bench.zig throughput -t 1,3-5`
* benchmark locks for throughput spending 50 microseconds in lock and 10 nanoseconds outside lock (unlocked)
    - `zig run bench.zig throughput -l 10us -u 10ns`
* benchmark locks for throughput spending a random time between 1 microsecond and 1 millisecond in lock
    - `zig run bench.zig throughput -l 1us-1ms`

demo benchmark:
- `zig run hybrid.zig -lc --release-fast -- throughput -l 10ns-100ns -u 10ns-500ns -t 2,6,13,16,32`