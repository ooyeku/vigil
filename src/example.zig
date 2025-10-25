const std = @import("std");
const vigil = @import("vigil");

// Simple worker function
fn simpleWorker() void {
    std.debug.print("Worker running\n", .{});
    std.Thread.sleep(100 * std.time.ns_per_ms);
}

// Another worker function
fn backgroundWorker() void {
    std.debug.print("Background worker running\n", .{});
    std.Thread.sleep(200 * std.time.ns_per_ms);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const gpa_allocator = gpa.allocator();

    // Use ArenaAllocator for cleaner memory management in examples
    var arena = std.heap.ArenaAllocator.init(gpa_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    std.debug.print("=== Vigil 0.3.0 High-Level API Example ===\n\n", .{});

    // Example 1: Simple message building
    std.debug.print("1. Message Builder Example:\n", .{});
    var msg = try vigil.msg("Hello from Vigil")
        .from("main")
        .priority(.high)
        .ttl(5000)
        .build(allocator);
    defer msg.deinit();
    std.debug.print("   Message created: {s}\n", .{msg.payload.?});
    std.debug.print("   Priority: high, TTL: 5000ms\n\n", .{});

    // Example 2: Inbox for message passing
    std.debug.print("2. Inbox Example:\n", .{});
    var inbox = try vigil.inbox(allocator);
    defer inbox.close();

    try inbox.send("Message 1");
    try inbox.send("Message 2");

    if (inbox.recvTimeout(1000)) |msg_opt| {
        if (msg_opt) |received_msg_const| {
            var received_msg = received_msg_const;
            std.debug.print("   Received: {?s}\n", .{received_msg.payload});
            received_msg.deinit();
        }
    } else |_| {}
    std.debug.print("\n", .{});

    // Example 3: Simple supervisor with workers
    std.debug.print("3. Supervisor Builder Example:\n", .{});
    var sup_builder = vigil.supervisor(allocator);
    _ = try sup_builder.child("worker1", simpleWorker);
    _ = try sup_builder.child("worker2", backgroundWorker);
    _ = sup_builder.build();

    std.debug.print("   Supervisor configured with 2 workers\n", .{});
    std.debug.print("   Strategy: one_for_one (default)\n\n", .{});

    // Example 4: Simple app builder
    std.debug.print("4. Application Builder Example:\n", .{});
    var app_builder = try vigil.app(allocator);
    _ = try app_builder.worker("task1", simpleWorker);
    _ = try app_builder.worker("task2", backgroundWorker);
    try app_builder.build();

    std.debug.print("   App built with 2 workers using production preset\n", .{});
    std.debug.print("   Preset: production\n", .{});
    std.debug.print("   Max restarts: 3, Max seconds: 60\n\n", .{});

    // Example 5: Presets demonstration
    std.debug.print("5. Preset Configurations:\n", .{});
    const dev_preset = vigil.PresetConfig.get(.development);
    std.debug.print("   Development: max_restarts={d}, health_check_interval={d}ms\n", .{
        dev_preset.max_restarts,
        dev_preset.health_check_interval_ms,
    });

    const prod_preset = vigil.PresetConfig.get(.production);
    std.debug.print("   Production: max_restarts={d}, health_check_interval={d}ms\n\n", .{
        prod_preset.max_restarts,
        prod_preset.health_check_interval_ms,
    });

    // Example 6: Version info
    std.debug.print("6. Library Version:\n", .{});
    const version = vigil.getVersion();
    std.debug.print("   Vigil v{d}.{d}.{d}\n\n", .{ version.major, version.minor, version.patch });

    std.debug.print("=== All examples completed successfully ===\n", .{});
}
