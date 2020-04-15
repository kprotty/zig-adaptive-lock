const std = @import("std");
const allocator = if (std.builtin.link_libc) std.heap.c_allocator else std.heap.page_allocator;

const mutexes = .{
    @import("./mutexes/os.zig").Mutex,
    @import("./mutexes/spin.zig").Mutex,
    @import("./mutexes/std.zig").Mutex,
};

pub fn main() !void {
    var ctx: BenchContext = undefined;

    var args = std.process.args();
    _ = try (args.next(allocator) orelse unreachable);
    const mode = (args.next(allocator) orelse return help()) catch return help();
    if (std.mem.eql(u8, mode, "throughput")) {
        ctx.mode = .Throughput;
    } else if (std.mem.eql(u8, mode, "latency")) {
        ctx.mode = .Latency;
    } else if (std.mem.eql(u8, mode, "fairness")) {
        ctx.mode = .Fairness;
    } else {
        return help();
    }

}

fn help() void {
    std.debug.warn(
        \\\Usage: [command] [options]
        \\\
        \\\Commands:
        \\\ throughput:     Measure overall system progress excluding individul thread progress
        \\\ latency:        Measure avg time to acquire over all threads
        \\\ fairness:       Measure how even of a chance each thread has at lock acquisition
    )
}

const BenchContext = struct {
    mode: enum {
        Throughput,
    },
    num_threads: usize,
    work_in_lock: u64,
    work_outside_lock: u64,
};

fn withThreads(ctx: *BenchContext, comptime next: var) !void {
    const max_threads = try std.Thread.cpuCount();

    var threads = std.ArrayList(usize).init(allocator);
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
    
    var i = threads.items.len;
    while (i > 0) : (i -= 1) {
        ctx.num_threads = threads.items[i - 1];
        next(ctx);
    }
}