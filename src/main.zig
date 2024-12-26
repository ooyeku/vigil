const std = @import("std");
const vigil = @import("vigil.zig");
const Allocator = std.mem.Allocator;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) @panic("Memory leak detected!");
    }

    const allocator = gpa.allocator();

    // Create supervisor with options
    const options = vigil.SupervisorOptions{
        .stategy = .one_for_all,
        .max_restarts = 3,
        .max_seconds = 5,
    };

    var supervisor = vigil.Supervisor.init(allocator, options);
    defer supervisor.deinit();

    // Add a single worker process
    try supervisor.addChild(.{
        .id = "worker",
        .start_fn = workerProcess,
        .restart_type = .permanent,
        .shutdown_timeout_ms = 1000,
    });

    // Start supervision
    try supervisor.start();
    std.debug.print("System started\n", .{});

    // Keep main thread alive
    var i: usize = 0;
    while (i < 10) {
        std.time.sleep(1 * std.time.ns_per_s);
        std.debug.print("Main thread running...\n", .{});
        if (supervisor.children.items.len == 0) {
            break;
        }
        std.debug.print("Waiting for children to stop...\n", .{});
        std.time.sleep(1 * std.time.ns_per_s);

        supervisor.stopChildren();
        i += 1;
    }
}

fn workerProcess() void {
    while (true) {
        std.time.sleep(1 * std.time.ns_per_s);
        std.debug.print("Worker process running...\n", .{});
    }
}
