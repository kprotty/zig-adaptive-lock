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

const std = @import("std");

const locks = .{
    "spin",
    "ticket",
    "os",
};

fn help() void {
    print("{}", .{
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
    // use an arena allocator for all future allocations
    const base_allocator = if (std.builtin.link_libc) std.heap.c_allocator else std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;

    var measures = std.ArrayList(Duration).init(allocator);
    defer measures.deinit();

    var threads = std.ArrayList(usize).init(allocator);
    defer threads.deinit();

    var locked = std.ArrayList(WorkUnit).init(allocator);
    defer locked.deinit();

    var unlocked = std.ArrayList(WorkUnit).init(allocator);
    defer unlocked.deinit();

    var args = std.process.args();
    _ = try (args.next(allocator) orelse unreachable);
    Parser.parse(allocator, &args, &measures, Parser.toMeasure) catch return help();
    Parser.parse(allocator, &args, &threads, Parser.toThread) catch return help();
    Parser.parse(allocator, &args, &locked, Parser.toWorkUnit) catch return help(); 
    Parser.parse(allocator, &args, &unlocked, Parser.toWorkUnit) catch return help();

    const nanos_per_work_unit = try WorkUnit.nanosPerUnit();

    for (unlocked.items) |work_unlocked| {
        for (locked.items) |work_locked| {
            for (threads.items) |num_threads| {
                for (measures.items) |measure| {
                    print("measure={} threads={} locked={} unlocked={}\n{}\n", .{
                        measure,
                        num_threads,
                        work_locked,
                        work_unlocked,
                        "-" ** 75,
                    });

                    const header_result = Result{};
                    print("{}\n", .{header_result});

                    inline for (locks) |lock| {
                        const Lock = @import("./locks/" ++ lock ++ ".zig").Lock;
                        const result = try bench(Lock, BenchConfig{
                            .allocator = allocator,
                            .num_threads = num_threads,
                            .measure = measure,
                            .work_locked = work_locked.scaled(nanos_per_work_unit),
                            .work_unlocked = work_unlocked.scaled(nanos_per_work_unit),
                        });
                        print("{}\n", .{result});
                    }

                    print("\n", .{});
                }
            }
        }
    }
}

const BenchConfig = struct {
    allocator: *std.mem.Allocator,
    num_threads: usize,
    measure: Duration,
    work_locked: WorkUnit,
    work_unlocked: WorkUnit,
};

fn bench(comptime Lock: type, config: BenchConfig) !Result {
    const Context = struct {
        lock: Lock,
        event: std.ResetEvent align(512),
        is_running: bool,
        results: []f64 align(512),
        work_locked: WorkUnit,
        work_unlocked: WorkUnit,
        
        const Self = @This();
        const RunInfo = struct {
            context: *Self,
            index: usize,
        };

        fn run(run_info: RunInfo) void {
            const self = run_info.context;
            const result = &self.results[run_info.index];

            var lock_operations: u64 = 0;
            defer result.* = @intToFloat(f64, lock_operations);

            var prng = @as(u64, @ptrToInt(self) ^ @ptrToInt(result));
            self.event.wait();

            const base_work_locked = self.work_locked;
            const base_work_unlocked = self.work_unlocked;

            var works_locked = base_work_locked.count(&prng);
            var works_unlocked = base_work_unlocked.count(&prng);

            while (@atomicLoad(bool, &self.is_running, .SeqCst)) {
                self.lock.acquire();
                WorkUnit.run(works_locked);
                
                self.lock.release();
                WorkUnit.run(works_unlocked);

                lock_operations += 1;

                if (lock_operations % 10_000 == 0) {
                    works_locked = base_work_locked.count(&prng);
                    works_unlocked = base_work_unlocked.count(&prng);
                }
            }
        }
    };

    const results = try config.allocator.alloc(f64, config.num_threads);
    defer config.allocator.free(results);
    
    {
        const context = try config.allocator.create(Context);
        defer config.allocator.destroy(context);

        context.is_running = true;
        context.results = results;
        context.work_locked = config.work_locked;
        context.work_unlocked = config.work_unlocked;

        context.lock.init();
        defer context.lock.deinit();

        context.event = std.ResetEvent.init();
        defer context.event.deinit();

        const threads = try config.allocator.alloc(*std.Thread, config.num_threads);
        defer config.allocator.free(threads);

        for (threads) |*thread, index| {
            thread.* = try std.Thread.spawn(
                Context.RunInfo{
                    .context = context,
                    .index = index,
                },
                Context.run,
            );
        }

        context.event.set();
        std.time.sleep(config.measure.nanos);

        @atomicStore(bool, &context.is_running, false, .SeqCst);
        for (threads) |thread| {
            thread.wait();
        }
    }

    var sum: f64 = 0;
    for (results) |lock_operations|
        sum += lock_operations;
    const mean = sum / @intToFloat(f64, results.len);

    var stdev: f64 = 0;
    for (results) |lock_operations| {
        const r = lock_operations - mean;
        stdev += r * r;
    }
    if (results.len > 1) {
        stdev /= @intToFloat(f64, results.len - 1);
        stdev = @sqrt(stdev);
    }

    std.sort.sort(f64, results, {}, comptime std.sort.asc(f64));
    const min = results[0];
    const max = results[results.len - 1];

    return Result{
        .name = Lock.name,
        .mean = mean,
        .stdev = stdev,
        .min = min,
        .max = max,
        .sum = sum,
    };
}

const Parser = struct {
    fn parse(
        allocator: *std.mem.Allocator,
        args: *std.process.ArgIterator,
        results: anytype,
        comptime resolveFn: anytype,
    ) !void {
        var input = try (args.next(allocator) orelse return error.ExpectedArg);
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
                try results.append(@intCast(usize, thread));
        } else if (a.mult != null) {
            return error.ThreadsTakeValuesNotTimeUnits;
        } else {
            try results.append(@intCast(usize, a.value));
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
                var m: u64 = switch (buf[0]) {
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

    const name_align = 18;
    const val_align = 8;

    fn toStr(comptime int: usize) []const u8 {
        @setEvalBranchQuota(2000);
        comptime var buffer: [64]u8 = undefined;
        return std.fmt.bufPrint(&buffer, "{}", .{int}) catch unreachable;
    }

    pub fn format(
        self: Result,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        const name_fmt = "{s:<" ++ toStr(name_align) ++ "} |";
        const name: []const u8 = self.name orelse "name"[0..];
        try std.fmt.format(writer, name_fmt, .{name});

        inline for ([_][]const u8 {
            "mean",
            "stdev",
            "min",
            "max",
            "sum",
        }) |field, index| {
            if (@field(self, field)) |value| {
                if (value < 1_000) {
                    try std.fmt.format(writer, " {d:>" ++ toStr(val_align) ++ "} |", .{@round(value)});
                } else if (value < 1_000_000) {
                    try std.fmt.format(writer, " {d:>" ++ toStr(val_align - 1) ++ ".0}k |", .{value / 1_000});
                } else if (value < 1_000_000_000) {
                    try std.fmt.format(writer, " {d:>" ++ toStr(val_align - 1) ++ ".2}m |", .{value / 1_000_000});
                } else {
                    try std.fmt.format(writer, " {d:>" ++ toStr(val_align - 1) ++ ".2}b |", .{value / 1_000_000_000});
                }
            } else {
                try std.fmt.format(writer, " {s:>" ++ toStr(val_align) ++ "} |", .{field});
            }
        }
    }
};

const WorkUnit = struct {
    from: u64,
    to: ?u64,

    fn nanosPerUnit() !u64 {
        var timer = try std.time.Timer.start();
        
        var attempts: [10]u64 = undefined;
        for (attempts) |*attempt| {
            const timer_start = timer.read();
            _ = timer.read();
            const timer_overhead = timer.read() - timer_start;

            const num_works = 10_000;
            WorkUnit.run(num_works);
            const work_start = timer.read();
            WorkUnit.run(num_works);
            const work_overhead = timer.read() - work_start;

            const elapsed = work_overhead - timer_overhead;
            const ns_per_work = elapsed / num_works;
            attempt.* = std.math.max(1, ns_per_work); 
        }

        var sum: u64 = 0;
        for (attempts) |attempt|
            sum += attempt;
        return sum / attempts.len;
    }

    fn scaled(self: WorkUnit, div: u64) WorkUnit {
        return WorkUnit{
            .from = self.from / div,
            .to = if (self.to) |t| t / div else null,
        };
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
        return (rng % (max - min + 1)) + min;
    }

    fn work() void {
        switch (std.builtin.arch) {
            .i386, .x86_64 => asm volatile("pause" ::: "memory"),
            .arm, .aarch64 => asm volatile("yield" ::: "memory"),
            else => {
                var local: usize = undefined;
                var load = @ptrCast(*volatile usize, &local).*;
            },
        }
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
        const from_duration = Duration{ .nanos = self.from };
        if (self.to) |to| {
            const to_duration = Duration{ .nanos = to };
            try std.fmt.format(writer, "rand({}, {})", .{from_duration, to_duration});   
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