const std = @import("std");
const bench = @import("main.zig");

test {
    std.testing.refAllDecls(@This());
}

pub const main = bench;

test "throughputPerSecond scales operations by elapsed time" {
    try std.testing.expectEqual(
        @as(f64, 2_000_000),
        bench.throughputPerSecond(1_000, 500_000),
    );
}

test "BenchmarkResult captures benchmark identity and operation count" {
    const result = bench.BenchmarkResult{
        .name = "sample",
        .operations = 10,
        .elapsed_ns = 2_000_000_000,
    };

    try std.testing.expectEqualStrings("sample", result.name);
    try std.testing.expectEqual(@as(usize, 10), result.operations);
    try std.testing.expectEqual(@as(u64, 2_000_000_000), result.elapsed_ns);
    try std.testing.expectEqual(@as(f64, 5), result.opsPerSecond());
}
