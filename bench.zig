const std = @import("std");
const eql = std.mem.eql;
const indexOf = std.mem.indexOf;
const startsWith = std.mem.startsWith;
const allocator = if (std.builtin.link_libc) std.heap.c_allocator else std.heap.page_allocator;

/// Add mutexes to benchmark here
fn benchMutexes(ctx: BenchContext) !void {
    try bench(ctx, @import("./mutexes/word_lock.zig").Mutex);
    try bench(ctx, @import("./mutexes/word_lock_waking.zig").Mutex);
    // try bench(ctx, @import("./mutexes/test_fair_lock.zig").Mutex);
    try bench(ctx, @import("./mutexes/test_new_lock.zig").Mutex);
    
    // try bench(ctx, @import("./mutexes/zap.zig").Mutex);
    // try bench(ctx, @import("./mutexes/std.zig").Mutex);
    try bench(ctx, @import("./mutexes/os.zig").Mutex);
    try bench(ctx, @import("./mutexes/spin.zig").Mutex);
    // try bench(ctx, @import("./mutexes/mcs.zig").Mutex);
}

fn help() void {
    std.debug.warn("{}\n", .{
        \\Usage: zig run bench.zig [command] [options]
        \\
        \\Commands:
        \\ throughput                  Measure overall system progress excluding individul thread progress (default)
        \\ latency                     Measure avg time to acquire a mutex over all threads
        \\ fairness                    Measure how even of a chance each thread has at lock acquisition
        \\
        \\Options:
        \\ -m/measure [time][units]    CSV list of time to measure each mutex during the benchmark
        \\ -t/threads [num]/[from-to]  CSV list of single/range thread counts to use when benchmarking
        \\ -l/locked [time][units]     CSV list of time to spend inside the critical section on each iteration in nanoseconds
        \\ -u/unlocked [time][units]   CSV list of time to spend outside the critical section on each iteration in nanoseconds
    });
}

const BenchContext = struct {
    mode: enum {
        Throughput,
        Latency,
        Fairness,
    },
    num_threads: usize,
    work_locked: WorkUnit,
    work_unlocked: WorkUnit,
    measure_ns: u64,
    loads_per_ns: u64,
    timer_overhead: u64,

    fn recordHeader(self: BenchContext) !void {
        if (self.mode != .Throughput)
            return;

        var buffer: [128]u8 = undefined;
        std.debug.warn("{}\n{}\n", .{
            "-" ** 50,
            try std.fmt.bufPrint(
                buffer[0..],
                "{s:20} | {s:14} | {s:14}",
                .{"name", "average", "std. dev."},
            ),
        });
    }

    fn recordValue(self: BenchContext, args: anytype) !void {
        if (self.mode != .Throughput)
            return;
            
        var buffer: [128]u8 = undefined;
        std.debug.warn("{}\n", .{
            try std.fmt.bufPrint(
                buffer[0..],
                "{s:20} | {:14} | {:14}",
                args,
            ),
        });
    }
};

pub fn main() !void {
    var ctx: BenchContext = undefined;

    var measures = std.ArrayList(WorkUnit).init(allocator);
    var threads = std.ArrayList(usize).init(allocator);
    var locked = std.ArrayList(WorkUnit).init(allocator);
    var unlocked = std.ArrayList(WorkUnit).init(allocator);

    defer measures.deinit();
    defer threads.deinit();
    defer locked.deinit();
    defer unlocked.deinit();

    var args = std.process.args();
    _ = try (args.next(allocator) orelse unreachable);
    const mode = (args.next(allocator) orelse return help()) catch return help();
    if (eql(u8, mode, "throughput")) {
        ctx.mode = .Throughput;
    } else if (eql(u8, mode, "latency")) {
        ctx.mode = .Latency;
    } else if (eql(u8, mode, "fairness")) {
        ctx.mode = .Fairness;
    } else {
        return help();
    }

    while (args.next(allocator)) |a| {
        const arg = try a;
        if (startsWith(u8, arg, "-m") or startsWith(u8, arg, "-measure") or startsWith(u8, arg, "--measure")) {
            try parse(arg, &args, &measures, parseWorkUnit, addWorkUnits);
        } else if (startsWith(u8, arg, "-t") or startsWith(u8, arg, "-threads") or startsWith(u8, arg, "--threads")) {
            try parse(arg, &args, &threads, parseInt, addThreads);
        } else if (startsWith(u8, arg, "-l") or startsWith(u8, arg, "-locked") or startsWith(u8, arg, "--locked")) {
            try parse(arg, &args, &locked, parseWorkUnit, addWorkUnits);
        } else if (startsWith(u8, arg, "-u") or startsWith(u8, arg, "-unlocked") or startsWith(u8, arg, "--unlocked")) {
            try parse(arg, &args, &unlocked, parseWorkUnit, addWorkUnits);
        } else {
            std.debug.panic("Unknown argument: {}\n", .{arg});
        }
    }

    if (measures.items.len == 0) {
        try measures.append(WorkUnit {
            .fromNs = 1 * std.time.ns_per_s,
            .toNs = null,
        });
    }

    if (locked.items.len == 0) {
        try locked.append(WorkUnit{
            .fromNs = 0,
            .toNs = null,
        });
    }
    if (unlocked.items.len == 0) {
        try unlocked.append(WorkUnit{
            .fromNs = 0,
            .toNs = null,
        });
    }

    if (threads.items.len == 0) {
        const max_threads = try std.Thread.cpuCount();
        try threads.append(max_threads * 2);
        try threads.append(max_threads);
        var stop = false;
        var rest = max_threads / 2;
        while (!stop and rest < max_threads) {
            if (rest == 1) {
                if (std.mem.indexOf(usize, threads.items, &[_]usize{2}) == null) {
                    try threads.append(2);
                }
                stop = true;
            }
            try threads.append(rest);
            rest /= 2;
        }
        var low: usize = 0;
        var high: usize = threads.items.len - 1;
        while (low < high) : ({ low += 1; high -= 1; }) {
            const temp = threads.items[low];
            threads.items[low] = threads.items[high];
            threads.items[high] = temp;
        }
    }

    var timer = try std.time.Timer.start();
    ctx.timer_overhead = blk: {
        const start = timer.read();
        var result: u64 = undefined;
        @ptrCast(*volatile u64, &result).* = timer.read();
        const end = timer.read();
        break :blk (end - start);
    };

    ctx.loads_per_ns = blk: {
        const NUM_PAUSES = 10000;
        const start = timer.read();
        for (@as([NUM_PAUSES]void, undefined)) |_|
            std.SpinLock.loopHint(1);
        const end = timer.read();
        const loads = (end - start) - ctx.timer_overhead;
        break :blk std.math.max(NUM_PAUSES / loads, 1);
    };

    for (unlocked.items) |work_unlocked| {
        for (locked.items) |work_locked| {
            for (threads.items) |num_threads| {
                for (measures.items) |measure| {
                    ctx.num_threads = num_threads;
                    ctx.work_locked = work_locked;
                    ctx.work_unlocked = work_unlocked;
                    ctx.measure_ns = measure.fromNs;

                    measure.print("measure=");
                    std.debug.warn(" threads={}", .{num_threads});
                    work_locked.print(" locked=");
                    work_unlocked.print(" unlocked=");
                    std.debug.warn("\n", .{});
                    
                    try ctx.recordHeader();
                    try benchMutexes(ctx);
                    std.debug.warn("\n", .{});
                }
            }
        }
    }
}

fn bench(ctx: BenchContext, comptime Mutex: type) !void {
    switch (ctx.mode) {
        .Throughput => try benchThroughput(ctx, Mutex),
        .Latency => try benchLatency(ctx, Mutex),
        .Fairness => try benchFairness(ctx, Mutex),
    }
}

fn benchThroughput(ctx: BenchContext, comptime Mutex: type) !void {
    var results = try runBench(ctx, Mutex, struct {
        const Self = @This();
        iterations: usize,

        fn init(self: *Self) void {
            self.iterations = 0;
        }

        fn after_release(self: *Self) void {
            self.iterations += 1;
        }
    });

    defer results.deinit();
    for (results.items) |*result| {
        result.iterations /= std.math.max(1, ctx.measure_ns / std.time.ns_per_s);
    }

    const average = blk: {
        var avg: f64 = 0;
        for (results.items) |result| {
            avg += @intToFloat(f64, result.iterations);
        }
        avg /= @intToFloat(f64, results.items.len);
        break :blk @floatToInt(u64, avg);
    };

    const variance = blk: {
        var stdev: f64 = 0;
        for (results.items) |result| {
            var r = @intToFloat(f64, result.iterations);
            r -= @intToFloat(f64, average);
            stdev += r * r;
        }
        if (results.items.len > 1) {
            stdev /= @intToFloat(f64, results.items.len - 1);
            stdev = @sqrt(stdev);
        }
        break :blk @floatToInt(u64, stdev);
    };

    try ctx.recordValue(.{Mutex.NAME, average, variance});
}

fn benchLatency(ctx: BenchContext, comptime Mutex: type) !void {
    return error.NotImplementedYet;
}

fn benchFairness(ctx: BenchContext, comptime Mutex: type) !void {
    return error.NotImplementedYet;
}

fn runBench(ctx: BenchContext, comptime Mutex: type, comptime WorkerContext: type) !std.ArrayList(WorkerContext) {
    const Context = struct {
        const Self = @This();

        mutex: Mutex align(256) = undefined,
        ctx: BenchContext,
        event: std.ResetEvent = undefined,
        contexes: std.ArrayList(WorkerContext) = undefined,
        stop: bool = false,

        const RunContext = struct {
            self: *Self,
            worker_context: *WorkerContext,
        };

        fn run(self: *Self) !void {
            self.mutex.init();
            defer self.mutex.deinit();
            
            self.event = std.ResetEvent.init();
            defer self.event.deinit();

            const threads = try allocator.alloc(*std.Thread, self.ctx.num_threads);
            defer allocator.free(threads);

            self.contexes = try std.ArrayList(WorkerContext).initCapacity(allocator, threads.len);
            for (threads) |_|
                try self.contexes.append(undefined);
            errdefer self.contexes.deinit();

            for (threads) |*t, i|
                t.* = try std.Thread.spawn(RunContext{
                    .self = self,
                    .worker_context = &self.contexes.items[i],
                }, worker);
            self.event.set();
            std.time.sleep(self.ctx.measure_ns);
            @atomicStore(bool, &self.stop, true, .Monotonic);
            for (threads) |t|
                t.wait();
        }

        fn workLoads(work_unit: WorkUnit, rng: *u64, loads_per_ns: u64) u64 {
            @setCold(true);
            const min = work_unit.fromNs;
            const max = work_unit.toNs orelse return min * loads_per_ns;
            const rng_state = r: {
                var x = rng.*;
                x ^= x << 13;
                x ^= x >> 7;
                x ^= x << 17;
                rng.* = x;
                break :r x;
            };
            const loads = (rng_state % (max - min + 1)) + min;
            return loads * loads_per_ns;
        }

        fn work(loads: u64) void {
            var i = loads;
            while (i != 0) : (i -= 1) {
                std.SpinLock.loopHint(1);
            }
        }

        fn worker(c: RunContext) void {
            const self = c.self;
            const worker_context = c.worker_context;
            
            const work_locked = self.ctx.work_locked;
            const work_unlocked = self.ctx.work_unlocked;
            const loads_per_ns = self.ctx.loads_per_ns;

            var rng: u64 = @ptrToInt(self) ^ @ptrToInt(worker_context);
            var work_locked_loads = workLoads(work_locked, &rng, loads_per_ns);
            var work_unlocked_loads = workLoads(work_unlocked, &rng, loads_per_ns);
            const refreshLocked = work_locked.toNs != null;
            const refreshUnlocked = work_unlocked.toNs != null;

            if (@hasDecl(WorkerContext, "init"))
                worker_context.init();

            self.event.wait();
            while (!@atomicLoad(bool, &self.stop, .Monotonic)) {
                if (refreshLocked)
                    work_locked_loads = workLoads(work_locked, &rng, loads_per_ns);
                if (refreshUnlocked)
                    work_unlocked_loads = workLoads(work_unlocked, &rng, loads_per_ns);

                if (@hasDecl(WorkerContext, "before_acquire"))
                    worker_context.before_acquire();
                self.mutex.acquire();
                if (@hasDecl(WorkerContext, "after_acquire"))
                    worker_context.after_acquire();

                work(work_locked_loads);

                if (@hasDecl(WorkerContext, "before_release"))
                    worker_context.before_release();
                self.mutex.release();
                if (@hasDecl(WorkerContext, "after_release"))
                    worker_context.after_release();

                work(work_unlocked_loads);
            }
        }
    };
    
    var context = Context{ .ctx = ctx };
    try context.run();
    return context.contexes;
}

const TimeUnit = struct {
    value: u64,
    unit: []const u8,
};

fn getTimeUnit(ns: u64) TimeUnit {
    var tu: TimeUnit = undefined;
    if (ns < std.time.ns_per_us) {
        tu.unit = "ns";
        tu.value = ns;
    } else if (ns < std.time.ns_per_ms) {
        tu.unit = "us";
        tu.value = ns / std.time.ns_per_us;
    } else if (ns < std.time.ns_per_s) {
        tu.unit = "ms";
        tu.value = ns / std.time.ns_per_ms;
    } else {
        tu.unit = "s";
        tu.value = ns / std.time.ns_per_s;
    }
    return tu;
}

fn parseInt(buf: []const u8) !usize {
    return std.fmt.parseInt(usize, buf, 10) catch return error.ExpectedInteger;
}

fn addThreads(array: anytype, threadStart: anytype, threadEnd: ?@TypeOf(threadStart)) !void {
    var start = threadStart;
    const end = threadEnd orelse threadStart;
    while (start <= end) : (start += 1) {
        try array.append(start);
    }
}

const WorkUnit = struct {
    fromNs: u64,
    toNs: ?u64,

    fn print(self: WorkUnit, comptime header: anytype) void {
        const from = getTimeUnit(self.fromNs);
        std.debug.warn("{}{}{}", .{
            header,
            from.value,
            from.unit,
        });
        if (self.toNs) |toNs| {
            const to = getTimeUnit(toNs);
            std.debug.warn("-{}{}", .{to.value, to.unit});
        }
    }
};

fn parseWorkUnit(buf: []const u8) !u64 {
    var end = indexOf(u8, buf, "s") orelse return error.UnexpectedTimeUnit;
    const unit: u64 = switch (buf[end - 1]) {
        'n' => b: { end -=1; break :b 1; },
        'u' => b: { end -=1; break :b std.time.ns_per_us; },
        'm' => b: { end -=1; break :b std.time.ns_per_ms; },
        else => std.time.ns_per_s,
    };
    const time = std.fmt.parseInt(u64, buf[0..end], 10) catch return error.ExpectedTimeValue;
    return time * unit;
}

fn addWorkUnits(array: anytype, start: u64, end: ?u64) !void {
    if (end) |e| {
        if (e < start)
            return error.InvalidTimeRange;
    }

    try array.append(WorkUnit{
        .fromNs = start,
        .toNs = end,
    });
}

fn parse(arg: anytype, args: anytype, array: anytype, comptime parseFn: anytype, comptime add: anytype) !void {
    var value = blk: {
        if (indexOf(u8, arg, "=")) |idx| {
            break :blk arg[idx + 1..];
        } else {
            const v = args.next(allocator) orelse return error.ExpectedArgument;
            break :blk (try v);
        }
    };
    while (value.len != 0) {
        if (indexOf(u8, value, "-")) |idx| {
            const len = blk: {
                if (indexOf(u8, value[idx + 1..], ",")) |i| {
                    break :blk (idx + 1 + i);
                } else {
                    break :blk value.len;
                }
            };
            var start = try parseFn(value[0..idx]);
            const end = try parseFn(value[idx + 1..len]);
            try add(array, start, end);
            if (len + 1 >= value.len)
                break;
            value = value[len + 1..];
            continue;
        }
        if (indexOf(u8, value, ",")) |len| {
            const item = try parseFn(value[0..len]);
            try add(array, item, null);
            if (len + 1 >= value.len)
                break;
            value = value[len + 1..];
            continue;
        }
        const item = try parseFn(value);
        try add(array, item, null);
        break;
    }
}