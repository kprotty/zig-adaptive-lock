const std = @import("std");
const builtin = @import("builtin");

const locks = .{
    @import("locks/spin_lock.zig"),
    @import("locks/futex_lock.zig"),
    @import("locks/os_lock.zig"),
    @import("locks/queue_lock.zig"),
};

// Circumvent going through std.debug.print
// as when theres a segfault that happens while std.debug.stderr_mutex is being held,
// then the panic handler will try and grab the mutex again which will result in a dead-lock.
fn print(comptime fmt: []const u8, args: anytype) void {
    nosuspend std.io.getStdErr().writer().print(fmt, args) catch return;
}

fn help() void {
    print("{s}", .{
        \\Usage: zig run bench.zig -OReleaseFast [measure] [threads] [locked] [unlocked]
        \\
        \\where:
        \\ [measure]:  [csv:time]         \\ List of time spent measuring for each mutex benchmark
        \\ [threads]:  [csv-ranged:count] \\ List of thread counts for each benchmark
        \\ [locked]:   [csv-ranged:time]  \\ List of time spent inside the lock for each benchmark
        \\ [unlocked]: [csv-ranged:time]  \\ List of time spent outside the lock for each benchmark
        \\
        \\where:
        \\ [count]:             {usize}
        \\ [time]:              {u64}[time_unit]
        \\ [time_unit]:         "ns" | "us" | "ms" | "s"
        \\ [csv-ranged:{rule}]: [csv:(ranged:{rule})]
        \\
        \\ [csv:{rule}]:
        \\      | {rule}             \\ single value
        \\      | {rule} "," {rule}  \\ multiple permutations
        \\
        \\ [ranged:{rule}]:
        \\      | {rule}            \\ single value
        \\      | {rule} "-" {rule} \\ randomized value in range
    });
}

pub fn main() !void {
    const global_allocator = blk: {
        if (builtin.link_libc) {
            break :blk std.heap.c_allocator;
        }

        if (builtin.target.os.tag == .windows) {
            const Static = struct { var heap = std.heap.HeapAllocator.init(); };
            break :blk Static.heap.allocator();
        }

        const Static = struct { var gpa = std.heap.GeneralPurposeAllocator(.{}){}; };
        break :blk Static.gpa.allocator();
    };

    var arena = std.heap.ArenaAllocator.init(global_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var measures = std.ArrayList(Duration).init(allocator);
    defer measures.deinit();

    var threads = std.ArrayList(usize).init(allocator);
    defer threads.deinit();

    var locked = std.ArrayList(WorkUnit).init(allocator);
    defer locked.deinit();

    var unlocked = std.ArrayList(WorkUnit).init(allocator);
    defer unlocked.deinit();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.skip(); // ignore self exe
    Parser.parse(&args, &measures, Parser.parse_measure) catch return help();
    Parser.parse(&args, &threads, Parser.parse_thread) catch return help();
    Parser.parse(&args, &locked, Parser.parse_work_unit) catch return help();
    Parser.parse(&args, &unlocked, Parser.parse_work_unit) catch return help();

    const multiplier = try WorkUnit.ns_per_work();

    for (unlocked.items) |work_unlocked| {
        for (locked.items) |work_locked| {
            for (threads.items) |num_threads| {
                for (measures.items) |measure| {
                    print("measure={s} threads={} locked={} unlocked={}\n{s}\n", .{
                        measure,
                        num_threads,
                        work_locked,
                        work_unlocked,
                        "-" ** 90,
                    });

                    // headers
                    print("{}\n", .{Result{}});

                    inline for (locks) |lock_impl| {
                        print("{}\n", .{
                            try bench(lock_impl.Lock, Config{
                                .global_allocator = global_allocator,
                                .allocator = allocator,
                                .measure = measure.ns,
                                .num_threads = num_threads,
                                .work_locked = work_locked.scaled(multiplier),
                                .work_unlocked = work_unlocked.scaled(multiplier),
                            }),
                        });
                    }

                    print("\n", .{});
                }
            }
        }
    }
}

const Parser = struct {
    fn parse(args: *std.process.ArgIterator, results: anytype, comptime resolve_fn: anytype) !void {
        const arg = args.next() orelse return error.ExpectedArg;
        var it = std.mem.tokenize(u8, arg, ",");
        while (it.next()) |item| {
            const sep = std.mem.indexOf(u8, item, "-");
            const a = item[0..(sep orelse item.len)];
            const b = if (sep) |s| item[s + 1..] else null;
            try resolve_fn(results, a, b);
        }
    }

    fn parse_measure(results: *std.ArrayList(Duration), a: []const u8, b: ?[]const u8) !void {
        if (b != null) return error.MeasureDoesNotSupportRanges;
        const ns = try parse_duration(a);
        try results.append(Duration{ .ns = ns });
    }

    fn parse_thread(results: *std.ArrayList(usize), a: []const u8, b: ?[]const u8) !void {
        var start = try std.fmt.parseInt(usize, a, 10);
        const end = if (b) |e| try std.fmt.parseInt(usize, e, 10) else start;

        if (start > end) return error.InvalidThreadRange;
        while (start <= end) : (start += 1) {
            try results.append(start);
        }
    }

    fn parse_work_unit(results: *std.ArrayList(WorkUnit), a: []const u8, b: ?[]const u8) !void {
        var end: ?u64 = null;
        var start = try parse_duration(a);

        if (b) |e| {
            end = try parse_duration(e);
            if (start >= end.?) return error.InvalidDurationRange;
        }

        const work_unit = WorkUnit{ .from = start, .to = end };
        try results.append(work_unit);
    }

    fn parse_duration(text: []const u8) !u64 {
        const mult: u64 = blk: {
            if (std.mem.endsWith(u8, text, "ns")) break :blk 1;
            if (std.mem.endsWith(u8, text, "us")) break :blk std.time.ns_per_us;
            if (std.mem.endsWith(u8, text, "ms")) break :blk std.time.ns_per_ms;
            if (std.mem.endsWith(u8, text, "s")) break :blk std.time.ns_per_s;
            return error.InvalidTimeUnit;
        };

        const unit_len = @as(usize, 1) + @boolToInt(mult != std.time.ns_per_s);
        const value = try std.fmt.parseInt(u64, text[0..text.len - unit_len], 10);
        return std.math.mul(u64, value, mult);
    }
};

const Duration = struct {
    ns: u64,

    pub fn format(duration: Duration, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;

        if (duration.ns < 1_000) {
            return std.fmt.format(writer, "{d}ns", .{duration.ns});
        } else if (duration.ns < 1_000_000) {
            return std.fmt.format(writer, "{d}us", .{duration.ns / 1_000});
        } else if (duration.ns < 1_000_000_000) {
            return std.fmt.format(writer, "{d}ms", .{duration.ns / 1_000_000});
        } else {
            return std.fmt.format(writer, "{d}s", .{duration.ns / 1_000_000_000});
        }
    }
};

const WorkUnit = struct {
    from: u64,
    to: ?u64,

    pub fn format(work_unit: WorkUnit, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;

        const from_duration = Duration{ .ns = work_unit.from };
        try std.fmt.format(writer, "{}", .{from_duration});

        if (work_unit.to) |to| {
            const to_duration = Duration{ .ns = to };
            try std.fmt.format(writer, "-{}", .{to_duration});
        }
    }

    fn scaled(work_unit: WorkUnit, multiplier: u64) WorkUnit {
        return WorkUnit{
            .from = work_unit.from * multiplier,
            .to = if (work_unit.to) |to| to * multiplier else null, 
        };
    }

    fn count(work_unit: WorkUnit, xorshift: *u64) u64 {
        const min = work_unit.from;
        const max = work_unit.to orelse return min;

        var xs = xorshift.*;
        xs ^= xs << 13;
        xs ^= xs >> 7;
        xs ^= xs << 17;
        xorshift.* = xs;

        return std.math.max(1, (xs % (max - min + 1)) + min);
    }

    fn run(iterations: u64) void {
        var i = iterations;
        while (i != 0) : (i -= 1) work();
    }

    fn work() void {
        std.atomic.spinLoopHint();
    }

    fn ns_per_work() !u64 {
        var timer = try std.time.Timer.start();

        var attempts: [10]f64 = undefined;
        for (attempts) |*attempt| {
            const num_works = 100_000;

            const start = timer.read();
            WorkUnit.run(num_works);
            const elapsed = @intToFloat(f64, timer.read() - start);

            attempt.* = elapsed / @as(f64, num_works);
        }

        var sum: f64 = 0;
        for (attempts) |attempt| sum += attempt;
        return std.math.max(1, @floatToInt(u64, sum / @intToFloat(f64, attempts.len)));
    }
};

const Config = struct {
    global_allocator: std.mem.Allocator,
    allocator: std.mem.Allocator,
    measure: u64,
    num_threads: usize,
    work_locked: WorkUnit,
    work_unlocked: WorkUnit,
};

fn bench(comptime Lock: type, config: Config) !Result {
    const workers = try config.allocator.alloc(Worker, config.num_threads);
    defer config.allocator.free(workers);

    var spawned: usize = 0;
    defer for (workers[0..spawned]) |*w| w.arena.deinit();

    {
        const LockStorage = extern struct {
            _cache_padding_0: [std.atomic.cache_line]u8 = undefined,
            lock_memory: [@sizeOf(Lock)]u8 align(@alignOf(Lock)) = undefined,
            _cache_padding_1: [std.atomic.cache_line]u8 = undefined,
        };

        var storage = LockStorage{};
        const lock = @ptrCast(*Lock, @alignCast(@alignOf(Lock), &storage.lock_memory));
        lock.init();
        defer lock.deinit();

        var guard = Guard{};
        defer {
            guard.stop();
            for (workers[0..spawned]) |w| w.thread.join();
        }
        
        const runFn = Worker.runner(Lock).run;
        while (spawned < workers.len) : (spawned += 1) {
            workers[spawned] = .{
                .thread = undefined,
                .timer = try std.time.Timer.start(),
                .arena = std.heap.ArenaAllocator.init(config.global_allocator),
                .latencies = std.ArrayList(u64).init(workers[spawned].arena.allocator()),
            };
            workers[spawned].thread = try std.Thread.spawn(.{}, runFn, .{
                &workers[spawned],
                lock,
                &guard,
                config.work_locked,
                config.work_unlocked,
            });
        }

        guard.start();
        std.time.sleep(config.measure);
    }

    var latencies = std.ArrayList(u64).init(config.allocator);
    defer latencies.deinit();

    var sum: u64 = 0;
    var max: u64 = 0;
    var min: u64 = std.math.maxInt(u64);

    for (workers) |w| {
        sum += w.iters;
        min = std.math.min(min, w.iters);
        max = std.math.max(max, w.iters);
        try latencies.appendSlice(w.latencies.items);
    }

    const mean = @intToFloat(f64, sum) / @intToFloat(f64, workers.len);
    var stdev: f64 = 0;
    for (workers) |w| {
        const r = @intToFloat(f64, w.iters) - mean;
        stdev += r * r;
    }
    if (workers.len > 1) {
        stdev /= @intToFloat(f64, workers.len - 1);
        stdev = @sqrt(stdev);
    }

    const items = latencies.items;
    const cmp = comptime std.sort.asc(u64);
    std.sort.sort(u64, items, {}, cmp);

    var latency_percentiles: [2]u64 = undefined;
    for ([_]f64{ 50.0, 99.0 }) |percentile, index| {
        const p = percentile / 100.0;
        const i = @round(p * @intToFloat(f64, items.len));
        const v = std.math.min(items.len, @floatToInt(usize, i));
        latency_percentiles[index] = items[v - 1];
    }

    const latency_p50 = latency_percentiles[0];
    const latency_p99 = latency_percentiles[1];
    
    return Result{
        .name = Lock.name,
        .mean = mean,
        .stdev = stdev,
        .min = @intToFloat(f64, min),
        .max = @intToFloat(f64, max),
        .sum = @intToFloat(f64, sum),
        .@"lat. <50%" = latency_p50,
        .@"lat. <99%" = latency_p99,
    };
}

const Result = struct {
    name: ?[]const u8 = null,
    mean: ?f64 = null,
    stdev: ?f64 = null,
    min: ?f64 = null,
    max: ?f64 = null,
    sum: ?f64 = null,
    @"lat. <50%": ?u64 = null,
    @"lat. <99%": ?u64 = null,

    pub fn format(result: Result, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;

        const name: []const u8 = result.name orelse "name";
        try std.fmt.format(writer, "{s:<18} |", .{ name });

        inline for (.{ "mean", "stdev", "min", "max", "sum" }) |field| {
            if (@field(result, field)) |value| {
                if (value < 1_000) {
                    try std.fmt.format(writer, " {d:>6} |", .{@round(value)});
                } else if (value < 1_000_000) {
                    try std.fmt.format(writer, " {d:>5.0}k |", .{value / 1_000});
                } else if (value < 1_000_000_000) {
                    try std.fmt.format(writer, " {d:>5.2}m |", .{value / 1_000_000});
                } else {
                    try std.fmt.format(writer, " {d:>5.2}b |", .{value / 1_000_000_000});
                }
            } else {
                try std.fmt.format(writer, " {s:>6} |", .{field});
            }
        }

        inline for (.{ "lat. <50%", "lat. <99%" }) |field| {
            if (@field(result, field)) |value| {
                if (value < 1_000) {
                    try std.fmt.format(writer, " {:>7}ns |", .{value});
                } else if (value < 1_000_000) {
                    try std.fmt.format(writer, " {d:>7.0}us |", .{@intToFloat(f64, value) / 1_000});
                } else if (value < 1_000_000_000) {
                    try std.fmt.format(writer, " {d:>7.0}ms |", .{@intToFloat(f64, value) / 1_000_000});
                } else {
                    try std.fmt.format(writer, " {d:>7.2}s |", .{@intToFloat(f64, value) / 1_000_000_000});
                }
            } else {
                try std.fmt.format(writer, " {s:>6} |", .{field});
            }
        }
    }
};

const Guard = struct {
    state: std.atomic.Atomic(u32) = std.atomic.Atomic(u32).init(0),

    fn wait(guard: *const Guard) void {
        while (guard.state.load(.Acquire) == 0) {
            std.Thread.Futex.wait(&guard.state, 0);
        }
    }

    fn start(guard: *Guard) void {
        guard.state.store(1, .Release);
        std.Thread.Futex.wake(&guard.state, std.math.maxInt(u32));
    }

    fn running(guard: *const Guard) bool {
        return guard.state.load(.Acquire) == 1;
    }

    fn stop(guard: *Guard) void {
        guard.state.store(2, .Release);
    }
};

const Worker = struct {
    iters: u64 = 0,
    thread: std.Thread,
    timer: std.time.Timer,
    latencies: std.ArrayList(u64),
    arena: std.heap.ArenaAllocator,

    fn runner(comptime Lock: type) type {
        return struct {
            pub fn run(
                noalias worker: *Worker,
                noalias lock: *Lock,
                noalias guard: *const Guard,
                work_locked: WorkUnit,
                work_unlocked: WorkUnit,
            ) void {
                var locked: u64 = 0;
                var unlocked: u64 = 0;
                var xorshift = @as(u64, @ptrToInt(worker) ^ @ptrToInt(lock)) | 1;

                guard.wait();
                while (guard.running()) : (worker.iters += 1) {
                    if (worker.iters % 32 == 0) {
                        locked = work_locked.count(&xorshift);
                        unlocked = work_unlocked.count(&xorshift);
                    }

                    WorkUnit.run(locked);

                    const acquire_begin = worker.timer.read();
                    lock.acquire();
                    const acquire_end = worker.timer.read();

                    WorkUnit.run(unlocked);
                    lock.release();

                    const latency = acquire_end - acquire_begin;
                    worker.latencies.append(latency) catch @panic("out of memory");
                }
            }
        };
    }
};