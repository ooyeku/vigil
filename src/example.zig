const std = @import("std");
const vigil = @import("vigil");
const Allocator = std.mem.Allocator;
const ProcessState = vigil.ProcessState;

/// Example worker errors that might occur during operation
const WorkerError = error{
    TaskFailed,
    ResourceUnavailable,
};

pub fn main() !void {
    // Setup allocator with leak detection for development
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) @panic("Memory leak detected!");
    }
    const allocator = gpa.allocator();

    // Create supervisor with one_for_all strategy
    // This ensures all workers are restarted if any fails
    const options = vigil.SupervisorOptions{
        .strategy = .one_for_all,
        // Intentionally set low restart limits to demonstrate the TooManyRestarts error.
        // In production, you might want higher limits like:
        // max_restarts = 10, max_seconds = 60
        .max_restarts = 5, // Allow up to 5 restarts
        .max_seconds = 10, // Within a 10 second window
    };

    var supervisor = vigil.Supervisor.init(allocator, options);
    defer supervisor.deinit(); // Ensure cleanup on exit

    // Add different types of workers to demonstrate restart types

    // Critical worker that should always be running
    try supervisor.addChild(.{
        .id = "critical_worker",
        .start_fn = criticalWorker,
        .restart_type = .permanent, // Always restart on failure
        .shutdown_timeout_ms = 1000,
    });

    // Temporary worker that exits after completing its task
    try supervisor.addChild(.{
        .id = "temporary_worker",
        .start_fn = temporaryWorker,
        .restart_type = .temporary, // Don't restart after completion
        .shutdown_timeout_ms = 500,
    });

    // Transient worker that should only be restarted on failure
    try supervisor.addChild(.{
        .id = "transient_worker",
        .start_fn = transientWorker,
        .restart_type = .transient, // Restart only on failure
        .shutdown_timeout_ms = 1000,
    });

    // Start supervision tree and monitoring
    try supervisor.start();
    try supervisor.startMonitoring();

    // Print initial status
    std.debug.print("\n=== Vigil Process Supervision Demo ===\n\n", .{});
    std.debug.print("Started supervisor with {d} workers\n", .{supervisor.children.items.len});
    std.debug.print("\nNote: This demo intentionally uses low restart limits\n", .{});
    std.debug.print("({d} restarts in {d}s) to demonstrate the TooManyRestarts error.\n", .{
        options.max_restarts,
        options.max_seconds,
    });
    std.debug.print("In production, you should use higher limits based on your needs.\n\n", .{});

    // Monitor system for 30 seconds
    var timer = try std.time.Timer.start();
    const demo_duration_ns = 30 * std.time.ns_per_s;

    while (timer.read() < demo_duration_ns) {
        // Get and display system status every second
        const stats = supervisor.getStats();
        const uptime_s = @divFloor(timer.read(), std.time.ns_per_s);

        std.debug.print("\nSystem status at {d}s:\n", .{uptime_s});
        std.debug.print("Active processes: {d}/{d}\n", .{
            stats.active_children,
            supervisor.children.items.len,
        });
        std.debug.print("Total restarts: {d}\n", .{stats.total_restarts});

        // Show time since last failure if any
        if (stats.last_failure_time > 0) {
            const time_since_failure = std.time.milliTimestamp() - stats.last_failure_time;
            std.debug.print("Time since last failure: {d}ms\n", .{time_since_failure});
        }

        // Display state of each process
        std.debug.print("\nProcess States:\n", .{});
        for (supervisor.children.items) |*child| {
            std.debug.print("- {s:<16} {s}\n", .{
                child.spec.id,
                @tagName(child.getState()),
            });
        }

        // Simulate random failures after 10 seconds of uptime
        if (uptime_s > 10 and std.crypto.random.boolean()) {
            const random_index = std.crypto.random.intRangeAtMost(usize, 0, supervisor.children.items.len - 1);
            const random_worker = &supervisor.children.items[random_index];

            std.debug.print("\n!!! Simulating failure in {s} !!!\n", .{random_worker.spec.id});
            random_worker.mutex.lock();
            random_worker.state = .failed;
            random_worker.mutex.unlock();
        }

        std.time.sleep(1 * std.time.ns_per_s);
    }

    // Demonstrate graceful shutdown
    std.debug.print("\n=== Starting graceful shutdown ===\n", .{});
    try supervisor.shutdown(5000); // Give processes up to 5 seconds to stop
    std.debug.print("=== Demo completed ===\n", .{});
}

/// A critical worker that should always be running
fn criticalWorker() void {
    var uptime: usize = 0;
    while (true) {
        uptime += 1;
        std.debug.print("Critical worker: Uptime {d}s\n", .{uptime});

        // Simulate occasional failures
        if (std.crypto.random.intRangeAtMost(u8, 0, 100) < 5) {
            std.debug.print("Critical worker: Task failed!\n", .{});
            return; // Return to trigger restart
        }

        std.time.sleep(1 * std.time.ns_per_s);
    }
}

/// A temporary worker that exits after completing its task
fn temporaryWorker() void {
    const work_duration = std.crypto.random.intRangeAtMost(u8, 3, 8);
    std.debug.print("Temporary worker: Starting {d}s task\n", .{work_duration});

    var i: usize = 0;
    while (i < work_duration) : (i += 1) {
        const percentage = @as(usize, i) * 100 / @as(usize, work_duration);
        std.debug.print("Temporary worker: Progress {d}%\n", .{percentage});
        std.time.sleep(1 * std.time.ns_per_s);
    }

    std.debug.print("Temporary worker: Task completed successfully\n", .{});
}

/// A transient worker that should be restarted only if it fails
fn transientWorker() void {
    var task_count: usize = 0;
    while (task_count < 5) : (task_count += 1) {
        std.debug.print("Transient worker: Starting task {d}/5\n", .{task_count + 1});

        // Simulate occasional resource failures
        if (std.crypto.random.intRangeAtMost(u8, 0, 100) < 20) {
            std.debug.print("Transient worker: Resource unavailable!\n", .{});
            return; // Return to trigger restart
        }

        std.time.sleep(2 * std.time.ns_per_s);
    }

    std.debug.print("Transient worker: All tasks completed successfully\n", .{});
}
