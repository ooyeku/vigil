const std = @import("std");
const vigil = @import("vigil");

// Worker that processes messages from an inbox
fn MessageWorker() void {
    const thread_id = std.Thread.getCurrentId();
    std.debug.print("[MessageWorker {d}] Starting\n", .{thread_id});

    var count: usize = 0;
    while (count < 5) : (count += 1) {
        std.Thread.sleep(200 * std.time.ns_per_ms);
        std.debug.print("[MessageWorker {d}] Processing batch {d}/5\n", .{ thread_id, count + 1 });
    }

    std.debug.print("[MessageWorker {d}] Finished\n", .{thread_id});
}

// Long-running worker with heartbeat
fn HeartbeatWorker() void {
    const thread_id = std.Thread.getCurrentId();
    std.debug.print("[Heartbeat {d}] Starting continuous monitoring\n", .{thread_id});

    var heartbeat: usize = 0;
    while (heartbeat < 8) : (heartbeat += 1) {
        std.Thread.sleep(300 * std.time.ns_per_ms);
        std.debug.print("[Heartbeat {d}] Pulse {d}\n", .{ thread_id, heartbeat + 1 });
    }

    std.debug.print("[Heartbeat {d}] Monitoring complete\n", .{thread_id});
}

pub fn main() !void {
    // Use arena allocator to avoid individual cleanup
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    std.debug.print("\n=== Vigil v1.0.0 Example ===\n", .{});
    std.debug.print("Demonstrating: Supervision, Messaging, Circuit Breaker, Telemetry\n\n", .{});

    // Create circuit breaker for resilience
    var breaker = try vigil.CircuitBreaker.init(allocator, "main_circuit", .{
        .failure_threshold = 3,
        .reset_timeout_ms = 1000,
    });
    defer breaker.deinit();

    std.debug.print("Circuit breaker state: {s}\n", .{@tagName(breaker.getState())});

    // Create process group for worker management
    var worker_group = try vigil.ProcessGroup.init(allocator, "workers");
    defer worker_group.deinit();

    // Create inboxes for workers
    var inbox1 = try vigil.inbox(allocator);
    defer inbox1.close();

    var inbox2 = try vigil.inbox(allocator);
    defer inbox2.close();

    try worker_group.add("worker_1", inbox1);
    try worker_group.add("worker_2", inbox2);

    std.debug.print("Process group '{s}' created with {d} members\n\n", .{
        "workers",
        worker_group.count(),
    });

    // Create supervisor with worker pool
    var app = try vigil.app(allocator);

    std.debug.print("Setting up worker pool with 2 message workers...\n", .{});
    _ = try app.workerPool("msg_worker", MessageWorker, 2);

    std.debug.print("Adding heartbeat workers...\n", .{});
    _ = try app.worker("heartbeat_1", HeartbeatWorker);

    std.debug.print("Starting all workers...\n\n", .{});
    try app.start();

    // Demonstrate rate limiter
    var rate_limiter = vigil.RateLimiter.init(10); // 10 ops/sec
    var allowed: u32 = 0;
    for (0..15) |_| {
        if (rate_limiter.allow()) {
            allowed += 1;
        }
    }
    std.debug.print("Rate limiter: {d}/15 operations allowed\n\n", .{allowed});

    // Let workers run
    std.Thread.sleep(3000 * std.time.ns_per_ms);

    std.debug.print("\n=== Initiating Graceful Shutdown ===\n", .{});

    app.shutdown();

    std.debug.print("\n=== Example Complete ===\n", .{});
}
