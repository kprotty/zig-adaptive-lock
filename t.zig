const std = @import("std");

pub fn main() void {
    std.debug.warn("{:>4}|{:>4}|\n", .{"hi", "world"});
}