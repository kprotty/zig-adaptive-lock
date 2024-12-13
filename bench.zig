// Copyright (c) 2020 kprotty
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

const std = @import("std");
const builtin = @import("builtin");

const locks = .{
    // Spin Locks
    @import("locks/spin_lock.zig").Lock,
    @import("locks/mcs_lock.zig").Lock,

    // OS Locks
    @import("locks/os_lock.zig").Lock,
    @import("locks/pi_lock.zig").Lock,
};

fn help() void {
    print("{s}", .{
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

// Circumvent going through std.debug.print
// as when theres a segfault that happens while std.debug.stderr_mutex is being held,
// then the panic handler will try and grab the mutex again which will result in a dead-lock.
fn print(comptime fmt: []const u8, args: anytype) void {
    nosuspend std.io.getStdErr().writer().print(fmt, args) catch return;
}

pub fn main() !void {
    // allocator which can be shared between threads
    const shared_allocator = blk: {
        if (builtin.link_libc) {
            break :blk std.heap.c_allocator;
        }

        if (builtin.os.tag == .window) {
            const Static = struct {
                var heap = std.heap.HeapAllocator.init();
            };
            break :blk Static.heap.allocator();
        }

        const Static = struct {
            var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        };
        break :blk Static.gpa.allocator();
    };

    // use an arena allocator for all future allocations
    var arena = std.heap.ArenaAllocator.init(shared_allocator);
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

    var args = try std.process.ArgIterator.initWithAllocator(allocator);
    defer args.deinit();

    _ = args.next() orelse unreachable;
    Parser.parse(&args, &measures, Parser.toMeasure) catch return help();
    Parser.parse(&args, &threads, Parser.toThread) catch return help();
    Parser.parse(&args, &locked, Parser.toWorkUnit) catch return help();
    Parser.parse(&args, &unlocked, Parser.toWorkUnit) catch return help();

    const nanos_per_work_unit = try WorkUnit.nanosPerUnit();

    for (unlocked.items) |work_unlocked| {
        for (locked.items) |work_locked| {
            for (threads.items) |num_threads| {
                for (measures.items) |measure| {
                    print("measure={} threads={} locked={} unlocked={}\n{s}\n", .{
                        measure,
                        num_threads,
                        work_locked,
                        work_unlocked,
                        "-" ** 90,
                    });

                    const header_result = Result{};
                    print("{}\n", .{header_result});

                    inline for (locks) |Lock| {
                        if (Lock != void) {
                            const result = try bench(Lock, BenchConfig{
                                .allocator = allocator,
                                .shared_allocator = shared_allocator,
                                .num_threads = num_threads,
                                .measure = measure,
                                .work_locked = work_locked.scaled(nanos_per_work_unit),
                                .work_unlocked = work_unlocked.scaled(nanos_per_work_unit),
                            });
                            print("{}\n", .{result});
                        }
                    }

                    print("\n", .{});
                }
            }
        }
    }
}

const BenchConfig = struct {
    allocator: std.mem.Allocator,
    shared_allocator: std.mem.Allocator,
    num_threads: usize,
    measure: Duration,
    work_locked: WorkUnit,
    work_unlocked: WorkUnit,
};

fn bench(comptime Lock: type, config: BenchConfig) !Result {
    const workers = try config.allocator.alloc(Worker, config.num_threads);
    defer config.allocator.free(workers);

    var spawned: usize = 0;
    defer for (workers[0..spawned]) |*w| w.arena.deinit();

    {
        var lock: Lock = undefined;
        lock.init();
        defer lock.deinit();

        var barrier = Barrier{};
        defer {
            barrier.stop();
            for (workers[0..spawned]) |w| w.thread.join();
        }

        const runFn = Worker.getRunner(Lock).run;
        while (spawned < workers.len) : (spawned += 1) {
            workers[spawned] = .{
                .thread = undefined,
                .arena = std.heap.ArenaAllocator.init(config.shared_allocator),
                .latencies = std.ArrayList(u64).init(workers[spawned].arena.allocator()),
            };
            workers[spawned].thread = try std.Thread.spawn(.{}, runFn, .{
                &workers[spawned],
                &lock,
                &barrier,
                config.work_locked,
                config.work_unlocked,
            });
        }

        barrier.start();
        std.time.sleep(config.measure.nanos);
    }

    var latencies = std.ArrayList(u64).init(config.allocator);
    defer latencies.deinit();

    var sum: u64 = 0;
    var max: u64 = 0;
    var min: u64 = std.math.maxInt(u64);

    for (workers) |w| {
        sum += w.iters;
        min = @min(min, w.iters);
        max = @max(max, w.iters);
        try latencies.appendSlice(w.latencies.items);
    }

    const mean = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(workers.len));
    var stdev: f64 = 0;
    for (workers) |w| {
        const r = @as(f64, @floatFromInt(w.iters)) - mean;
        stdev += r * r;
    }
    if (workers.len > 1) {
        stdev /= @as(f64, @floatFromInt(workers.len)) - 1;
        stdev = @sqrt(stdev);
    }

    const items = latencies.items;
    const cmp = comptime std.sort.asc(u64);
    std.mem.sort(u64, items, {}, cmp);

    var latency_percentiles: [2]u64 = undefined;
    for ([_]f64{ 50.0, 99.0 }, 0..) |percentile, index| {
        const p = percentile / 100.0;
        const i = @round(p * @as(f64, @floatFromInt(items.len)));
        const v = @min(items.len, @as(usize, @intFromFloat(i)));
        latency_percentiles[index] = items[v - 1];
    }

    const latency_p50 = latency_percentiles[0];
    const latency_p99 = latency_percentiles[1];

    return Result{
        .name = Lock.name,
        .mean = mean,
        .stdev = stdev,
        .min = @as(f64, @floatFromInt(min)),
        .max = @as(f64, @floatFromInt(max)),
        .sum = @as(f64, @floatFromInt(sum)),
        .@"lat. <50%" = latency_p50,
        .@"lat. <99%" = latency_p99,
    };
}

const Barrier = struct {
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    fn wait(self: *const Barrier) void {
        while (self.state.load(.acquire) == 0) {
            std.Thread.Futex.wait(&self.state, 0);
        }
    }

    fn isRunning(self: *const Barrier) bool {
        return self.state.load(.acquire) == 1;
    }

    fn wake(self: *Barrier, value: u32) void {
        self.state.store(value, .release);
        std.Thread.Futex.wake(&self.state, std.math.maxInt(u32));
    }

    fn start(self: *Barrier) void {
        self.wake(1);
    }

    fn stop(self: *Barrier) void {
        self.wake(2);
    }
};

const Worker = struct {
    iters: u64 = 0,
    thread: std.Thread,
    latencies: std.ArrayList(u64),
    arena: std.heap.ArenaAllocator,

    fn getRunner(comptime Lock: type) type {
        return struct {
            pub fn run(
                noalias self: *Worker,
                noalias lock: *Lock,
                noalias barrier: *const Barrier,
                work_locked: WorkUnit,
                work_unlocked: WorkUnit,
            ) void {
                var prng = @as(u64, @intFromPtr(self) ^ @intFromPtr(lock));
                var locked: u64 = 0;
                var unlocked: u64 = 0;

                barrier.wait();
                while (barrier.isRunning()) : (self.iters += 1) {
                    if (self.iters % 32 == 0) {
                        locked = work_locked.count(&prng);
                        unlocked = work_unlocked.count(&prng);
                    }

                    WorkUnit.run(locked);

                    const acquire_begin = std.time.Instant.now() catch unreachable;
                    lock.acquire();
                    const acquire_end = std.time.Instant.now() catch unreachable;

                    WorkUnit.run(unlocked);
                    lock.release();

                    const latency = acquire_end.since(acquire_begin);
                    self.latencies.append(latency) catch {};
                }
            }
        };
    }
};

const Parser = struct {
    fn parse(
        args: *std.process.ArgIterator,
        results: anytype,
        comptime resolveFn: anytype,
    ) !void {
        var input = args.next() orelse return error.ExpectedArg;
        while (input.len > 0) {
            const a = try Item.read(&input);
            const b = blk: {
                if (input.len == 0 or input[0] != '-')
                    break :blk null;
                input = input[1..];
                const b = try Item.read(&input);
                break :blk b;
            };
            try resolveFn(results, a, b);
            if (input.len > 0) {
                if (input[0] != ',')
                    return error.InvalidSeparator;
                input = input[1..];
            }
        }
    }

    fn toMeasure(results: *std.ArrayList(Duration), a: Item, b: ?Item) !void {
        if (b != null)
            return error.MeasureDoesntSupportRanges;
        const mult = a.mult orelse return error.MeasureRequiresTimeUnit;
        try results.append(Duration{ .nanos = a.value * mult });
    }

    fn toThread(results: *std.ArrayList(usize), a: Item, b: ?Item) !void {
        if (b) |real_b| {
            if (real_b.mult != null)
                return error.ThreadsTakeValuesNotTimeUnits;
            if (a.value > real_b.value)
                return error.InvalidThreadRange;
            var thread = a.value;
            while (thread <= real_b.value) : (thread += 1)
                try results.append(@intCast(thread));
        } else if (a.mult != null) {
            return error.ThreadsTakeValuesNotTimeUnits;
        } else {
            try results.append(@intCast(a.value));
        }
    }

    fn toWorkUnit(results: *std.ArrayList(WorkUnit), a: Item, b: ?Item) !void {
        var work_unit = WorkUnit{
            .from = a.value * (a.mult orelse return error.WorkUnitRequiresTimeUnit),
            .to = null,
        };

        if (b) |real_b| {
            const mult = real_b.mult orelse return error.WorkUnitRequiresTimeUnit;
            work_unit.to = real_b.value * mult;
        }

        if (work_unit.to) |to| {
            if (work_unit.from >= to) {
                return error.InvalidWorkUnitRange;
            }
        }

        try results.append(work_unit);
    }

    const Item = struct {
        value: u64,
        mult: ?u64,

        fn read(input: *[]const u8) !Item {
            var buf = input.*;
            defer input.* = buf;

            const value = blk: {
                var val: ?u64 = null;
                while (buf.len > 0) {
                    if (buf[0] < '0' or buf[0] > '9')
                        break;
                    val = ((val orelse 0) * 10) + (buf[0] - '0');
                    buf = buf[1..];
                }
                break :blk (val orelse return error.NoValueProvided);
            };

            var mult: ?u64 = null;
            if (buf.len > 0 and buf[0] != '-' and buf[0] != ',') {
                const m: u64 = switch (buf[0]) {
                    'n' => 1,
                    'u' => std.time.ns_per_us,
                    'm' => std.time.ns_per_ms,
                    's' => std.time.ns_per_s,
                    else => return error.InvalidTimeUnit,
                };
                buf = buf[1..];
                if (m != std.time.ns_per_s) {
                    if (buf.len == 0 or buf[0] != 's')
                        return error.InvalidTimeUnit;
                    buf = buf[1..];
                }
                mult = m;
            }

            return Item{
                .value = value,
                .mult = mult,
            };
        }
    };
};

const Result = struct {
    name: ?[]const u8 = null,
    mean: ?f64 = null,
    stdev: ?f64 = null,
    min: ?f64 = null,
    max: ?f64 = null,
    sum: ?f64 = null,
    @"lat. <50%": ?u64 = null,
    @"lat. <99%": ?u64 = null,

    const name_align = 18;
    const val_align = 8;

    fn toStr(comptime int: u8) []const u8 {
        if (int < 10)
            return &[_]u8{'0' + int};
        return &[_]u8{
            '0' + (int / 10),
            '0' + (int % 10),
        };
    }

    pub fn format(
        self: Result,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        const name_fmt = "{s:<" ++ comptime toStr(name_align) ++ "} |";
        const name: []const u8 = self.name orelse "name"[0..];
        try std.fmt.format(writer, name_fmt, .{name});

        inline for ([_][]const u8{
            "mean",
            "stdev",
            "min",
            "max",
            "sum",
        }) |field| {
            const valign = val_align - 2;
            if (@field(self, field)) |value| {
                if (value < 1_000) {
                    try std.fmt.format(writer, " {d:>" ++ toStr(valign) ++ "} |", .{@round(value)});
                } else if (value < 1_000_000) {
                    try std.fmt.format(writer, " {d:>" ++ toStr(valign - 1) ++ ".0}k |", .{value / 1_000});
                } else if (value < 1_000_000_000) {
                    try std.fmt.format(writer, " {d:>" ++ toStr(valign - 1) ++ ".2}m |", .{value / 1_000_000});
                } else {
                    try std.fmt.format(writer, " {d:>" ++ toStr(valign - 1) ++ ".2}b |", .{value / 1_000_000_000});
                }
            } else {
                try std.fmt.format(writer, " {s:>" ++ toStr(valign) ++ "} |", .{field});
            }
        }

        inline for ([_][]const u8{
            "lat. <50%",
            "lat. <99%",
        }) |field| {
            const valign = val_align + 1;
            if (@field(self, field)) |value| {
                if (value < 1_000) {
                    try std.fmt.format(writer, " {:>" ++ toStr(valign - 2) ++ "}ns |", .{value});
                } else if (value < 1_000_000) {
                    try std.fmt.format(writer, " {d:>" ++ toStr(valign - 2) ++ ".2}us |", .{@as(f64, @floatFromInt(value)) / 1_000});
                } else if (value < 1_000_000_000) {
                    try std.fmt.format(writer, " {d:>" ++ toStr(valign - 2) ++ ".2}ms |", .{@as(f64, @floatFromInt(value)) / 1_000_000});
                } else {
                    try std.fmt.format(writer, " {d:>" ++ toStr(valign - 1) ++ ".2}s |", .{@as(f64, @floatFromInt(value)) / 1_000_000_000});
                }
            } else {
                try std.fmt.format(writer, " {s:>" ++ toStr(valign) ++ "} |", .{field});
            }
        }
    }
};

const WorkUnit = struct {
    from: u64,
    to: ?u64,

    fn nanosPerUnit() !f64 {
        var attempts: [10]f64 = undefined;
        for (&attempts) |*attempt| {
            const num_works = 10_000;
            const start = std.time.Instant.now() catch unreachable;

            WorkUnit.run(num_works);
            const elapsed = @as(f64, @floatFromInt((std.time.Instant.now() catch unreachable).since(start)));
            attempt.* = elapsed / @as(f64, num_works);
        }

        var sum: f64 = 0;
        for (attempts) |attempt|
            sum += attempt;
        return sum / @as(f64, @floatFromInt(attempts.len));
    }

    fn scaled(self: WorkUnit, ns_per_unit: f64) WorkUnit {
        return WorkUnit{
            .from = scale(self.from, ns_per_unit),
            .to = if (self.to) |t| scale(t, ns_per_unit) else null,
        };
    }

    fn scale(value: u64, ns_per_unit: f64) u64 {
        return @intFromFloat(@as(f64, @floatFromInt(value)) / ns_per_unit);
    }

    fn count(self: WorkUnit, prng: *u64) u64 {
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
        return @max(1, (rng % (max - min + 1)) + min);
    }

    fn work() void {
        std.atomic.spinLoopHint();
    }

    fn run(iterations: u64) void {
        var i = iterations;
        while (i != 0) : (i -= 1) {
            WorkUnit.work();
        }
    }

    pub fn format(
        self: WorkUnit,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        const from_duration = Duration{ .nanos = self.from };
        if (self.to) |to| {
            const to_duration = Duration{ .nanos = to };
            try std.fmt.format(writer, "rand({}, {})", .{ from_duration, to_duration });
        } else {
            try std.fmt.format(writer, "{}", .{from_duration});
        }
    }
};

const Duration = struct {
    nanos: u64,

    pub fn format(
        self: Duration,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        if (self.nanos < std.time.ns_per_us) {
            try std.fmt.format(writer, "{}ns", .{self.nanos});
        } else if (self.nanos < std.time.ns_per_ms) {
            try std.fmt.format(writer, "{}us", .{self.nanos / std.time.ns_per_us});
        } else if (self.nanos < std.time.ns_per_s) {
            try std.fmt.format(writer, "{}ms", .{self.nanos / std.time.ns_per_ms});
        } else {
            try std.fmt.format(writer, "{}s", .{self.nanos / std.time.ns_per_s});
        }
    }
};