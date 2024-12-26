const std = @import("std");
const vigil = @import("vigil.zig");
const Allocator = std.mem.Allocator;

// Global state
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const logger = std.log.scoped(.main);

pub fn main() !void {
    const allocator = gpa.allocator();
    defer {
        const check = gpa.deinit();
        if (check == .leak) {
            @panic("Memory leak detected!");
        }
    }

    // Create supervisor with options
    const options = vigil.SupervisorOptions{
        .stategy = .one_for_all,
        .max_restarts = 5,
        .max_seconds = 60,
    };

    var supervisor = vigil.Supervisor.init(allocator, options);
    defer supervisor.deinit();

    // Add worker processes
    try supervisor.addChild(.{
        .id = "log_collector",
        .start_fn = logCollector,
        .restart_type = .permanent,
        .shutdown_timeout_ms = 1000,
    });

    // Start supervision
    try supervisor.start();
    logger.info("System started", .{});

    // Keep main thread alive
    while (true) {
        std.time.sleep(1 * std.time.ns_per_s);
    }
}

fn logCollector() void {
    while (true) {
        logger.info("Collecting logs...", .{});
        std.time.sleep(2 * std.time.ns_per_s);
    }
}
