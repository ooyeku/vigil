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
    const BACKGROUND_WORKERS = 40;
    /// Number of business logic workers
    const BUSINESS_WORKERS = 200;
    /// Demo duration in seconds
    const DEMO_DURATION_SECS = 10;
    /// Status update interval in milliseconds
    const STATUS_UPDATE_MS = 50;
    /// Worker sleep duration in milliseconds
    const WORKER_SLEEP_MS = 10;

    /// Message passing configuration
    const MAX_MAILBOX_CAPACITY = 1000;
    const MESSAGE_TTL_MS = 5000;
    const BROADCAST_INTERVAL_MS = 50;

    /// Health check thresholds
    const MEMORY_WARNING_THRESHOLD_MB = 10;
    const MEMORY_CRITICAL_THRESHOLD_MB = 100;
    const HEALTH_CHECK_INTERVAL_MS = 10;

    /// Dynamic scaling
    const MIN_WORKERS = 20;
    const MAX_WORKERS = 100;
    const SCALE_CHECK_INTERVAL_MS = 50;
    const LOAD_THRESHOLD_HIGH = 0.8;
    const LOAD_THRESHOLD_LOW = 0.2;
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

const SystemMetrics = struct {
    cpu_usage: f32 = 0.0,
    memory_usage_mb: usize = 0,
    message_queue_length: usize = 0,
    worker_load: f32 = 0.0,

    mutex: std.Thread.Mutex = .{},

    pub fn update(self: *SystemMetrics, cpu: f32, mem: usize, queue: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.cpu_usage = cpu;
        self.memory_usage_mb = mem;
        self.message_queue_length = queue;
        self.worker_load = @as(f32, queue) / @as(f32, Config.MAX_MAILBOX_CAPACITY);
    }

    pub fn shouldScale(self: *SystemMetrics) enum { Up, Down, None } {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.worker_load > Config.LOAD_THRESHOLD_HIGH) return .Up;
        if (self.worker_load < Config.LOAD_THRESHOLD_LOW) return .Down;
        return .None;
    }
};

var system_metrics = SystemMetrics{};

fn generateWorkerNames(allocator: Allocator, prefix: []const u8, count: usize) ![][]const u8 {
    var names = try allocator.alloc([]const u8, count);
    errdefer {
        for (names) |name| {
            allocator.free(name);
        }
        allocator.free(names);
    }

    for (0..count) |i| {
        names[i] = try std.fmt.allocPrint(allocator, "{s}_{d}", .{ prefix, i + 1 });
    }

    return names;
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

    // Generate worker names dynamically
    const worker_names = try generateWorkerNames(allocator, "background_worker", Config.BACKGROUND_WORKERS);
    defer {
        for (worker_names) |name| {
            allocator.free(name);
        }
        allocator.free(worker_names);
    }

    // Add worker group for background processing
    try vigil.addWorkerGroup(&worker_sup, .{
        .size = Config.BACKGROUND_WORKERS,
        .worker_names = worker_names,
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

    // Initialize message passing demonstration
    const messages = [_]struct { id: []const u8, payload: []const u8, priority: MessagePriority }{
        .{ .id = "status_update", .payload = "System running normally", .priority = .normal },
        .{ .id = "alert", .payload = "High CPU usage detected", .priority = .high },
        .{ .id = "metrics", .payload = "Memory: 85%, CPU: 92%", .priority = .critical },
        .{ .id = "log", .payload = "Background tasks completed", .priority = .low },
    };

    // Send messages with different priorities
    for (messages) |msg| {
        const message = try Message.init(
            allocator,
            msg.id,
            "system_monitor",
            msg.payload,
            .info,
            msg.priority,
            Config.MESSAGE_TTL_MS,
        );

        if (system_mailbox) |*mailbox| {
            if (mailbox.hasCapacity(msg.payload.len)) {
                try mailbox.send(message);
                std.debug.print("{s}Message sent: [{s}] {s}{s}\n", .{
                    if (msg.priority == .critical) "\x1b[31m" else if (msg.priority == .high) "\x1b[33m" else "\x1b[32m",
                    msg.id,
                    msg.payload,
                    "\x1b[0m",
                });
            }
        }

        // Small delay between messages
        std.time.sleep(50 * std.time.ns_per_ms);
    }

    // Process received messages
    if (system_mailbox) |*mailbox| {
        while (mailbox.messages.items.len > 0) {
            const msg = try mailbox.receive();
            std.debug.print("Processing message: [{s}] {?s}\n", .{ msg.id, msg.payload });

            // Simulate message handling
            switch (msg.priority) {
                .critical => {
                    // Send immediate response
                    const response = try vigil.createResponse(&msg, "Acknowledged critical situation", .alert, allocator);
                    try mailbox.send(response);
                    std.debug.print("Sent critical response\n", .{});
                },
                .high => std.debug.print("High priority message handled\n", .{}),
                .normal => std.debug.print("Normal message processed\n", .{}),
                .low => std.debug.print("Background message queued\n", .{}),
                .batch => std.debug.print("Batch message queued for processing\n", .{}),
            }
        }
    }

    // View the message in the mailbox
    if (system_mailbox) |*mailbox| {
        if (mailbox.messages.items.len > 0) {
            std.debug.print("Message in mailbox: {?s}\n", .{mailbox.messages.items[0].payload});
        } else {
            std.debug.print("No messages in mailbox\n", .{});
        }
    }

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

    // View the message in the mailbox only if there are messages
    if (system_mailbox) |*mailbox| {
        if (mailbox.messages.items.len > 0) {
            const payload = mailbox.messages.items[0].payload orelse "No payload";
            std.debug.print("Message received: {s}\n", .{payload});
        } else {
            std.debug.print("No messages in mailbox\n", .{});
        }
    }
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

fn metricsCollectorWorker(sup_tree: *SupervisorTree) void {
    std.debug.print("\nMetrics collector started\n", .{});
    worker_state.incrementActiveProcesses();

    while (worker_state.shouldRun()) {
        // Collect system metrics
        const memory_mb = worker_state.memory_usage / (1024 * 1024);
        const queue_length = if (system_mailbox) |mb| mb.getStats().message_count else 0;

        // Update metrics
        system_metrics.update(0.7, // Simulated CPU usage
            memory_mb, queue_length);

        // Check scaling needs
        switch (system_metrics.shouldScale()) {
            .Up => scaleWorkers(.up, sup_tree) catch {},
            .Down => scaleWorkers(.down, sup_tree) catch {},
            .None => {},
        }

        std.time.sleep(Config.SCALE_CHECK_INTERVAL_MS * std.time.ns_per_ms);
    }

    worker_state.decrementActiveProcesses();
    std.debug.print("Metrics collector shutting down\n", .{});
}

fn scaleWorkers(direction: enum { up, down }, sup_tree: *SupervisorTree) !void {
    const allocator = std.heap.page_allocator;

    switch (direction) {
        .up => {
            if (worker_state.active_processes < Config.MAX_WORKERS) {
                // Add a new business logic worker
                try sup_tree.main.supervisor.addChild(.{
                    .id = std.fmt.allocPrint(allocator, "business_worker_{d}", .{worker_state.active_processes + 1}) catch "worker",
                    .start_fn = businessLogicWorker,
                    .restart_type = .permanent,
                    .shutdown_timeout_ms = 2000,
                    .priority = .high,
                    .max_memory_bytes = 50 * 1024 * 1024,
                    .health_check_interval_ms = 1000,
                });
                try sup_tree.main.supervisor.start();
            }
        },
        .down => {
            if (worker_state.active_processes > Config.MIN_WORKERS) {
                // Find and remove the last added worker
                if (sup_tree.main.supervisor.findChild("business_worker_" ++
                    std.fmt.allocPrint(allocator, "{d}", .{worker_state.active_processes}) catch "worker")) |worker|
                {
                    try sup_tree.main.supervisor.removeChild(worker.spec.id);
                }
            }
        },
    }
}
