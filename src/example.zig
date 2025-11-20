const std = @import("std");
const vigil = @import("vigil");

// Simple worker that does some work and exits
fn WorkerTask() void {
    const thread_id = std.Thread.getCurrentId();

    std.debug.print("[Worker {d}] Starting work\n", .{thread_id});

    // Simulate some work
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        std.Thread.sleep(300 * std.time.ns_per_ms);
        std.debug.print("[Worker {d}] Task {d}/5 completed\n", .{ thread_id, i + 1 });
    }

    std.debug.print("[Worker {d}] All tasks completed\n", .{thread_id});
}

// Long-running worker
fn LongRunningWorker() void {
    const thread_id = std.Thread.getCurrentId();
    std.debug.print("[LongRunner {d}] Starting continuous work\n", .{thread_id});

    var count: usize = 0;
    while (count < 10) : (count += 1) {
        std.Thread.sleep(500 * std.time.ns_per_ms);
        std.debug.print("[LongRunner {d}] Heartbeat {d}\n", .{ thread_id, count + 1 });
    }

    std.debug.print("[LongRunner {d}] Shutting down\n", .{thread_id});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Vigil Worker Pool Example ===\n", .{});
    std.debug.print("Demonstrating: Supervision and Worker Pools\n\n", .{});

    // Create supervisor with worker pool
    var app = try vigil.app(allocator);

    std.debug.print("Setting up worker pool with 3 workers...\n", .{});
    _ = try app.workerPool("worker", WorkerTask, 3);

    std.debug.print("Adding long-running workers...\n", .{});
    _ = try app.worker("long_runner_1", LongRunningWorker);
    _ = try app.worker("long_runner_2", LongRunningWorker);

    std.debug.print("Starting all workers...\n\n", .{});
    try app.start();

    // Let workers run for a while
    std.Thread.sleep(6000 * std.time.ns_per_ms);

    std.debug.print("\n=== Shutting down ===\n", .{});
    app.shutdown();

    std.debug.print("Done.\n", .{});
}
