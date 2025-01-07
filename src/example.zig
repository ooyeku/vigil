const std = @import("std");
const vigil = @import("vigil");
const Allocator = std.mem.Allocator;
const ProcessState = vigil.ProcessState; 
const Message = vigil.Message;
const ProcessMailbox = vigil.ProcessMailbox;
const MessagePriority = vigil.MessagePriority;
const Signal = vigil.Signal;
const SupervisorTree = vigil.SupervisorTree;
const TreeConfig = vigil.TreeConfig;
const WorkerGroupConfig = vigil.WorkerGroupConfig;
const Supervisor = vigil.Supervisor;

/// Configuration constants for the demo
const Config = struct {
    /// Number of iterations to run the demo
    const DEMO_ITERATIONS = 100;
    /// Sleep duration between iterations in milliseconds
    const SLEEP_DURATION_MS = 1;

    /// Number of background workers to create
    const BACKGROUND_WORKERS = 3;
    /// Number of business logic workers
    const BUSINESS_WORKERS = 20;
    /// Demo duration in seconds
    const DEMO_DURATION_SECS = 10;
    /// Status update interval in milliseconds
    const STATUS_UPDATE_MS = 50000;
    /// Worker sleep duration in milliseconds
    const WORKER_SLEEP_MS = 10;
};

/// Example worker errors that might occur during operation
const WorkerError = error{
    TaskFailed,
    ResourceUnavailable,
    HealthCheckFailed,
    MemoryLimitExceeded,
};

/// Shared state for worker processes
const WorkerState = struct {
    should_run: bool = true,
    memory_usage: usize = 0,
    peak_memory_bytes: usize = 0,
    is_healthy: bool = true,
    total_process_count: usize = 0,
    active_processes: usize = 0,
    total_restarts: usize = 0,
    mutex: std.Thread.Mutex = .{},

    fn shouldRun(self: *WorkerState) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.should_run and self.total_process_count < 1000;
    }

    fn incrementProcessCount(self: *WorkerState) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.total_process_count += 1;
    }

    fn allocateMemory(self: *WorkerState, bytes: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.memory_usage += bytes;
        self.peak_memory_bytes = @max(self.peak_memory_bytes, self.memory_usage);
    }

    fn freeMemory(self: *WorkerState, bytes: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (bytes <= self.memory_usage) {
            self.memory_usage -= bytes;
        } else {
            self.memory_usage = 0;
        }
    }

    fn isHealthy(self: *WorkerState) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.is_healthy;
    }

    fn setHealth(self: *WorkerState, healthy: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.is_healthy = healthy;
    }

    fn incrementActiveProcesses(self: *WorkerState) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.active_processes += 1;
    }

    fn decrementActiveProcesses(self: *WorkerState) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.active_processes > 0) {
            self.active_processes -= 1;
        }
    }

    fn incrementRestarts(self: *WorkerState) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.total_restarts += 1;
    }
};

var worker_state = WorkerState{};

// Add mailbox for inter-process communication
var system_mailbox: ?ProcessMailbox = null;

fn initSystemMailbox(allocator: Allocator) !void {
    system_mailbox = ProcessMailbox.init(allocator, .{
        .capacity = 100,
        .max_message_size = 1024 * 1024, // 1MB
        .default_ttl_ms = 5000, // 5 seconds
        .priority_queues = true,
        .enable_deadletter = true,
    });
}

fn deinitSystemMailbox() void {
    if (system_mailbox) |*mailbox| {
        mailbox.deinit();
    }
}

pub fn main() !void {
    // Setup allocator with leak detection for development
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) @panic("Memory leak detected!");
    }
    const allocator = gpa.allocator();

    // Initialize system mailbox with enhanced configuration
    system_mailbox = ProcessMailbox.init(allocator, .{
        .capacity = 100,
        .max_message_size = 1024 * 1024, // 1MB
        .default_ttl_ms = 5000, // 5 seconds
        .priority_queues = true,
        .enable_deadletter = true, // Enable dead letter queue for undeliverable messages
    });
    defer deinitSystemMailbox();

    // Create root supervisor with one_for_all strategy
    const root_options = vigil.SupervisorOptions{
        .strategy = .one_for_all,
        .max_restarts = 5,
        .max_seconds = 10,
    };

    // Initialize supervision tree with monitoring
    var tree = try SupervisorTree.init(allocator, Supervisor.init(allocator, root_options), "root", .{
        .max_depth = 3,
        .enable_monitoring = false,
        .shutdown_timeout_ms = 10_000,
        .propagate_signals = true,
    });
    defer tree.deinit();

    // Create worker supervisor for background tasks
    var worker_sup = Supervisor.init(allocator, .{
        .strategy = .one_for_one,
        .max_restarts = 3,
        .max_seconds = 5,
    });
    defer worker_sup.deinit();

    // Add worker supervisor to tree with name
    try tree.addChild(worker_sup, "worker_sup");

    // Add worker group for background processing
    try vigil.addWorkerGroup(&worker_sup, .{
        .size = Config.BACKGROUND_WORKERS,
        .worker_names = &[_][]const u8{ "background1", "background2", "batch_processor" } ** Config.BACKGROUND_WORKERS,
        .priority = .low,
        .max_memory_mb = 100,
        .health_check_interval_ms = 1000,
        .mailbox_capacity = 100,
        .enable_monitoring = false,
    });

    // Add critical system workers to root supervisor
    try tree.main.supervisor.addChild(.{
        .id = "system_monitor",
        .start_fn = systemMonitorWorker,
        .restart_type = .permanent,
        .shutdown_timeout_ms = 1000,
        .priority = .critical,
        .max_memory_bytes = 10 * 1024 * 1024,
        .health_check_interval_ms = 500,
    });

    // Add high-priority business logic workers
    if (Config.BUSINESS_WORKERS > 0) {
        try tree.main.supervisor.addChild(.{
            .id = "business_logic",
            .start_fn = businessLogicWorker,
            .restart_type = .permanent,
            .shutdown_timeout_ms = 2000,
            .priority = .high,
            .max_memory_bytes = 50 * 1024 * 1024,
            .health_check_fn = checkBusinessHealth,
            .health_check_interval_ms = 1000,
        });
    }

    // Start the entire supervision tree
    try tree.start();

    // ANSI color codes
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const green = "\x1b[32m";
    const yellow = "\x1b[33m";
    const blue = "\x1b[34m";

    std.debug.print("\n{s}╔═══ Vigil Process Supervision Demo ═══╗{s}\n", .{ bold, reset });
    std.debug.print("║ Running demo for {d} iterations...      ║\n", .{10});
    std.debug.print("╚═══════════════════════════════════╝\n\n", .{});

    // Simple loop that runs for a fixed number of iterations
    var iterations: usize = 0;
    const max_iterations = Config.DEMO_ITERATIONS;

    while (iterations < max_iterations) : (iterations += 1) {
        std.debug.print("{s}System Status (Iteration: {d}/{d}){s}\n", .{ bold, iterations + 1, max_iterations, reset });
        std.debug.print("├─ Active processes: {s}{d}/{d}{s}\n", .{
            green,
            worker_state.active_processes,
            Config.BACKGROUND_WORKERS + Config.BUSINESS_WORKERS + 1,
            reset,
        });
        std.debug.print("├─ Total restarts: {s}{d}{s}\n", .{
            if (worker_state.total_restarts > 0) yellow else green,
            worker_state.total_restarts,
            reset,
        });
        std.debug.print("└─ Memory usage: {s}{d} KB{s}\n\n", .{
            if (worker_state.memory_usage > 100 * 1024 * 1024) yellow else green,
            worker_state.memory_usage / 1024,
            reset,
        });

        std.time.sleep(Config.SLEEP_DURATION_MS * std.time.ns_per_ms); // Sleep between updates
    }

    // Demonstrate graceful shutdown
    std.debug.print("\n{s}╔═══ Initiating Graceful Shutdown ═══╗{s}\n", .{ blue, reset });
    std.debug.print("║ Stopping all processes...           ║\n", .{});
    std.debug.print("╚═══════════════════════════════════╝\n", .{});

    worker_state.should_run = false;
    tree.shutdown(1000) catch |err| {
        std.debug.print("Warning: Shutdown error: {}\n", .{err});
    };

    std.debug.print("\n{s}╔═══ Demo Completed Successfully ═══╗{s}\n", .{ green, reset });
    std.debug.print("║ All processes terminated cleanly    ║\n", .{});
    std.debug.print("╚═══════════════════════════════════╝\n", .{});

    // Example of message broadcasting
    const broadcast_msg = try Message.init(
        allocator,
        "broadcast_status",
        "system_monitor",
        "System status update",
        .info,
        .normal,
        5000,
    );

    var recipients = std.ArrayList(*ProcessMailbox).init(allocator);
    defer recipients.deinit();

    // Collect mailboxes for broadcasting
    if (system_mailbox) |*mailbox| {
        try recipients.append(mailbox);
    }

    // Broadcast message to all recipients
    try vigil.broadcast(recipients.items, broadcast_msg, allocator);
}

/// System monitoring worker with critical priority
fn systemMonitorWorker() void {
    std.debug.print("\nSystem monitor started\n", .{});
    worker_state.incrementActiveProcesses();
    var counter: usize = 0;
    const min_processes = (Config.BACKGROUND_WORKERS + Config.BUSINESS_WORKERS + 1) / 2;

    while (worker_state.shouldRun()) {
        counter += 1;
        worker_state.incrementProcessCount();

        // Simulate memory allocation
        const memory_needed = counter * 1024 * 10; // Increase by 10KB each iteration
        worker_state.allocateMemory(memory_needed);

        // Simulate health check failures more frequently (every 3rd iteration)
        if (counter % 3 == 0) {
            worker_state.setHealth(false);
            std.debug.print("System health check failed (count: {d})\n", .{counter});
            if (counter % 9 == 0 and worker_state.active_processes > min_processes) { // Only restart if enough processes are running
                worker_state.incrementRestarts();
                break; // Force restart
            }
        } else {
            worker_state.setHealth(true);
            std.debug.print("System health check passed (count: {d})\n", .{counter});
        }
        std.time.sleep(Config.WORKER_SLEEP_MS * std.time.ns_per_ms);
    }
    worker_state.decrementActiveProcesses();
    std.debug.print("System monitor shutting down\n", .{});
}

/// Business logic worker with high priority
fn businessLogicWorker() void {
    std.debug.print("\nBusiness logic worker started\n", .{});
    worker_state.incrementActiveProcesses();
    var counter: usize = 0;
    const min_processes = (Config.BACKGROUND_WORKERS + Config.BUSINESS_WORKERS + 1) / 2;

    while (worker_state.shouldRun()) {
        counter += 1;
        worker_state.incrementProcessCount();

        // Simulate memory usage
        const memory_needed = counter * 1024 * 20; // Increase by 20KB each iteration
        worker_state.allocateMemory(memory_needed);

        // Simulate more frequent failures (every 4th iteration)
        if (counter % 4 == 0 and worker_state.active_processes > min_processes) { // Only restart if enough processes are running
            std.debug.print("Business logic error occurred (count: {d})\n", .{counter});
            worker_state.incrementRestarts();
            break; // This will cause the process to restart
        }

        std.debug.print("Processing business logic (count: {d})\n", .{counter});
        std.time.sleep(Config.WORKER_SLEEP_MS * std.time.ns_per_ms);
    }
    worker_state.decrementActiveProcesses();
    std.debug.print("Business logic worker shutting down\n", .{});
}

/// Background task worker with low priority
fn backgroundWorker() void {
    std.debug.print("\nBackground worker started\n", .{});
    worker_state.incrementActiveProcesses();
    var counter: usize = 0;
    const min_processes = (Config.BACKGROUND_WORKERS + Config.BUSINESS_WORKERS + 1) / 2;

    while (worker_state.shouldRun()) {
        counter += 1;
        worker_state.incrementProcessCount();

        // Simulate memory usage
        const memory_needed = counter * 1024 * 5; // Increase by 5KB each iteration
        worker_state.allocateMemory(memory_needed);

        // Simulate occasional failures (every 5th iteration)
        if (counter % 5 == 0 and worker_state.active_processes > min_processes) { // Only restart if enough processes are running
            std.debug.print("Background worker error occurred (count: {d})\n", .{counter});
            worker_state.incrementRestarts();
            break; // Force restart
        }

        std.debug.print("Running background tasks (count: {d})\n", .{counter});
        std.time.sleep(Config.WORKER_SLEEP_MS * std.time.ns_per_ms);
    }
    worker_state.decrementActiveProcesses();
    std.debug.print("Background worker shutting down\n", .{});
}

/// Health check functions
fn checkSystemHealth() bool {
    return worker_state.isHealthy();
}

fn checkBusinessHealth() bool {
    return worker_state.isHealthy();
}

fn checkBackgroundHealth() bool {
    return worker_state.isHealthy();
}
