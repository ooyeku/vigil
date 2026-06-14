const std = @import("std");

pub const main = @import("main.zig");

test {
    std.testing.refAllDecls(@This());
}
