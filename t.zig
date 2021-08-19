const std = @import("std");
const target = std.Target.current;

const SpinLock = struct {
    pub const name = "spinlock";

    locked: std.atomic.Atomic(bool),

    pub fn init(self: *@This()) void {
        self.locked = @TypeOf(self.locked).init(false);
    }

    pub fn deinit(self: *@This()) void {
        self.* = undefined;
    }

    pub fn acquire(self: *@This()) void {
        while (self.locked.swap(true, .Acquire)) std.atomic.spinLoopHint();
    }

    pub fn release(self: *@This()) void {
        self.locked.store(false, .Release);
    }
};

const lock_impls = .{
    SpinLock,
};

fn print(comptime fmt: []const u8, args: anytype) void {
    std.io.getStdOut().writer().print(fmt, args) catch @panic("failed to write to stdout");
}

fn help(exe: []const u8) void {
    const exe_file = std.fs.path.basename(exe);
    print(
        \\ Usage: {s} [measure] [threads] [locked] [unlocked]
        \\  Example: {s} 1s 1,2,4,8 100ns 1us
        \\
        \\{s}
    ,
        .{
            exe_file,
            exe_file,
            \\where:
            \\ [measure]:  [permutations:time]  \\ List of time spent measuring for each mutex benchmark
            \\ [threads]:  [permutations:count] \\ List of thread counts for each benchmark
            \\ [locked]:   [permutations:time]  \\ List of time spent inside the lock for each benchmark
            \\ [unlocked]: [cpermutations:time] \\ List of time spent outside the lock for each benchmark
            \\
            \\where:
            \\ [count]:     {usize}
            \\ [time]:      {u64}[time_unit]
            \\ [time_unit]: "ns" | "us" | "ms" | "s"
            \\
            \\ // One or more permutations of the unit. Available for all options
            \\ [permutations:{unit}]: 
            \\      | [value:{unit}]
            \\      | [value:{unit}] ("," [value:{unit}])+
            \\
            \\ [value:{unit}]:
            \\      | {unit}
            \\      | {unit<start>} "-" {unit<end>} // A range of units.
            \\          // [thread]: <start> to <end> permutations of thread counts
            \\          // [locked]: random time spent between <start> to <end> inside the lock
            \\          // [unlocked]: random time spent between <start> to <end> outside the lock
            \\
        },
    );
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = undefined;
    var win_heap: if (target.os.tag == .windows) std.heap.HeapAllocator else void = undefined;

    const base_allocator = blk: {
        if (std.builtin.link_libc) break :blk std.heap.c_allocator;
        if (target.os.tag == .windows) {
            win_heap = std.heap.HeapAllocator.init();
            win_heap.heap_handle = std.os.windows.kernel32.GetProcessHeap() orelse return error.ProcessHeap;
            break :blk &win_heap.allocator;
        }
        gpa = @TypeOf(gpa){};
        break :blk &gpa.allocator;
    };

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
    const exe = try (args.next(allocator) orelse return error.ArgsWithoutExe);
    ArgParser.parse(Duration, allocator, &args, &measures, ArgParser.collectDuration) catch return help(exe);
    ArgParser.parse(usize, allocator, &args, &threads, ArgParser.collectThreads) catch return help(exe);
    ArgParser.parse(WorkUnit, allocator, &args, &locked, ArgParser.collectWorkUnit) catch return help(exe);
    ArgParser.parse(WorkUnit, allocator, &args, &unlocked, ArgParser.collectWorkUnit) catch return help(exe);

    const timer_scale = Timer.getScale();
    const work_unit_per_nanos = WorkUnit.computeWorkPerNanos(timer_scale);

    for (measures.items) |measure_time| {
        for (threads.items) |num_threads| {
            for (locked.items) |work_locked| {
                for (unlocked.items) |work_unlocked| {
                    print("measure={} threads={} locked={} unlocked={}\n{s}\n", .{
                        measure_time,
                        num_threads,
                        work_locked,
                        work_unlocked,
                        "-" ** 90,
                    });

                    const header = Benchmark.Result{};
                    print("{}\n", .{header});
                    defer print("\n", .{});

                    inline for (lock_impls) |Lock| {
                        const result = try Benchmark.bench(
                            Lock,
                            timer_scale,
                            allocator,
                            base_allocator,
                            measure_time,
                            num_threads,
                            work_locked.scaled(work_unit_per_nanos),
                            work_unlocked.scaled(work_unit_per_nanos),
                        );
                        print("{}\n", .{result});
                    }
                }
            }
        }
    }
}

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
        if (self.nanos >= std.time.ns_per_s) {
            const value = @intToFloat(f64, self.nanos) / @as(f64, std.time.ns_per_s);
            try std.fmt.format(writer, "{d:.2}s", .{value});
        } else if (self.nanos >= std.time.ns_per_ms) {
            const value = @intToFloat(f64, self.nanos) / @as(f64, std.time.ns_per_ms);
            try std.fmt.format(writer, "{d:.2}ms", .{value});
        } else if (self.nanos >= std.time.ns_per_us) {
            const value = @intToFloat(f64, self.nanos) / @as(f64, std.time.ns_per_us);
            try std.fmt.format(writer, "{d:.2}us", .{value});
        } else {
            try std.fmt.format(writer, "{d}ns", .{self.nanos});
        }
    }
};

const Timer = struct {
    pub usingnamespace switch (target.os.tag) {
        .macos, .ios, .tvos, .watchos => DarwinTimer,
        .windows => WindowsTimer,
        else => PosixTimer,
    };

    const WindowsTimer = struct {
        pub fn read() u64 {
            return std.os.windows.QueryPerformanceCounter();
        }

        pub fn getScale() u64 {
            return std.os.windows.QueryPerformanceFrequency();
        }

        pub fn toDuration(diff: u64, scale: u64) Duration {
            return Duration{ .nanos = (diff * std.time.ns_per_s) / scale };
        }
    };

    const PosixTimer = struct {
        pub fn read() u64 {
            var ts: std.os.timespec = undefined;
            std.os.clock_gettime(std.os.CLOCK_MONOTONIC, &ts) catch unreachable;
            return @intCast(u64, ts.tv_sec) * std.time.ns_per_s + @intCast(u64, ts.tv_nsec);
        }

        pub fn getScale() u64 {
            return undefined;
        }

        pub fn toDuration(diff: u64, scale: u64) Duration {
            _ = scale;
            return Duration{ .nanos = diff };
        }
    };

    const DarwinTimer = struct {
        pub fn read() u64 {
            return std.os.darwin.mach_absolute_time();
        }

        pub fn getScale() u64 {
            var info: std.os.darwin.mach_timebase_info_data = undefined;
            std.os.darwin.mach_timebase_info(&info);
            return (@as(u64, info.numer) << 32) | info.denom;
        }

        pub fn toDuration(diff: u64, scale: u64) Duration {
            const denom = @truncate(u32, scale);
            const numer = @truncate(u32, scale >> 32);
            return Duration{ .nanos = (diff * numer) / denom };
        }
    };
};

const WorkUnit = union(enum) {
    fixed: u64,
    range: struct {
        begin: u64,
        end: u64,
    },

    pub fn format(
        self: WorkUnit,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        switch (self) {
            .fixed => |nanos| {
                const d = Duration{ .nanos = nanos };
                try std.fmt.format(writer, "{}", .{d});
            },
            .range => |r| {
                const begin = Duration{ .nanos = r.begin };
                const end = Duration{ .nanos = r.end };
                try std.fmt.format(writer, "{}-{}", .{ begin, end });
            },
        }
    }

    fn work() void {
        std.atomic.spinLoopHint();
    }

    fn computeWorkPerNanos(timer_scale: u64) f64 {
        const num_attempts = 100;
        const num_iters = 10_000;

        var attempts: [num_attempts]f64 = undefined;
        for (attempts) |*attempt| {
            const elapsed = while (true) {
                const begin = Timer.read();
                var i: usize = num_iters;
                while (i > 0) : (i -= 1) work();
                const end = Timer.read();
                if (end >= begin) break (end - begin);
            } else unreachable;

            const elapsed_ns = Timer.toDuration(elapsed, timer_scale).nanos;
            const work_per_ns = @intToFloat(f64, elapsed_ns) / @as(f64, num_iters);
            attempt.* = work_per_ns;
        }

        var sum: f64 = 0;
        for (attempts) |attempt| sum += attempt;
        return sum / @as(f64, num_attempts);
    }

    fn scaled(self: WorkUnit, work_per_ns: f64) WorkUnit {
        return switch (self) {
            .fixed => |ns| WorkUnit{
                .fixed = std.math.max(1, @floatToInt(u64, @intToFloat(f64, ns) * work_per_ns)),
            },
            .range => |r| WorkUnit{
                .range = .{
                    .begin = std.math.max(1, @floatToInt(u64, @intToFloat(f64, r.begin) * work_per_ns)),
                    .end = std.math.max(1, @floatToInt(u64, @intToFloat(f64, r.end) * work_per_ns)),
                },
            },
        };
    }

    fn execute(self: WorkUnit, prng: *u32) void {
        var num_iters = switch (self) {
            .fixed => |v| v,
            .range => |r| blk: {
                var xorshift = prng.*;
                xorshift ^= xorshift >> 17;
                xorshift ^= xorshift << 13;
                xorshift ^= xorshift >> 5;
                prng.* = xorshift;
                break :blk (@as(u64, xorshift) % (r.end - r.begin)) + r.begin;
            },
        };

        while (num_iters > 0) : (num_iters -= 1) {
            work();
        }
    }
};

const ArgParser = struct {
    fn parse(
        comptime T: type,
        allocator: *std.mem.Allocator,
        args: *std.process.ArgIterator,
        array_list: *std.ArrayList(T),
        comptime collectFn: anytype,
    ) !void {
        const arg: []const u8 = try (args.next(allocator) orelse return error.ExpectedArg);
        var items = std.mem.tokenize(arg, ",");
        while (items.next()) |item| {
            var first = item;
            const second = blk: {
                const split = std.mem.indexOf(u8, item, "-") orelse break :blk null;
                first = item[0..split];
                break :blk item[(split + 1)..];
            };
            try collectFn(
                array_list,
                try Item.parse(first),
                if (second) |s| try Item.parse(s) else null,
            );
        }
    }

    const Item = struct {
        number: u64,
        scale: ?u64,

        fn parse(arg: []const u8) !Item {
            var i: usize = 0;
            while (i < arg.len and arg[i] >= '0' and arg[i] <= '9') i += 1;
            return Item{
                .number = try std.fmt.parseInt(u64, arg[0..i], 10),
                .scale = blk: {
                    const scale = arg[std.math.min(i, arg.len)..];
                    if (scale.len == 0) break :blk null;
                    if (std.mem.eql(u8, scale, "ns")) break :blk 1;
                    if (std.mem.eql(u8, scale, "us")) break :blk std.time.ns_per_us;
                    if (std.mem.eql(u8, scale, "ms")) break :blk std.time.ns_per_ms;
                    if (std.mem.eql(u8, scale, "s")) break :blk std.time.ns_per_s;
                    return error.InvalidTimeUnit;
                },
            };
        }
    };

    fn collectDuration(array_list: *std.ArrayList(Duration), first: Item, second: ?Item) !void {
        if (second != null) return error.MeasurementWithRange;
        const scale = first.scale orelse return error.MeasurementNotInTimeUnits;
        try array_list.append(Duration{ .nanos = first.number * scale });
    }

    fn collectThreads(array_list: *std.ArrayList(usize), first: Item, second: ?Item) !void {
        if (first.scale != null) return error.ThreadsInTimeUnits;
        var begin = first.number;
        var end = blk: {
            const item = second orelse break :blk begin;
            if (item.scale != null) return error.ThreadsRangeInTimeUnits;
            break :blk item.number;
        };

        if (end < begin) return error.ThreadsRangeInvalid;
        while (begin <= end) : (begin += 1) {
            const threads = try std.math.cast(usize, begin);
            try array_list.append(threads);
        }
    }

    fn collectWorkUnit(array_list: *std.ArrayList(WorkUnit), first: Item, second: ?Item) !void {
        const begin = blk: {
            const scale = first.scale orelse return error.WorkUnitNotInTimeUnits;
            break :blk first.number * scale;
        };

        var work_unit = WorkUnit{ .fixed = begin };
        if (second) |item| {
            const scale = item.scale orelse return error.WorkUnitRangeNotInTimeUnits;
            const end = item.number * scale;
            if (end < begin) return error.WorkUnitRangeInvalid;
            work_unit = WorkUnit{
                .range = .{
                    .begin = begin,
                    .end = end,
                },
            };
        }

        try array_list.append(work_unit);
    }
};

const Benchmark = struct {
    const Count = struct {
        value: u64,

        pub fn format(
            self: Count,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;
            if (self.value >= 1_000_000_000) {
                const value = @intToFloat(f64, self.value) / @as(f64, 1_000_000_000);
                try std.fmt.format(writer, "{d:.2}b", .{value});
            } else if (self.value >= 1_000_000) {
                const value = @intToFloat(f64, self.value) / @as(f64, 1_000_000);
                try std.fmt.format(writer, "{d:.2}m", .{value});
            } else if (self.value >= 1_000) {
                const value = @intToFloat(f64, self.value) / @as(f64, 1_000);
                try std.fmt.format(writer, "{d:.0}k", .{value});
            } else {
                const value = self.value;
                try std.fmt.format(writer, "{d}", .{value});
            }
        }
    };

    const Result = struct {
        name: ?[]const u8 = null,
        mean: ?Count = null,
        stdev: ?Count = null,
        min: ?Count = null,
        max: ?Count = null,
        sum: ?Count = null,
        @"lat. 50%": ?Duration = null,
        @"lat. 90%": ?Duration = null,
        @"lat. 99%": ?Duration = null,
        @"lat. max": ?Duration = null,

        const name_align = "18";
        const value_align = "8";

        pub fn format(
            self: Result,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;
            inline for (std.meta.fields(Result)) |field_info| {
                const field = field_info.name;
                if (comptime std.mem.eql(u8, field, "name")) {
                    const name_fmt = "{s:<" ++ name_align ++ "} |";
                    const name: []const u8 = self.name orelse field;
                    try std.fmt.format(writer, name_fmt, .{name});
                } else if (@field(self, field)) |value| {
                    const value_fmt = " {:>" ++ value_align ++ "} |";
                    try std.fmt.format(writer, value_fmt, .{value});
                } else {
                    const base_fmt = " {s:>" ++ value_align ++ "} |";
                    const base: []const u8 = if (self.name == null) field else "n/a";
                    try std.fmt.format(writer, base_fmt, .{base});
                }
            }
        }
    };

    const Coordinator = struct {
        state: Atomic(State) = Atomic(State).init(.ready),

        const Futex = std.Thread.Futex;
        const Atomic = std.atomic.Atomic;
        const State = enum(u32) {
            ready,
            run,
            stop,
        };

        fn wait(self: *const Coordinator) void {
            while (self.state.load(.Acquire) == .ready) {
                Futex.wait(
                    @ptrCast(*const Atomic(u32), &self.state),
                    @enumToInt(State.ready),
                    null,
                ) catch unreachable;
            }
        }

        fn wake(self: *Coordinator, state: State) void {
            self.state.store(state, .Release);
            Futex.wake(
                @ptrCast(*const Atomic(u32), &self.state),
                std.math.maxInt(u32),
            );
        }

        fn isRunning(self: *const Coordinator) bool {
            return self.state.load(.SeqCst) == .run;
        }

        fn start(self: *Coordinator) void {
            return self.wake(.run);
        }

        fn stop(self: *Coordinator) void {
            return self.wake(.stop);
        }
    };

    const Worker = struct {
        thread: std.Thread,
        num_iters: ?u64,
        latencies: std.ArrayList(u64),
        arena: std.heap.ArenaAllocator,

        fn getRunner(comptime Lock: type) type {
            return struct {
                pub fn run(
                    self: *Worker,
                    seed: usize,
                    lock: *Lock,
                    coordinator: *const Coordinator,
                    locked: WorkUnit,
                    unlocked: WorkUnit,
                ) void {
                    var prng: u32 = @truncate(u32, seed + 1);
                    coordinator.wait();

                    while (coordinator.isRunning()) {
                        unlocked.execute(&prng);

                        const begin_acquire = Timer.read();
                        lock.acquire();
                        const end_acquire = Timer.read();

                        locked.execute(&prng);
                        lock.release();
                        self.num_iters = (self.num_iters orelse 0) + 1;

                        if (end_acquire < begin_acquire) continue;
                        const latency = end_acquire - begin_acquire;
                        self.latencies.append(latency) catch {};
                    }
                }
            };
        }
    };

    fn bench(
        comptime Lock: type,
        timer_scale: u64,
        allocator: *std.mem.Allocator,
        base_allocator: *std.mem.Allocator,
        measure: Duration,
        num_threads: usize,
        locked: WorkUnit,
        unlocked: WorkUnit,
    ) !Result {
        var lock: Lock = undefined;
        lock.init();
        defer lock.deinit();

        const workers = try allocator.alloc(Worker, num_threads);
        defer allocator.free(workers);

        defer for (workers) |w| w.arena.deinit();
        for (workers) |*w| {
            w.num_iters = null;
            w.arena = std.heap.ArenaAllocator.init(base_allocator);
            w.latencies = std.ArrayList(u64).init(&w.arena.allocator);
        }

        {
            var spawned: usize = 0;
            var coordinator = Coordinator{};
            defer {
                coordinator.stop();
                for (workers[0..spawned]) |worker| {
                    worker.thread.join();
                }
            }

            while (spawned < workers.len) : (spawned += 1) {
                workers[spawned].thread = try std.Thread.spawn(.{}, Worker.getRunner(Lock).run, .{
                    &workers[spawned],
                    spawned,
                    &lock,
                    &coordinator,
                    locked,
                    unlocked,
                });
            }

            coordinator.start();
            std.time.sleep(measure.nanos);
        }

        var sum: ?u64 = null;
        var min: ?u64 = null;
        var max: ?u64 = null;
        var latency_min: ?u64 = null;
        var latency_max: ?u64 = null;

        for (workers) |w| {
            const iters = w.num_iters orelse continue;
            sum = (sum orelse 0) + iters;
            max = std.math.max(iters, max orelse 0);
            min = std.math.min(iters, min orelse std.math.maxInt(u64));
            for (w.latencies.items) |latency| {
                latency_max = std.math.max(latency, latency_max orelse 0);
                latency_min = std.math.min(latency, latency_min orelse std.math.maxInt(u64));
            }
        }

        const mean = blk: {
            const s = sum orelse break :blk null;
            break :blk @divFloor(s, workers.len);
        };

        const stdev = blk: {
            var stdev: ?f64 = 0;
            for (workers) |w| {
                const r = (w.num_iters orelse continue) - (mean orelse continue);
                stdev = (stdev orelse 0.0) + @intToFloat(f64, r * r);
            }
            var s = stdev orelse break :blk null;
            if (workers.len > 1) {
                s /= @intToFloat(f64, workers.len - 1);
                s = @sqrt(s);
            }
            break :blk @floatToInt(u64, s);
        };

        const percentiles = [_]f64{ 50.0, 90.0, 99.0 };
        var latency_percentiles = [_]?Duration{null} ** percentiles.len;

        compute_latency: {
            const lat_max = latency_max orelse break :compute_latency;
            const lat_min = latency_min orelse break :compute_latency;

            const lat_range = lat_max - lat_min;
            const lat_bins = std.math.cast(usize, lat_range + 1) catch break :compute_latency;
            const lat_width = lat_range / lat_bins;

            const lat_histogram = allocator.alloc(u64, lat_bins) catch break :compute_latency;
            defer allocator.free(lat_histogram);

            var lat_total: usize = 0;
            for (lat_histogram) |*bin| bin.* = 0;
            for (workers) |w| {
                for (w.latencies.items) |latency| {
                    const lat_bin = (latency - lat_min) / lat_width;
                    lat_histogram[lat_bin] += 1;
                    lat_total += 1;
                }
            }

            const lat_sum = @intToFloat(f64, lat_total);
            var lat_limits: [percentiles.len]f64 = undefined;
            inline for (percentiles) |p, index| {
                lat_limits[index] = (p * lat_sum) / 100.0;
            }

            lat_total = 0;
            for (lat_histogram) |bin_count, index| {
                lat_total += bin_count;
                for (lat_limits) |limit, lat_index| {
                    if (latency_percentiles[lat_index] != null) continue;
                    if (@intToFloat(f64, lat_total) < limit) continue;
                    const delta = index * lat_width;
                    latency_percentiles[lat_index] = Timer.toDuration(delta, timer_scale);
                }
            }
        }

        return Result{
            .name = Lock.name,
            .mean = if (mean) |m| Count{ .value = m } else null,
            .stdev = if (stdev) |s| Count{ .value = s } else null,
            .min = if (min) |m| Count{ .value = m } else null,
            .max = if (max) |m| Count{ .value = m } else null,
            .@"lat. 50%" = latency_percentiles[0],
            .@"lat. 90%" = latency_percentiles[1],
            .@"lat. 99%" = latency_percentiles[2],
            .@"lat. max" = if (latency_max) |m| Timer.toDuration(m, timer_scale) else null,
        };
    }
};
