const std = @import("std");
const vigil = @import("vigil.zig");
const Allocator = std.mem.Allocator;

// Global logger for demonstration
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const logger = std.log.scoped(.main);

// Log collector process
fn logCollector() void {
    while (true) {
        std.debug.print("[Collector] Collecting logs from system...\n", .{});
        std.time.sleep(2 * std.time.ns_per_s);
    }
}

// Log parser process
fn logParser() void {
    while (true) {
        std.debug.print("[Parser] Parsing and structuring log data...\n", .{});
        std.time.sleep(3 * std.time.ns_per_s);
    }
}

// Metrics analyzer process
fn metricsAnalyzer() void {
    while (true) {
        std.debug.print("[Analyzer] Analyzing metrics and patterns...\n", .{});
        std.time.sleep(5 * std.time.ns_per_s);
    }
}

// Alert manager process
fn alertManager() void {
    while (true) {
        std.debug.print("[Alert] Checking for alert conditions...\n", .{});
        std.time.sleep(4 * std.time.ns_per_s);
    }
}

pub fn main() !void {
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Create supervisor with one_for_all strategy
    const options = vigil.SupervisorOptions{
        .stategy = .one_for_all, // If one fails, restart all (they're interdependent)
        .max_restarts = 5,
        .max_seconds = 60,
    };

    var supervisor = vigil.Supervisor.init(allocator, options);
    defer supervisor.deinit();

    // Add child processes
    try supervisor.addChild(.{
        .id = "log_collector",
        .start_fn = &logCollector,
        .restart_type = .permanent,
        .shutdown_timeout_ms = 1000,
    });

    try supervisor.addChild(.{
        .id = "log_parser",
        .start_fn = &logParser,
        .restart_type = .permanent,
        .shutdown_timeout_ms = 1000,
    });

    try supervisor.addChild(.{
        .id = "metrics_analyzer",
        .start_fn = &metricsAnalyzer,
        .restart_type = .permanent,
        .shutdown_timeout_ms = 1000,
    });

    try supervisor.addChild(.{
        .id = "alert_manager",
        .start_fn = &alertManager,
        .restart_type = .permanent,
        .shutdown_timeout_ms = 1000,
    });

    // Start the supervisor and all child processes
    try supervisor.start();
    std.debug.print("Log monitoring system started...\n", .{});

    // Keep the main thread alive
    while (true) {
        std.time.sleep(1 * std.time.ns_per_s);
    }
}
