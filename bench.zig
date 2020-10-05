
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
const sync = @import("./sync/sync.zig");

const print = std.debug.warn;
const nanotime = sync.nanotime;
const allocator = if (std.builtin.link_libc) std.heap.c_allocator else std.heap.page_allocator;

fn benchAll(b: Benchmarker) !void {
    try benchLock(b, "spin");
    try benchLock(b, "os");
    try benchLock(b, "std");
    try benchLock(b, "word");
}

fn benchLock(b: Benchmarker, comptime lock_name: []const u8) !void {
    try b.bench(@import("./locks/" ++ lock_name ++ ".zig").Lock);
}

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
                        .work_inside = work_locked,
                        .work_outside = work_unlocked,
                    };

                    print("measure=", .{});
                    (Duration{ .value = measure }).fmtPrint();
                    print(" threads={} locked=", .{num_threads});
                    b.work_inside.fmtPrint();
                    print(" unlocked=", .{});
                    b.work_outside.fmtPrint();
                    print("\n{}\n", .{"-" ** 75});
                    (BenchmarkResult{}).fmtPrint();
                    print("\n", .{});

                    b.work_inside = b.work_inside.scaled(work_per_ns);
                    b.work_outside = b.work_outside.scaled(work_per_ns);
                    try benchAll(b);
                    print("\n", .{});
                }
            }
        }
    }
}

fn parse(
    args: *std.process.ArgIterator,
    array_list: anytype,
    comptime allow_time: bool,
    comptime is_ranged: bool,
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

        if (is_ranged) {
            const end = to orelse from;
            var start = from;
            while (start <= end) : (start += 1) {
                try array_list.append(start);
            }
        } else {
            if (to) |_to| {
                if (from > _to) {
                    return error.InvalidRange;
                }
            }   
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
    while (buf.len > 0) : ({ buf = buf[1..]; consumed += 1; }) {
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

    const mult: u64 = switch (buf[0]) {
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
                    info.lock.withLock((struct {
                        work_units: u64, 
                        pub fn run(_ctx: @This()) void {
                            WorkUnit.run(_ctx.work_units);
                        }
                    }){
                        .work_units = info.wrk_inside.count(&prng),
                    });

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
            thread.wait();

        var sum: f64 = 0;
        for (results) |iters|
            sum += @intToFloat(f64, iters);
        const mean = sum / @intToFloat(f64, results.len);

        var stdev: f64 = 0;
        for (results) |iters| {
            const r = @intToFloat(f64, iters) - mean;
            stdev += r * r;
        }
        if (results.len > 1) {
            stdev /= @intToFloat(f64, results.len - 1);
            stdev = @sqrt(stdev);
        }

        const cmp = comptime std.sort.asc(u64);
        std.sort.sort(u64, results, {}, cmp);
        const min = results[0];
        const max = results[results.len - 1];

        (BenchmarkResult{
            .name = Lock.name,
            .mean = @floatToInt(u64, mean),
            .stdev = @floatToInt(u64, stdev),
            .min = min,
            .max = max,
            .sum = @floatToInt(u64, sum),
        }).fmtPrint();
        print("\n", .{});
    }
};

const BenchmarkResult = struct {
    name: ?[]const u8 = null,
    mean: ?u64 = null,
    stdev: ?u64 = null,
    min: ?u64 = null,
    max: ?u64 = null,
    sum: ?u64 = null,

    const name_align = "18";
    const num_align = "8";
    const val_align = "7";

    pub fn fmtPrint(self: BenchmarkResult) void {
        if (self.name) |name| {
            print("{s:<" ++ name_align ++ "}", .{name});
        } else {
            print("{s:<" ++ name_align ++ "}", .{"name"});
        }
        print(" | ", .{});

        if (self.mean) |mean| {
            printNum(mean);
        } else {
            print("{s:>" ++ num_align ++ "}", .{"mean"});
        }
        print(" | ", .{});

        if (self.stdev) |stdev| {
            printNum(stdev);
        } else {
            print("{s:>" ++ num_align ++ "}", .{"stdev"});
        }
        print(" | ", .{});

        if (self.min) |min| {
            printNum(min);
        } else {
            print("{s:>" ++ num_align ++ "}", .{"min"});
        }
        print(" | ", .{});

        if (self.max) |max| {
            printNum(max);
        } else {
            print("{s:>" ++ num_align ++ "}", .{"max"});
        }
        print(" | ", .{});

        if (self.sum) |sum| {
            printNum(sum);
        } else {
            print("{s:>" ++ num_align ++ "}", .{"sum"});
        }
        print(" |", .{});
    }

    fn printNum(num: u64) void {
        if (num < 1000) {
            print("{d:>" ++ num_align ++ ".0}", .{div(num, 1)});
        } else if (num < 1_000_000) {
            print("{d:>" ++ val_align ++ ".0}k", .{div(num, 1000)});
        } else if (num < 1_000_000_000) {
            print("{d:>" ++ val_align ++ ".2}m", .{div(num, 1_000_000)});
        } else {
            print("{d:>" ++ val_align ++ ".2}b", .{div(num, 1_000_000_000)});
        }
    }

    fn div(num: u64, scale: f64) f64 {
        return @intToFloat(f64, num) / scale;
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

    fn run(iters: u64) void {
        var i = iters;
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
                    const start = nanotime();
                    _ = nanotime();
                    break :blk nanotime() - start;
                };

                const num_steps = 10_000;
                const ns = blk: {
                    run(num_steps);
                    const start = nanotime();
                    run(num_steps);
                    break :blk nanotime() - start;
                };

                const elapsed = ns - timer_overhead;
                break :compute std.math.max(1, elapsed / num_steps);
            };
        }

        var sum: u64 = 0;
        for (attempts) |attempt|
            sum += attempt;
        return sum / attempts.len;
    }

    pub fn fmtPrint(self: WorkUnit) void {
        const from = Duration{ .value = self.from };
        if (self.to) |to| {
            print("rand(", .{});
            from.fmtPrint();
            print(", ", .{});
            (Duration{ .value = to }).fmtPrint();
            print(")", .{});
        } else {
            from.fmtPrint();
        }
    }
};

const Duration = struct {
    value: u64,

    pub fn fmtPrint(self: Duration) void {
        if (self.value < std.time.ns_per_us) {
            print("{}ns", .{self.value});
        } else if (self.value < std.time.ns_per_ms) {
            print("{}us", .{self.value / std.time.ns_per_us});
        } else if (self.value < std.time.ns_per_s) {
            print("{}ms", .{self.value / std.time.ns_per_ms});
        } else {
            print("{}s", .{self.value / std.time.ns_per_s});
        }
    }
};