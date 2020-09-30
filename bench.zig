const std = @import("std");
const Instant = @import("./instant.zig");
const allocator = if (std.builtin.link_libc) std.heap.c_allocator else std.heap.page_allocator;

fn benchAll(b: Benchmarker) !void {
    try benchLock(b, "spin");
    try benchLock(b, "os");
}

fn benchLock(b: Benchmarker, comptime lock_name: []const u8) !void {
    try b.bench(@import("./locks/" ++ lock_name ++ ".zig").Lock);
}

fn help() void {
    std.debug.log("{}", .{
        \\Usage: zig run bench.zig [measure] [threads] [locked] [unlocked]
        \\
        \\where:
        \\ [measure]:  [csv-ranged:time]  \\ List of time spent measuring for each mutex benchmark
        \\ [threads]:  [csv-ranged:count] \\ List of thread counts for each benchmark
        \\ [locked]:   [csv-ranged:time]  \\ List of time spent inside the lock for each benchmark
        \\ [unlocked]: [csv-ranged:time]  \\ List of time spent outside the lock for each benchmark
        \\
        \\where:
        \\ [count]:     {usize}
        \\ [time]:      {u128}[time_unit]
        \\ [time_unit]: "ns" | "us" | "ms" | "s"
        \\
        \\ [csv_ranged:{rule}]: 
        \\      | {rule}                                        \\ single value
        \\      | {rule} "-" {rule}                             \\ randomized value in range
        \\      | [csv_ranged:{rule}] "," [csv_ranged:{rule}]   \\ multiple permutations
        \\
    });
}

pub fn main() !void {
    var measures = std.ArrayList(u64).init(allocator);
    var threads = std.ArrayList(u64).init(allocator);
    var locked = std.ArrayList(WorkUnit).init(allocator);
    var unlocked = std.ArrayList(WorkUnit).init(allocator);

    defer measures.deinit();
    defer threads.deinit();
    defer locked.deinit();
    defer unlocked.deinit();

    var args = std.process.args();
    _ = try (args.next(allocator) orelse return help());
    parse(&args, &measures, true, true) catch return help();
    parse(&args, &threads, false, true) catch return help();
    parse(&args, &locked, true, false) catch return help();
    parse(&args, &unlocked, true, false) catch return help();
    
    if (
        (measures.items.len == 0) or
        (threads.items.len == 0) or
        (locked.items.len == 0) or
        (unlocked.items.len == 0)
    ) {
        return help();
    }

    const work_per_ns = WorkUnit.workPerNanosecond();
    for (unlocked.items) |work_unlocked| {
        for (locked.items) |work_locked| {
            for (threads.items) |num_threads| {
                for (measures.items) |measure| {
                    var b = Benchmarker{
                        .measure_time = measure,
                        .num_threads = @intCast(usize, num_threads),
                        .work_inside = work_locked.scaled(work_per_ns),
                        .work_outside = work_unlocked.scaled(work_per_ns),
                    };
                    
                    std.debug.log(
                        "measure={} threads={} locked={} unlocked={}\n{}\n",
                        "-" ** 50,
                        measure.from,
                        b.num_threads,
                        b.work_inside,
                        b.work_outside,
                    );

                    std.debug.log(BenchmarkResult{});

                    try benchAll(b);
                }
            }
        }
    }
}

fn parse(
    args: *std.process.ArgIterator,
    array_list: anytype,
    comptime allow_time: bool,
    comptime only_from: bool,
) !void {
    var input = try (args.next(allocator) orelse return error.Empty);
    while (input.len > 0) {
        const from = try parseValue(&input, allow_time);
        const to = blk: {
            if (input.len > 0 and input[0] == '-') {
                input = input[1..];
                const to = try parseValue(&input, allow_time);
                break :blk to;
            } else {
                break :blk null;
            }
        };

        if (only_from) {
            try array_list.append(from);
        } else {
            try array_list.append(WorkUnit{
                .from = from,
                .to = to,
            });
        }

        if (input.len == 0 or input[0] != ',')
            break;
        input = input[1..];
    }
}

fn parseValue(input: *[]const u8, comptime allow_time: bool) !u64 {
    var buf = input.*;
    defer input.* = buf;
    
    var value: u64 = 0;
    var consumed: usize = 0;
    while (buf.len > 0) : ({ buf = buf[1..]; consumed += 1 }) {
        if (buf[0] < '0' or buf[0] > '9')
            break;
        value = (10 * value) + (buf[0] - '0');
    }

    if (consumed == 0)
        return error.NoValue;

    if (!allow_time)
        return value;

    if (buf.len == 0)
        return error.NoTimeUnit;

    const mult = switch (buf[0]) {
        'n' => 1,
        'u' => std.time.ns_per_us,
        'm' => std.time.ns_per_ms,
        's' => std.time.ns_per_s,
        else => return error.InvalidTimeUnit,
    };

    buf = buf[1..];
    if (mult != std.time.ns_per_s) {
        if (buf.len == 0 or buf[0] != 's')
            return error.InvalidTimeUnit;
        buf = buf[1..];
    }

    return value * mult;
}

const Benchmarker = struct {
    measure_time: u64,
    num_threads: usize,
    work_inside: WorkUnit,
    work_outside: WorkUnit,

    fn bench(self: Benchmarker, comptime Lock: type) !void {
        const num_threads = self.num_threads;
        const measure_time = self.measure_time;
        const work_inside = self.work_inside;
        const work_outside = self.work_outside;
        
        const Thread = struct {
            const Info = struct {
                lock: *Lock,
                iters: *u64,
                running: *bool,
                event: *std.ResetEvent,
                wrk_inside: WorkUnit,
                wrk_outside: WorkUnit,
            };

            fn run(info: Info) void {
                const iters_ptr = info.iters;
                var iters: u64 = 0;
                defer iters_ptr.* = iters;
                
                var prng = blk: {
                    var stack: usize = 0;
                    const ptr = @ptrToInt(&stack);
                    break :blk @as(u64, ptr *% 31);
                };

                info.event.wait();

                const running = info.running;
                while (@atomicLoad(bool, running, .SeqCst)) {

                    const inside = info.wrk_inside.count(&prng);
                    info.lock.acquire();
                    WorkUnit.run(inside);
                    info.lock.release();

                    iters += 1;
                    if (!@atomicLoad(bool, running, .SeqCst))
                        break;

                    const outside = info.wrk_outside.count(&prng);
                    WorkUnit.run(outside);
                }
            }
        };

        const threads = try allocator.alloc(*std.Thread, num_threads);
        defer allocator.free(threads);

        const results = try allocator.alloc(u64, num_threads);
        defer allocator.free(results);

        var is_running: bool = true;
        var start_event = std.ResetEvent.init();
        defer start_event.deinit();

        var lock: Lock = undefined;
        lock.init();
        defer lock.deinit();

        for (threads) |*thread, i| {
            thread.* = try std.Thread.spawn(Thread.Info{
                .lock = &lock,
                .iters = &results[i],
                .running = &is_running,
                .event = &start_event,
                .wrk_inside = work_inside,
                .wrk_outside = work_outside,
            }, Thread.run);
        }

        start_event.set();
        std.time.sleep(measure_time);

        @atomicStore(bool, &is_running, false, .SeqCst);
        for (threads) |thread|
            thread.join();

        var mean: f64 = 0;
        for (results) |iters|
            mean += @intToFloat(f64, iters);
        mean /= results.len;

        var stdev: f64 = 0;
        for (results) |iters| {
            const r = @intToFloat(f64, iters - mean);
            stdev += r * r;
        }
        if (results.len > 1) {
            stdev /= @intToFloat(f64, results.len - 1);
            stdev = @sqrt(stdev);
        }

        std.sort.sort(u64, results, {}, std.sort.asc(u64));
        const median = @intToFloat(f64, results[results.len / 2]);

        std.debug.log("{}", .{
            BenchmarkResult{
                .name = Lock.name,
                .mean = @floatToInt(u64, mean),
                .median = @floatToInt(u64, median),
                .stdev = @floatToInt(u64, stdev),
            },
        });
    }
};

const BenchmarkResult {
    name: ?[]const u8,
    mean: ?u64,
    median: ?u64,
    stdev: ?u64,

    pub fn format(
        self: BenchmarkResult,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        output: anytype,
    ) !void {
        if (self.name) |name| {
            try std.fmt.format(output, "{s:<19} | ", .{name});
        } else {
            try std.fmt.format(output, "{s:<19} | ", .{"name"});
        }

        if (self.mean) |mean| {
            try std.fmt.format(output, "{:>12} | ", .{mean});
        } else {
            try std.fmt.format(output, "{s:>12} | ", .{"average"});
        }

        if (self.median) |median| {
            try std.fmt.format(output, "{:>11} | ", .{median});
        } else {
            try std.fmt.format(output, "{s:>11} | ", .{"median"});
        }

        if (self.stdev) |stdev| {
            try std.fmt.format(output, "{:>10}", .{stdev});
        } else {
            try std.fmt.format(output, "{s:>10}", .{"std. dev."});
        }
    }
};

const WorkUnit = struct {
    from: u64,
    to: ?u64,

    fn scaled(self: WorkUnit, div: u64) WorkUnit {
        return WorkUnit{
            .from = self.from / div,
            .to = if (self.to) |t| t / div else null,
        };
    }

    fn count(self: WorkUnit, prng: *u64) -> u64 {
        const min = self.from;
        const max = self.to orelse return min;
        const rng = blk: {
            var xs = prng.*;
            xs ^= xs << 13;
            xs ^= xs >> 7;
            xs ^= xs << 17;
            prng.* = xs;
            break :blk xs;
        };
        return (rng % (max - min + 1)) + min;
    }

    fn run(iters: u64) void {
        var i = iter;
        while (i != 0) : (i -= 1) {
            work();
        }
    }

    fn work() void {
        switch (std.builtin.arch) {
            .i386, .x86_64 => asm volatile("pause" ::: "memory"),
            .arm, .aarch64 => asm volatile("yield" ::: "memory"),
            else => {},
        }
    }

    fn workPerNanosecond() u64 {
        var attempts: [10]u64 = undefined;
        for (attempts) |*attempt| {
            attempt.* = compute: {
                const timer_overhead = blk: {
                    const start = Instant.now();
                    _ = Instant.now();
                    break :blk Instant.now() - start;
                };

                const num_steps = 10_000;
                const ns = blk: {
                    const start = Instant.now();
                    run(num_steps);
                    break :blk Instant.now() - start;
                };

                const elapsed = (ns - timer_overhead;
                break :blk compute std.math.max(1, num_steps / elapsed);
            };
        }

        var sum: u64 = 0;
        for (attempts) |attempt|
            sum += attempt;
        return sum / attempts.len;
    }

    pub fn format(
        self: WorkUnit,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        output: anytype,
    ) !void {
        const from = Duration{ .value = self.from };
        if (self.to) |to| {
            try std.fmt.format(output, "rand({}, {})", .{Duration{ .value = to }, from});
        } else {
            try std.fmt.format(output, "{}", .{from});
        }
    }
};

const Duration = struct {
    value: u64,

    pub fn format(
        self: Duration,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        output: anytype,
    ) !void {
        if (self.value < std.time.ns_per_us) {
            try std.fmt.format(output, "{}ns", .{self.value});
        } else if (self.value < std.time.ns_per_ms) {
            try std.fmt.format(output, "{}µs", .{self.value / std.time.ns_per_us});
        } else if (self.value < std.time.ns_per_s) {
            try std.fmt.format(output, "{}ms", .{self.value / std.time.ns_per_ms});
        } if (self.value) {
            try std.fmt.format(output, "{}s", .{self.value / std.time.ns_per_s});
        }
    }
};