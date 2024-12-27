const std = @import("std");
const vigil = @import("vigil");
const Allocator = std.mem.Allocator;

// Example of a worker that can fail
const WorkerError = error{
    TaskFailed,
    ResourceUnavailable,
};

pub fn main() !void {
    // Setup allocator with leak detection
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) @panic("Memory leak detected!");
    }
    const allocator = gpa.allocator();

    // Create supervisor with different restart strategies
    const options = vigil.SupervisorOptions{
        .stategy = .one_for_all, // If one fails, restart all
        .max_restarts = 3, // Maximum number of restarts in max_seconds
        .max_seconds = 5, // Time window for max_restarts
    };

    var supervisor = vigil.Supervisor.init(allocator, options);
    defer supervisor.deinit();

    // Add different types of workers
    try supervisor.addChild(.{
        .id = "critical_worker",
        .start_fn = criticalWorker,
        .restart_type = .permanent, // Always restart
        .shutdown_timeout_ms = 1000,
    });

    try supervisor.addChild(.{
        .id = "temporary_worker",
        .start_fn = temporaryWorker,
        .restart_type = .temporary, // Don't restart if it exits normally
        .shutdown_timeout_ms = 500,
    });

    try supervisor.addChild(.{
        .id = "transient_worker",
        .start_fn = transientWorker,
        .restart_type = .transient, // Only restart if it fails
        .shutdown_timeout_ms = 1000,
    });

    // Start supervision tree
    try supervisor.start();
    std.debug.print("\n=== Vigil Process Supervision Demo ===\n\n", .{});
    std.debug.print("Started supervisor with {d} workers\n", .{supervisor.children.items.len});

    // Demonstrate process monitoring and messaging
    var timer = try std.time.Timer.start();
    const demo_duration_ns = 30 * std.time.ns_per_s; // Run for 30 seconds

    while (timer.read() < demo_duration_ns) {
        // Print system status every second
        std.debug.print("\nSystem status at {d}s:\n", .{timer.read() / std.time.ns_per_s});
        for (supervisor.children.items) |child| {
            std.debug.print("- {s}: {s}\n", .{
                child.spec.id,
                @tagName(child.state),
            });
        }

        std.time.sleep(1 * std.time.ns_per_s);

        // Simulate random process failures after 10 seconds
        if (timer.read() > 10 * std.time.ns_per_s and std.crypto.random.boolean()) {
            const random_index = std.crypto.random.intRangeAtMost(usize, 0, supervisor.children.items.len - 1);
            const random_worker = &supervisor.children.items[random_index];
            std.debug.print("\n!!! Simulating failure in {s} !!!\n", .{random_worker.spec.id});

            // Set the worker's state to failed, which will trigger the supervisor's restart mechanism
            random_worker.mutex.lock();
            random_worker.state = .failed;
            random_worker.mutex.unlock();
        }
    }

    // Graceful shutdown
    std.debug.print("\n=== Starting graceful shutdown ===\n", .{});
    supervisor.stopChildren();

    // Wait for all processes to stop
    var shutdown_timer = try std.time.Timer.start();
    while (supervisor.children.items.len > 0 and shutdown_timer.read() < 5 * std.time.ns_per_s) {
        std.time.sleep(100 * std.time.ns_per_ms);
    }
    std.debug.print("=== Demo completed ===\n", .{});
}

// A critical worker that should always be running
fn criticalWorker() void {
    var uptime: usize = 0;
    while (true) {
        uptime += 1;
        std.debug.print("Critical worker: Uptime {d}s\n", .{uptime});
        std.time.sleep(1 * std.time.ns_per_s);

        // Simulate random failures
        if (std.crypto.random.intRangeAtMost(u8, 0, 100) < 5) {
            std.debug.print("Critical worker: Task failed!\n", .{});
            return; // Return instead of error to trigger restart
        }
    }
}

// A temporary worker that exits after completing its task
fn temporaryWorker() void {
    const work_duration = std.crypto.random.intRangeAtMost(u8, 3, 8);
    std.debug.print("Temporary worker: Starting {d}s task\n", .{work_duration});

    var i: usize = 0;
    while (i < work_duration) : (i += 1) {
        // Calculate percentage safely using usize for all operations
        const percentage = @as(usize, i) * 100 / @as(usize, work_duration);
        std.debug.print("Temporary worker: Processing... {d}%\n", .{percentage});
        std.time.sleep(1 * std.time.ns_per_s);
    }
    std.debug.print("Temporary worker: Task completed\n", .{});
}

// A transient worker that should be restarted only if it fails
fn transientWorker() void {
    var task_count: usize = 0;
    while (task_count < 5) : (task_count += 1) {
        std.debug.print("Transient worker: Starting task {d}/5\n", .{task_count + 1});

        // Simulate work with potential failures
        if (std.crypto.random.intRangeAtMost(u8, 0, 100) < 20) {
            std.debug.print("Transient worker: Resource unavailable!\n", .{});
            return; // Return instead of error to trigger restart
        }

        std.time.sleep(2 * std.time.ns_per_s);
    }
    std.debug.print("Transient worker: All tasks completed successfully\n", .{});
}
