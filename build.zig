const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.build.Builder) void {
    const build_mode = b.standardReleaseOptions();
    const link_libc = b.option(bool, "libc", "Link libc") orelse false;
    const target = b.standardTargetOptions(null);

    const bench = b.addExecutable("bench", "src/main.zig");
    bench.setBuildMode(build_mode);
    bench.setTheTarget(target);
    bench.setOutputDir("zig-cache");
    if (link_libc or (!target.isWindows() and !target.isLinux()))
        bench.linkLibC();

    const step = b.step("bench", "Run the benchmark");
    step.dependOn(&bench.step);
    step.dependOn(&bench.run().step);
}