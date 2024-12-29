const std = @import("std");
const vigil = @import("vigil");
const Allocator = std.mem.Allocator;
const ProcessState = vigil.ProcessState;
const ProcessSignal = vigil.ProcessSignal;

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
    is_healthy: bool = true,
    mutex: std.Thread.Mutex = .{},

    fn shouldRun(self: *WorkerState) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.should_run;
    }

    fn allocateMemory(self: *WorkerState, bytes: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.memory_usage = bytes;
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
};

var worker_state = WorkerState{};

pub fn main() !void {
    // Setup allocator with leak detection for development
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) @panic("Memory leak detected!");
    }
    const allocator = gpa.allocator();

    // Create supervisor with one_for_all strategy
    const options = vigil.SupervisorOptions{
        .strategy = .one_for_all,
        .max_restarts = 5,
        .max_seconds = 10,
    };

    var supervisor = vigil.Supervisor.init(allocator, options);
    defer supervisor.deinit();

    // Add workers with different priorities and monitoring configurations

    // Critical system worker with strict resource limits
    try supervisor.addChild(.{
        .id = "system_monitor",
        .start_fn = systemMonitorWorker,
        .restart_type = .permanent,
        .shutdown_timeout_ms = 1000,
        .priority = .critical,
        .max_memory_bytes = 10 * 1024 * 1024, // 10MB limit
        .health_check_fn = checkSystemHealth,
        .health_check_interval_ms = 500,
    });

    // High-priority business logic worker
    try supervisor.addChild(.{
        .id = "business_logic",
        .start_fn = businessLogicWorker,
        .restart_type = .permanent,
        .shutdown_timeout_ms = 2000,
        .priority = .high,
        .max_memory_bytes = 50 * 1024 * 1024, // 50MB limit
        .health_check_fn = checkBusinessHealth,
        .health_check_interval_ms = 1000,
    });

    // Background task worker
    try supervisor.addChild(.{
        .id = "background_tasks",
        .start_fn = backgroundWorker,
        .restart_type = .transient,
        .shutdown_timeout_ms = 5000,
        .priority = .low,
        .max_memory_bytes = 100 * 1024 * 1024, // 100MB limit
        .health_check_fn = checkBackgroundHealth,
        .health_check_interval_ms = 2000,
    });

    // Batch processing worker
    try supervisor.addChild(.{
        .id = "batch_processor",
        .start_fn = batchProcessorWorker,
        .restart_type = .temporary,
        .shutdown_timeout_ms = 10000,
        .priority = .batch,
        .max_memory_bytes = 200 * 1024 * 1024, // 200MB limit
    });

    // Start supervision tree and monitoring
    try supervisor.start();
    try supervisor.startMonitoring();

    // ANSI color codes
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const dim = "\x1b[2m";
    const green = "\x1b[32m";
    const yellow = "\x1b[33m";
    const blue = "\x1b[34m";
    const magenta = "\x1b[35m";
    const cyan = "\x1b[36m";
    const red = "\x1b[31m";

    // Process ID counter for display purposes
    var next_pid: u32 = 1000;
    var process_ids = std.AutoHashMap(*vigil.Process, u32).init(allocator);
    defer process_ids.deinit();

    // Assign PIDs to all processes
    for (supervisor.children.items) |*child| {
        try process_ids.put(child, next_pid);
        next_pid += 1;
    }

    std.debug.print("\n{s}╔═══ Vigil Enhanced Process Supervision Demo ═══╗{s}\n", .{ bold, reset });
    std.debug.print("║ Started supervisor with {s}{d}{s} workers           ║\n", .{ green, supervisor.children.items.len, reset });
    std.debug.print("╚════════════════════════════════════════════════╝\n\n", .{});

    std.debug.print("{s}Demonstrating:{s}\n", .{ bold, reset });
    std.debug.print("• Process priorities and health monitoring\n", .{});
    std.debug.print("• Resource limits and usage tracking\n", .{});
    std.debug.print("• Signal handling and state transitions\n", .{});
    std.debug.print("• Statistics and performance monitoring\n", .{});

    // Monitor system and demonstrate features
    var timer = try std.time.Timer.start();
    const demo_duration_ns = 60 * std.time.ns_per_s;

    while (timer.read() < demo_duration_ns) {
        const stats = supervisor.getStats();
        const uptime_s = @divFloor(timer.read(), std.time.ns_per_s);

        std.debug.print("\n{s}╔══ System Status at {d}s ══╗{s}\n", .{ bold, uptime_s, reset });
        std.debug.print("║ Active processes: {s}{d}/{d}{s}     ║\n", .{
            green,
            stats.active_children,
            supervisor.children.items.len,
            reset,
        });
        std.debug.print("║ Total restarts: {s}{d}{s}          ║\n", .{
            if (stats.total_restarts > 0) yellow else green,
            stats.total_restarts,
            reset,
        });
        std.debug.print("╚═════════════════════════╝\n", .{});

        // Display detailed process information
        std.debug.print("\n{s}Process Details:{s}\n", .{ bold, reset });
        for (supervisor.children.items) |*child| {
            const process_stats = child.getStats();
            const pid = process_ids.get(child) orelse 0;
            const state_color = switch (child.getState()) {
                .running => green,
                .suspended => yellow,
                .failed => red,
                else => dim,
            };
            const priority_color = switch (child.spec.priority) {
                .critical => red,
                .high => magenta,
                .normal => blue,
                .low => cyan,
                .batch => dim,
            };

            std.debug.print("├─ {s}[PID {d}] {s:<16}{s}\n", .{ bold, pid, child.spec.id, reset });
            std.debug.print("│  {s}Status:{s} {s}{s:<10}{s} {s}Priority:{s} {s}{s:<8}{s}\n", .{
                dim,
                reset,
                state_color,
                @tagName(child.getState()),
                reset,
                dim,
                reset,
                priority_color,
                @tagName(child.spec.priority),
                reset,
            });
            std.debug.print("│  {s}Health:{s} {s}{d} failed checks{s}  {s}Memory:{s} {s}{d:>6} KB{s}\n", .{
                dim,
                reset,
                if (process_stats.health_check_failures > 0) yellow else green,
                process_stats.health_check_failures,
                reset,
                dim,
                reset,
                if (process_stats.peak_memory_bytes > 100 * 1024 * 1024) yellow else green,
                process_stats.peak_memory_bytes / 1024,
                reset,
            });
            std.debug.print("│  {s}Uptime:{s} {s}{d:>6} ms{s}\n", .{
                dim,
                reset,
                blue,
                process_stats.total_runtime_ms,
                reset,
            });
        }

        // Demonstrate different scenarios based on uptime
        switch (uptime_s) {
            10 => {
                if (supervisor.findChild("background_tasks")) |worker| {
                    const pid = process_ids.get(worker) orelse 0;
                    std.debug.print("\n{s}╔═══ Event: Memory Pressure ═══╗{s}\n", .{ yellow, reset });
                    std.debug.print("║ Process: [PID {d}] background_tasks\n", .{pid});
                    std.debug.print("║ Action: Increasing memory usage to 150MB\n", .{});
                    std.debug.print("╚════════════════════════════════╝\n", .{});
                    worker_state.allocateMemory(150 * 1024 * 1024);
                    worker.stats.peak_memory_bytes = worker_state.memory_usage;
                }
            },
            20 => {
                if (supervisor.findChild("batch_processor")) |worker| {
                    const pid = process_ids.get(worker) orelse 0;
                    std.debug.print("\n{s}╔═══ Event: Process Suspension ═══╗{s}\n", .{ yellow, reset });
                    std.debug.print("║ Process: [PID {d}] batch_processor\n", .{pid});
                    std.debug.print("║ Action: Suspending process\n", .{});
                    std.debug.print("╚═════════════════════════════════╝\n", .{});
                    try worker.sendSignal(.@"suspend");
                }
            },
            25 => {
                if (supervisor.findChild("batch_processor")) |worker| {
                    const pid = process_ids.get(worker) orelse 0;
                    std.debug.print("\n{s}╔═══ Event: Process Resume ═══╗{s}\n", .{ green, reset });
                    std.debug.print("║ Process: [PID {d}] batch_processor\n", .{pid});
                    std.debug.print("║ Action: Resuming process\n", .{});
                    std.debug.print("╚══════════════════════════════╝\n", .{});
                    try worker.sendSignal(.@"resume");
                }
            },
            30 => {
                std.debug.print("\n{s}╔═══ Event: Health Check Failure ═══╗{s}\n", .{ yellow, reset });
                std.debug.print("║ Action: Simulating system-wide health failure\n", .{});
                std.debug.print("╚═══════════════════════════════════╝\n", .{});
                worker_state.setHealth(false);
            },
            40 => {
                std.debug.print("\n{s}╔═══ Event: Health Restored ═══╗{s}\n", .{ green, reset });
                std.debug.print("║ Action: Restoring system health\n", .{});
                std.debug.print("╚════════════════════════════╝\n", .{});
                worker_state.setHealth(true);
            },
            else => {},
        }

        std.time.sleep(1 * std.time.ns_per_s);
    }

    // Demonstrate graceful shutdown
    std.debug.print("\n{s}╔═══ Initiating Graceful Shutdown ═══╗{s}\n", .{ blue, reset });
    std.debug.print("║ Stopping all processes...           ║\n", .{});
    std.debug.print("╚═══════════════════════════════════╝\n", .{});
    worker_state.should_run = false;
    try supervisor.shutdown(5000);
    std.debug.print("\n{s}╔═══ Demo Completed Successfully ═══╗{s}\n", .{ green, reset });
    std.debug.print("║ All processes terminated cleanly    ║\n", .{});
    std.debug.print("╚═══════════════════════════════════╝\n", .{});
}

/// System monitoring worker with critical priority
fn systemMonitorWorker() void {
    std.debug.print("System monitor started with critical priority\n", .{});
    var memory_usage: usize = 2 * 1024 * 1024; // Start with 2MB
    var iteration: usize = 0;
    var peak_load: bool = false;

    while (worker_state.shouldRun()) {
        iteration += 1;
        // Simulate system monitoring with periodic spikes
        if (iteration % 3 == 0) {
            memory_usage += 1024 * 1024; // Regular increase
        }
        if (iteration % 10 == 0) {
            memory_usage += 5 * 1024 * 1024; // Periodic spike
            peak_load = true;
        }
        if (peak_load and iteration % 2 == 0) {
            memory_usage = @max(2 * 1024 * 1024, memory_usage - 3 * 1024 * 1024); // Gradual decrease
            if (memory_usage <= 2 * 1024 * 1024) {
                peak_load = false;
            }
        }
        worker_state.allocateMemory(memory_usage);
        std.time.sleep(500 * std.time.ns_per_ms);
    }
}

/// Business logic worker with high priority
fn businessLogicWorker() void {
    std.debug.print("Business logic worker started with high priority\n", .{});
    var memory_usage: usize = 8 * 1024 * 1024; // Start with 8MB
    var iteration: usize = 0;
    var processing_batch: bool = false;

    while (worker_state.shouldRun()) {
        iteration += 1;
        // Simulate business processing with batch operations
        if (iteration % 5 == 0) {
            processing_batch = true;
            memory_usage += 15 * 1024 * 1024; // Start batch processing
        }
        if (processing_batch) {
            if (iteration % 2 == 0) {
                memory_usage += 2 * 1024 * 1024; // Gradual increase during batch
            }
            if (iteration % 8 == 0) {
                memory_usage = 8 * 1024 * 1024; // Batch complete, reset
                processing_batch = false;
            }
        } else {
            memory_usage += 512 * 1024; // Normal operation growth
            if (memory_usage > 12 * 1024 * 1024) {
                memory_usage = 8 * 1024 * 1024; // Regular cleanup
            }
        }
        worker_state.allocateMemory(memory_usage);
        std.time.sleep(750 * std.time.ns_per_ms);
    }
}

/// Background task worker with low priority
fn backgroundWorker() void {
    std.debug.print("Background worker started with low priority\n", .{});
    var memory_usage: usize = 15 * 1024 * 1024; // Start with 15MB
    var iteration: usize = 0;
    var gc_needed: bool = false;

    while (worker_state.shouldRun()) {
        iteration += 1;
        // Simulate background processing with GC cycles
        if (!gc_needed) {
            memory_usage += 4 * 1024 * 1024; // Regular growth
            if (iteration % 3 == 0) {
                memory_usage += 8 * 1024 * 1024; // Periodic larger allocation
            }
            if (memory_usage > 150 * 1024 * 1024) {
                gc_needed = true;
            }
        } else {
            // Simulate garbage collection
            memory_usage = @max(15 * 1024 * 1024, memory_usage - 12 * 1024 * 1024);
            if (memory_usage <= 15 * 1024 * 1024) {
                gc_needed = false;
            }
        }
        worker_state.allocateMemory(memory_usage);
        std.time.sleep(1000 * std.time.ns_per_ms);
    }
}

/// Batch processing worker with batch priority
fn batchProcessorWorker() void {
    std.debug.print("Batch processor started with batch priority\n", .{});
    var memory_usage: usize = 25 * 1024 * 1024; // Start with 25MB
    var iteration: usize = 0;

    const fast_reduction: usize = 15 * 1024 * 1024;
    const slow_reduction: usize = 8 * 1024 * 1024;

    while (worker_state.shouldRun()) {
        iteration += 1;
        // Simulate batch processing with varying batch sizes
        if (iteration % 6 == 0) {
            const batch_size = 40 * 1024 * 1024 + (iteration % 4) * 10 * 1024 * 1024; // 40-70MB batches
            memory_usage += batch_size;
        }
        if (memory_usage > 25 * 1024 * 1024) {
            // Process batch with varying speeds
            memory_usage = @max(25 * 1024 * 1024, memory_usage - if (iteration % 3 == 0) fast_reduction else slow_reduction);
        } else {
            memory_usage += 2 * 1024 * 1024; // Small growth between batches
        }
        worker_state.allocateMemory(memory_usage);
        std.time.sleep(1500 * std.time.ns_per_ms);
    }
}

/// Health check functions for different workers
fn checkSystemHealth() bool {
    return worker_state.is_healthy;
}

fn checkBusinessHealth() bool {
    return worker_state.is_healthy and worker_state.memory_usage < 75 * 1024 * 1024;
}

fn checkBackgroundHealth() bool {
    // Simulate health check failures based on memory pressure
    if (worker_state.memory_usage > 150 * 1024 * 1024) {
        // Since we can't modify the process stats directly, we'll just return false
        return false;
    }
    return worker_state.isHealthy();
}
