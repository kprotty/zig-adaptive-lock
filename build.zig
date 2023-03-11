const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const c = b.option(bool, "c", "link libc") orelse false;
    const tsan = b.option(bool, "tsan", "build with ThreadSanitizer") orelse false;

    const exe = b.addExecutable(.{
        .name = "bench",
        .target = target,
        .optimize = optimize,
        .root_source_file = .{ .path = "bench.zig" },
    });
    if (c) exe.linkLibC();
    exe.sanitize_thread = tsan;
    exe.install();

    const run = exe.run();
    if (b.args) |args| run.addArgs(args);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run.step);
}