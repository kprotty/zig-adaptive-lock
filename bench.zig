const std = @import("std");
const eql = std.mem.eql;
const indexOf = std.mem.indexOf;
const startsWith = std.mem.startsWith;
const allocator = if (std.builtin.link_libc) std.heap.c_allocator else std.heap.page_allocator;

/// Add mutexes to benchmark here
fn benchMutexes(ctx: BenchContext) !void {
    try bench(ctx, @import("./mutexes/os.zig").Mutex);
    try bench(ctx, @import("./mutexes/spin.zig").Mutex);
    try bench(ctx, @import("./mutexes/std.zig").Mutex);
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
        \\ -m/measure [seconds]        Amount of seconds to measure each mutex during the benchmark
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
    work_locked: u64,
    work_unlocked: u64,
    measure_seconds: u64,
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
                "{s:16} | {s:14} | {s:14}",
                .{"name", "avg lock/s", "std. dev."},
            ),
        });
    }

    fn recordValue(self: BenchContext, args: var) !void {
        if (self.mode != .Throughput)
            return;
            
        var buffer: [128]u8 = undefined;
        std.debug.warn("{}\n", .{
            try std.fmt.bufPrint(
                buffer[0..],
                "{s:16} | {:12} k | {:12} k",
                args,
            ),
        });
    }
};

pub fn main() !void {
    var ctx: BenchContext = undefined;
    ctx.measure_seconds = 1;
    var threads = std.ArrayList(usize).init(allocator);
    var locked = std.ArrayList(u64).init(allocator);
    var unlocked = std.ArrayList(u64).init(allocator);

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
            const seconds_str = blk: {
                if (indexOf(u8, arg, "=")) |idx| {
                    break :blk arg[idx+1..];
                } else {
                    break :blk (args.next(allocator) orelse return help()) catch return help();
                }
            };
            ctx.measure_seconds = std.fmt.parseInt(u64, seconds_str, 10) catch @panic("Expected seconds for measure time");
            ctx.measure_seconds = std.math.max(ctx.measure_seconds, 1);
        } else if (startsWith(u8, arg, "-t") or startsWith(u8, arg, "-threads") or startsWith(u8, arg, "--threads")) {
            try parse(arg, &args, &threads, parseInt, true);
        } else if (startsWith(u8, arg, "-l") or startsWith(u8, arg, "-locked") or startsWith(u8, arg, "--locked")) {
            try parse(arg, &args, &locked, parseWorkUnit, false);
        } else if (startsWith(u8, arg, "-u") or startsWith(u8, arg, "-unlocked") or startsWith(u8, arg, "--unlocked")) {
            try parse(arg, &args, &unlocked, parseWorkUnit, false);
        } else {
            std.debug.panic("Unknown argument: {}\n", .{arg});
        }
    }
    
    if (locked.items.len == 0) {
        try locked.append(1 * std.time.microsecond);
    }
    if (unlocked.items.len == 0) {
        try unlocked.append(0 * std.time.microsecond);
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
        _ = timer.read();
        const end = timer.read();
        break :blk (end - start);
    };

    
    ctx.loads_per_ns = blk: {
        const NUM_LOADS = 10000;
        var value: usize = undefined;
        const start = timer.read();
        for (@as([NUM_LOADS]void, undefined)) |_|
            _ = @ptrCast(*volatile usize, &value).*;
        const end = timer.read();
        const loads = (end - start) - ctx.timer_overhead;
        break :blk std.math.max(loads / NUM_LOADS, 1);
    };

    for (locked.items) |work_locked| {
        for (unlocked.items) |work_unlocked| {
            for (threads.items) |num_threads| {
                ctx.num_threads = num_threads;
                ctx.work_locked = work_locked;
                ctx.work_unlocked = work_unlocked;

                const locked_time = getTimeUnit(work_locked);
                const unlocked_time = getTimeUnit(work_unlocked); 
                std.debug.warn("threads={} locked={}{} unlocked={}{}\n", .{
                    num_threads,
                    locked_time.value,
                    locked_time.unit,
                    unlocked_time.value,
                    unlocked_time.unit,
                });
                
                try ctx.recordHeader();
                try benchMutexes(ctx);
                std.debug.warn("\n", .{});
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
        result.iterations /= 1000;
        result.iterations /= ctx.measure_seconds;
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

        mutex: Mutex align(128) = undefined,
        ctx: BenchContext,
        event: std.ResetEvent = undefined,
        contexes: std.ArrayList(WorkerContext) = undefined,
        stop: bool = false,

        const RunContext = struct {
            self: *Self,
            worker_context: *WorkerContext,
        };

        fn run(self: *Self) !void {
            self.mutex = Mutex.init();
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
            std.time.sleep(self.ctx.measure_seconds * std.time.second);
            @atomicStore(bool, &self.stop, true, .Monotonic);
            for (threads) |t|
                t.wait();
        }

        fn work(loads: usize) void {
            var i = loads;
            var value: usize = undefined;
            while (i != 0) : (i -= 1) {
                _ = @ptrCast(*volatile usize, &value).*;
            }
        }

        fn worker(c: RunContext) void {
            const self = c.self;
            const worker_context = c.worker_context;

            self.event.wait();
            const loads_with_lock = self.ctx.work_locked * self.ctx.loads_per_ns;
            const loads_without_lock = self.ctx.work_unlocked * self.ctx.loads_per_ns;
            if (@hasDecl(WorkerContext, "init"))
                worker_context.init();

            while (!@atomicLoad(bool, &self.stop, .Monotonic)) {
                if (@hasDecl(WorkerContext, "before_acquire"))
                    worker_context.before_acquire();
                self.mutex.acquire();
                if (@hasDecl(WorkerContext, "after_acquire"))
                    worker_context.after_acquire();

                work(loads_with_lock);

                if (@hasDecl(WorkerContext, "before_release"))
                    worker_context.before_release();
                self.mutex.release();
                if (@hasDecl(WorkerContext, "after_release"))
                    worker_context.after_release();

                work(loads_without_lock);
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
    if (ns < std.time.microsecond) {
        tu.unit = "ns";
        tu.value = ns;
    } else if (ns < std.time.millisecond) {
        tu.unit = "us";
        tu.value = ns / std.time.microsecond;
    } else if (ns < std.time.second) {
        tu.unit = "ms";
        tu.value = ns / std.time.millisecond;
    } else {
        tu.unit = "s";
        tu.value = ns / std.time.second;
    }
    return tu;
}

fn parseInt(buf: []const u8) !usize {
    return std.fmt.parseInt(usize, buf, 10) catch return error.ExpectedInteger;
}

fn parseWorkUnit(buf: []const u8) !u64 {
    var end = indexOf(u8, buf, "s") orelse return error.UnexpectedTimeUnit;
    const unit: u64 = switch (buf[end - 1]) {
        'n' => b: { end -=1; break :b std.time.nanosecond; },
        'u' => b: { end -=1; break :b std.time.microsecond; },
        'm' => b: { end -=1; break :b std.time.millisecond; },
        else => std.time.second,
    };
    const time = std.fmt.parseInt(u64, buf[0..end], 10) catch return error.ExpectedTimeValue;
    return time * unit;
}

fn parse(arg: var, args: var, array: var, comptime parseFn: var, comptime ranges: bool) !void {
    var value = blk: {
        if (indexOf(u8, arg, "=")) |idx| {
            break :blk arg[idx + 1..];
        } else {
            const v = args.next(allocator) orelse return error.ExpectedArgument;
            break :blk (try v);
        }
    };
    while (value.len != 0) {
        if (ranges) {
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
                while (start <= end) : (start += 1) {
                    try array.append(start);
                }
                if (len + 1 >= value.len)
                    break;
                value = value[len + 1..];
                continue;
            }
        }
        if (indexOf(u8, value, ",")) |len| {
            const item = try parseFn(value[0..len]);
            try array.append(item);
            if (len + 1 >= value.len)
                break;
            value = value[len + 1..];
            continue;
        }
        const item = try parseFn(value);
        try array.append(item);
        break;
    }
}