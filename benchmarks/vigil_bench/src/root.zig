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
        .allocations = 4,
        .bytes_allocated = 128,
    };

    try std.testing.expectEqualStrings("sample", result.name);
    try std.testing.expectEqual(@as(usize, 10), result.operations);
    try std.testing.expectEqual(@as(u64, 2_000_000_000), result.elapsed_ns);
    try std.testing.expectEqual(@as(f64, 5), result.opsPerSecond());
    try std.testing.expectEqual(@as(u64, 200_000_000), result.averageLatencyNs());
    try std.testing.expectEqual(@as(f64, 0.4), result.allocationsPerOperation());
}

test "CountingAllocator records allocation activity" {
    var counter = bench.CountingAllocator.init(std.testing.allocator);
    const allocator = counter.allocator();

    const bytes = try allocator.alloc(u8, 16);
    allocator.free(bytes);

    try std.testing.expectEqual(@as(usize, 1), counter.allocationCount());
    try std.testing.expectEqual(@as(usize, 1), counter.freeCount());
    try std.testing.expectEqual(@as(usize, 16), counter.bytesAllocated());
    try std.testing.expectEqual(@as(usize, 16), counter.bytesFreed());
}

test "v2.1 benchmark harness exposes all measurement rows" {
    try std.testing.expect(@hasDecl(bench, "benchInbox"));
    try std.testing.expect(@hasDecl(bench, "benchRegistryLookup"));
    try std.testing.expect(@hasDecl(bench, "benchRegistryRegister"));
    try std.testing.expect(@hasDecl(bench, "benchTelemetry"));
    try std.testing.expect(@hasDecl(bench, "benchTimerScheduling"));
    try std.testing.expect(@hasDecl(bench, "benchProcessGroupRoute"));
    try std.testing.expect(@hasDecl(bench, "benchProcessGroupBroadcast"));
    try std.testing.expect(@hasDecl(bench, "benchPubSub"));
    try std.testing.expect(@hasDecl(bench, "benchReplyCorrelation"));
    try std.testing.expect(@hasDecl(bench, "benchInboxContention"));
}

test "v2.1 benchmark rows run at smoke scale" {
    const allocator = std.testing.allocator;
    const iterations = 8;

    const rows = .{
        try bench.benchInbox(allocator, iterations),
        try bench.benchRegistryLookup(allocator, iterations),
        try bench.benchRegistryRegister(allocator, iterations),
        try bench.benchTelemetry(allocator, iterations),
        try bench.benchTimerScheduling(allocator, iterations),
        try bench.benchProcessGroupRoute(allocator, iterations),
        try bench.benchProcessGroupBroadcast(allocator, iterations),
        try bench.benchPubSub(allocator, iterations),
        try bench.benchReplyCorrelation(allocator, iterations),
        try bench.benchInboxContention(std.heap.smp_allocator, iterations),
    };

    inline for (rows) |row| {
        try std.testing.expect(row.name.len > 0);
        try std.testing.expect(row.operations > 0);
    }
}
