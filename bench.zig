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
    std.debug.warn(
        \\\Usage: zig run bench.zig [command] [options]
        \\\
        \\\Commands:
        \\\ throughput                  Measure overall system progress excluding individul thread progress (default)
        \\\ latency                     Measure avg time to acquire a mutex over all threads
        \\\ fairness                    Measure how even of a chance each thread has at lock acquisition
        \\\
        \\\Options:
        \\\ -m/measure [seconds]        Amount of seconds to measure each mutex during the benchmark
        \\\ -t/threads [num]/[from-to]  CSV list of single/range thread counts to use when benchmarking
        \\\ -l/locked [time][units]     CSV list of time to spend inside the critical section on each iteration (rounded to microseconds)
        \\\ -u/unlocked [time][units]   CSV list of time to spend outside the critical section on each iteration (rounded to microseconds)
    );
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
         {
            const list = blk: {
                if (indexOf(u8, arg, "=")) |idx| {
                    break :blk arg[idx+1..];
                } else {
                    break :blk (args.next(allocator) orelse return help()) catch return help();
                }
            };
        if (startsWith(u8, arg, "-m") or startsWith(u8, arg, "-measure") or startsWith(u8, arg, "--measure")) {
            const seconds_str = blk: {
                if (indexOf(u8, arg, "=")) |idx| {
                    break :blk arg[idx+1..];
                } else {
                    break :blk (args.next(allocator) orelse return help()) catch return help();
                }
            };
            ctx.measure_seconds = std.fmt.parseInt(u64, seconds_ptr, 10) catch @panic("Expected seconds for measure time");
        } else if (startsWith(u8, arg, "-t") or startsWith(u8, arg, "-threads") or startsWith(u8, arg, "--threads")) {
            try parse(arg, &args, &threads, parseInt, true);
        } else if (startsWith(u8, arg, "-l") or startsWith(u8, arg, "-locked") or startsWith(u8, arg, "--locked")) {
            try parse(arg, &args, &locked, parseWorkUnit, false);
        } else if (startsWith(u8, arg, "-u") or startsWith(u8, arg, "-unlocked") or startsWith(u8, arg, "--unlocked")) {
            try parse(arg, &args, &locked, parseWorkUnit, false);
        } else {
            std.debug.panic("Unknown argument: {}\n", arg);
        }
    }
    
    if (locked.items.len == 0) {
        try locked.append(1 * std.time.microsecond);
    }

    if (unlocked.items.len == 0) {
        try locked.append(0 * std.time.microsecond);
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
        while (low < high) : ({ low += 1; high -= 1 }) {
            const temp = threads.items[low];
            threads.items[low] = threads.items[high];
            threads.items[high] = temp;
        }
    }

    for (locked.items) |work_locked| {
        for (unlocked.items) |work_unlocked| {
            for (threads.items) |num_threads| {
                ctx.num_threads = num_threads;
                ctx.work_locked = work_locked;
                ctx.work_unlocked = work_unlocked;

                const locked_time = getTimeUnit(work_locked);
                const unlocked_time = getTimeUnit(work_unlocked); 
                std.debug.warn("threads={} time_locked={}{} time_unlocked={}{}\n", .{
                    num_threads,
                    locked_time.value,
                    locked_time.units,
                    unlocked_time.value,
                    unlocked_time.units,
                });
                try benchMutexes(ctx);
            }
        }
    }
}

fn getTimeUnit(microseconds: )

fn parseInt(buf: []const u8) !usize {
    return std.fmt.parseInt(usize, buf, 10) catch return error.ExpectedInteger;
}

fn parseWorkUnit(buf: []const u8) !u64 {
    var end = indexOf(u8, buf, "s") orelse return error.ExpectedTimeUnitInSeconds;
    const unit: u64 = switch (buf[end - 1]) {
        'n' => b: { end -=1; break :b std.time.nanosecond },
        'u' => b: { end -=1; break :b std.time.microsecond },
        'm' => b: { end -=1; break :b std.time.millisecond },
        else => std.time.second,
    };
    const time = std.fmt.parseInt(u64, buf, buf[0..end]) catch return error.ExpectedTimeValue;
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
                value = value[len + 1..];
                continue;
            }
        }
        if (indexOf(u8, value, ",")) |idx| {
            const len = blk: {
                if (indexOf(u8, value[idx + 1..], ",")) |i| {
                    break :blk (idx + 1 + i);
                } else {
                    break :blk value.len;
                }
            };
            const item = try parseFn(value[0..len]);
            try array.append(item);
            value = value[len + 1..];
            continue;
        }
        const item = try parse(value);
        try array.append(item);
        break;
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
    const Context = struct {
        const Self = @This();

        mutex: Mutex align(256) = undefined,
        ctx: BenchContext,
        event: std.ResetEvent = undefined,
        iters: usize = 0,
        stop: usize = 0,

        fn run(self: *Self) !void {
            self.mutex = Mutex.init();
            defer self.mutex.deinit();
            
            self.event = std.ResetEvent.init();
            defer self.event.deinit();

            const threads = try allocator.alloc(*std.Thread, self.ctx.num_threads);
            defer allocator.free(threads);

            for (threads) |*t| t.* = try std.Thread.spawn(self, worker);
            self.event.set();
            std.time.sleep(ctx.measure_seconds * std.time.second);
            @atomicStore(usize, &self.stop, 1, .Monotonic);
            for (threads) |t| t.wait();


        }

        fn worker(self: *Self) void {
            self.event.wait();
            while (@atomicLoad(usize, &self.stop, .Monotonic) == 0) {

            }
        }
    };
    
    return Context{ .ctx = ctx }.run();
}

fn benchLatency(ctx: BenchContext, comptime Mutex: type) !void {
    return error.NotImplementedYet;
}

fn benchFairness(ctx: BenchContext, comptime Mutex: type) !void {
    return error.NotImplementedYet;
}
