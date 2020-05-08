const std = @import("std");

pub fn main() void {
    var buf: [100]u8 = undefined;
    const c = std.fmt.bufPrint(
        buf[0..],
        "|{:x<20}|",
        .{@as(i64, 0)},
    ) catch unreachable;
    
    std.debug.warn("{}\n", .{c});
}