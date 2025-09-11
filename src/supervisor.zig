//! Supervisor module provides process supervision capabilities inspired by Erlang/OTP.
//! It manages child processes with different restart strategies and monitoring capabilities.
//!
//! Example usage:
//! ```zig
//! const supervisor = Supervisor.init(allocator, .{
//!     .strategy = .one_for_one,
//!     .max_restarts = 3,
//!     .max_seconds = 5,
//! });
//! defer supervisor.deinit();
//!
//! try supervisor.addChild(.{
//!     .id = "worker1",
//!     .start_fn = workerFunction,
//!     .restart_type = .permanent,
//!     .shutdown_timeout_ms = 1000,
//! });
//!
//! try supervisor.start();
//! try supervisor.startMonitoring();
//! ```
const SupervisorMod = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
const Process = @import("process.zig");

/// Defines how the supervisor should handle process restarts.
/// This determines the strategy used when a child process fails.
pub const RestartStrategy = enum {
    /// Only restart the failed process.
    /// This is the most isolated strategy and is suitable when processes are independent.
    one_for_one,

    /// Restart all processes if any fails.
    /// Use this when all processes are interdependent and need to be restarted together.
    one_for_all,

    /// Restart the failed process and all processes started after it.
    /// Useful when there's a dependency chain where later processes depend on earlier ones.
    rest_for_one,
};

/// Configuration options for supervisor behavior.
/// These options determine how the supervisor manages its child processes.
/// - strategy: RestartStrategy,
/// - max_restarts: u32,
/// - max_seconds: u32,
pub const SupervisorOptions = struct {
    /// Strategy to use when restarting processes
    strategy: RestartStrategy,
    /// Maximum number of restarts allowed within max_seconds
    max_restarts: u32,
    /// Time window in seconds for max_restarts
    max_seconds: u32,
};

/// Statistics about supervisor operations.
/// These stats can be used for monitoring and debugging.
/// - total_restarts: u32,
/// - uptime_ms: i64,
/// - last_failure_time: i64,
/// - active_children: u32,
pub const SupervisorStats = struct {
    /// Total number of process restarts since supervisor start
    total_restarts: u32 = 0,
    /// Supervisor uptime in milliseconds
    uptime_ms: i64 = 0,
    /// Timestamp of last process failure
    last_failure_time: i64 = 0,
    /// Current number of running processes
    active_children: u32 = 0,
};

/// Possible supervisor errors that can occur during operation
pub const SupervisorError = error{
    /// Maximum restart limit exceeded within the time window
    TooManyRestarts,
    /// Attempted operation on non-existent child
    ChildNotFound,
    /// Attempted to start monitoring when already monitoring
    AlreadyMonitoring,
    /// Process shutdown exceeded timeout duration
    ShutdownTimeout,
};

/// Current state of the supervisor
pub const SupervisorState = enum {
    /// Initial state before start
    initial,
    /// Supervisor is running and monitoring children
    running,
    /// Supervisor is in the process of stopping
    stopping,
    /// Supervisor has stopped
    stopped,
};

/// Main supervisor structure that manages child processes
///
/// fields:
/// - allocator: Allocator,
/// - children: std.ArrayList(Process.ChildProcess),
/// - options: SupervisorOptions,
/// - restart_count: u32,
/// - last_restart_time: i64,
/// - mutex: Mutex,
/// - stats: SupervisorStats,
/// - monitor_thread: ?std.Thread,
/// - is_shutting_down: bool,
/// - state: SupervisorState,
///
/// methods:
/// - init: fn (allocator: Allocator, options: SupervisorOptions) Supervisor,
/// - deinit: fn (self: *Supervisor) void,
/// - addChild: fn (self: *Supervisor, spec: Process.ChildSpec) !void,
/// - start: fn (self: *Supervisor) !void,
/// - startMonitoring: fn (self: *Supervisor) !void,
/// - stopMonitoring: fn (self: *Supervisor) void,
/// - getStats: fn (self: *Supervisor) SupervisorStats,
/// - shutdown: fn (self: *Supervisor, timeout_ms: i64) SupervisorError!void,
/// - findChild: fn (self: *Supervisor, id: []const u8) ?*Process.ChildProcess,
pub const Supervisor = struct {
    /// Memory allocator used by the supervisor
    allocator: Allocator,
    /// List of child processes being supervised
    children: std.ArrayList(Process.ChildProcess),
    /// Configuration options for this supervisor
    options: SupervisorOptions,
    /// Count of restarts within the current time window
    restart_count: u32,
    /// Timestamp of the last restart
    last_restart_time: i64,
    /// Mutex for thread-safe operations
    mutex: Mutex,
    /// Current statistics for this supervisor
    stats: SupervisorStats,
    /// Handle to the monitoring thread
    monitor_thread: ?std.Thread,
    /// Flag indicating shutdown in progress
    is_shutting_down: bool,
    /// Current state of the supervisor
    state: SupervisorState,

    /// Initialize a new supervisor with the given options.
    /// The supervisor will use the provided allocator for memory management.
    pub fn init(allocator: Allocator, options: SupervisorOptions) Supervisor {
        return .{
            .allocator = allocator,
            .children = std.ArrayList(Process.ChildProcess){},
            .options = options,
            .restart_count = 0,
            .last_restart_time = 0,
            .mutex = Mutex{},
            .stats = .{
                .uptime_ms = std.time.milliTimestamp(),
            },
            .monitor_thread = null,
            .is_shutting_down = false,
            .state = .initial,
        };
    }

    /// Clean up supervisor resources.
    /// This will attempt to gracefully shut down all child processes.
    pub fn deinit(self: *Supervisor) void {
        // First stop monitoring and wait for thread to finish
        if (self.state != .stopped) {
            self.stopMonitoring();
            self.shutdown(5000) catch {};
        }
        self.children.deinit(self.allocator);
    }

    /// Add a child process to be supervised.
    /// Returns error.AlreadyMonitoring if a child with the same ID already exists.
    pub fn addChild(self: *Supervisor, spec: Process.ChildSpec) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Search for existing child without acquiring mutex again
        for (self.children.items) |*child| {
            if (std.mem.eql(u8, child.spec.id, spec.id)) {
                return error.AlreadyMonitoring;
            }
        }

        const child = Process.ChildProcess.init(self.allocator, spec);
        try self.children.append(self.allocator, child);
    }

    /// Start all child processes.
    /// This transitions the supervisor from initial to running state.
    /// Returns error.AlreadyRunning if the supervisor is not in initial state.
    pub fn start(self: *Supervisor) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.state != .initial) return error.AlreadyRunning;

        for (self.children.items) |*child| {
            try child.start();
        }

        self.state = .running;
    }

    /// Start monitoring child processes.
    /// This spawns a monitoring thread that checks process states and handles failures.
    /// Returns error.AlreadyMonitoring if monitoring is already active.
    pub fn startMonitoring(self: *Supervisor) !void {
        if (self.monitor_thread != null) return error.AlreadyMonitoring;
        self.monitor_thread = try std.Thread.spawn(.{}, monitorChildren, .{self});
    }

    /// Stop monitoring child processes.
    /// This gracefully stops the monitoring thread.
    pub fn stopMonitoring(self: *Supervisor) void {
        self.mutex.lock();
        self.is_shutting_down = true;
        const thread_handle = self.monitor_thread;
        self.monitor_thread = null;
        self.mutex.unlock();

        if (thread_handle) |thread| {
            thread.join(); // Wait for thread to finish
        }
    }

    /// Get current supervisor statistics.
    /// Returns a copy of the current stats with up-to-date active children count.
    pub fn getStats(self: *Supervisor) SupervisorStats {
        self.mutex.lock();
        defer self.mutex.unlock();

        var active: u32 = 0;
        for (self.children.items) |*child| {
            if (child.getState() == .running) active += 1;
        }

        self.stats.active_children = active;
        return self.stats;
    }

    /// Gracefully shut down the supervisor and all child processes.
    /// Waits up to timeout_ms for processes to stop before returning error.ShutdownTimeout.
    pub fn shutdown(self: *Supervisor, timeout_ms: i64) SupervisorError!void {
        // Check and set state atomically
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.state == .stopped) return;
            self.state = .stopping;
        }

        // First stop monitoring to prevent interference
        self.stopMonitoring();

        // Then handle children shutdown
        {
            self.mutex.lock();
            defer self.mutex.unlock();

            for (self.children.items) |*child| {
                child.stop() catch {};
            }
        }

        // Wait for children to stop (without holding the mutex continuously)
        const start_time = std.time.milliTimestamp();
        while (true) {
            var all_stopped = true;

            // Check if all children are stopped
            {
                self.mutex.lock();
                defer self.mutex.unlock();

                for (self.children.items) |*child| {
                    if (child.isAlive()) {
                        all_stopped = false;
                        break;
                    }
                }
            }

            if (all_stopped) break;

            const elapsed = std.time.milliTimestamp() - start_time;
            if (elapsed > timeout_ms) return error.ShutdownTimeout;

            // Sleep without holding the mutex
            std.Thread.sleep(50 * std.time.ns_per_ms);
        }

        // Set final state
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.state = .stopped;
        }
    }

    /// Find a child process by ID.
    /// Returns null if no child with the given ID exists.
    pub fn findChild(self: *Supervisor, id: []const u8) ?*Process.ChildProcess {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.children.items) |*child| {
            if (std.mem.eql(u8, child.spec.id, id)) {
                return child;
            }
        }
        return null;
    }

    // Internal functions below this point

    /// Internal function to handle child process failure according to restart strategy
    fn handleChildFailure(self: *Supervisor, failed_child: *Process.ChildProcess) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const current_time = std.time.milliTimestamp();
        self.stats.last_failure_time = current_time;

        // Reset restart count if outside time window
        const time_diff = current_time - self.last_restart_time;
        if (time_diff > self.options.max_seconds * 1000) {
            self.restart_count = 0;
        }

        // Check restart limits
        self.restart_count += 1;
        if (self.restart_count > self.options.max_restarts) {
            return error.TooManyRestarts;
        }

        self.last_restart_time = current_time;

        // Apply restart strategy according to configuration
        switch (self.options.strategy) {
            .one_for_one => {
                try failed_child.start();
                self.stats.total_restarts += 1;
            },
            .one_for_all => {
                for (self.children.items) |*child| {
                    child.stop() catch {};
                    try child.start();
                }
                self.stats.total_restarts += 1;
            },
            .rest_for_one => {
                var found_failed = false;
                for (self.children.items) |*child| {
                    if (child == failed_child) {
                        found_failed = true;
                    }
                    if (found_failed) {
                        child.stop() catch {};
                        try child.start();
                    }
                }
                self.stats.total_restarts += 1;
            },
        }
    }

    /// Monitor thread function that continuously checks child processes
    fn monitorChildren(self: *Supervisor) !void {
        while (true) {
            // Check shutdown flag without holding the main lock
            self.mutex.lock();
            const should_shutdown = self.is_shutting_down;
            self.mutex.unlock();

            if (should_shutdown) break;

            // Sleep at the start to prevent tight loop
            std.Thread.sleep(100 * std.time.ns_per_ms);

            // Now check children with proper locking
            self.mutex.lock();

            // Check all children while holding the lock
            for (self.children.items) |*child| {
                const child_state = child.getState();
                if (child_state == .failed and child.spec.restart_type != .temporary) {
                    // Handle failure according to restart strategy
                    const current_time = std.time.milliTimestamp();
                    self.stats.last_failure_time = current_time;

                    const time_diff = current_time - self.last_restart_time;
                    if (time_diff > self.options.max_seconds * 1000) {
                        self.restart_count = 0;
                    }

                    self.restart_count += 1;
                    if (self.restart_count > self.options.max_restarts) {
                        self.mutex.unlock();
                        return error.TooManyRestarts;
                    }

                    self.last_restart_time = current_time;

                    // Apply restart strategy with state verification
                    switch (self.options.strategy) {
                        .one_for_one => {
                            child.stop() catch {};
                            try child.start();
                            self.stats.total_restarts += 1;
                        },
                        .one_for_all => {
                            for (self.children.items) |*sibling| {
                                sibling.stop() catch {};
                                try sibling.start();
                            }
                            self.stats.total_restarts += 1;
                        },
                        .rest_for_one => {
                            var found_failed = false;
                            for (self.children.items) |*sibling| {
                                if (sibling == child) {
                                    found_failed = true;
                                }
                                if (found_failed) {
                                    sibling.stop() catch {};
                                    try sibling.start();
                                }
                            }
                            self.stats.total_restarts += 1;
                        },
                    }
                }
            }

            self.mutex.unlock();
        }
    }
};

test "supervisor basic operations" {
    const allocator = std.testing.allocator;

    const options = SupervisorOptions{
        .strategy = .one_for_one,
        .max_restarts = 3,
        .max_seconds = 5,
    };

    var supervisor = Supervisor.init(allocator, options);
    defer supervisor.deinit();

    try supervisor.addChild(.{
        .id = "test1",
        .start_fn = struct {
            fn testFn() void {
                std.Thread.sleep(200 * std.time.ns_per_ms);
            }
        }.testFn,
        .restart_type = .permanent,
        .shutdown_timeout_ms = 100,
    });

    try supervisor.start();

    // Wait for process to start
    std.Thread.sleep(150 * std.time.ns_per_ms);

    const stats = supervisor.getStats();
    try std.testing.expect(stats.active_children == 1);
    try std.testing.expect(stats.total_restarts == 0);

    try supervisor.shutdown(5000);

    // Verify shutdown completed successfully
    {
        supervisor.mutex.lock();
        defer supervisor.mutex.unlock();

        if (supervisor.children.items.len > 0) {
            try std.testing.expect(!supervisor.children.items[0].isAlive());
        }
        try std.testing.expect(supervisor.state == .stopped);
    }
}

test "supervisor monitoring" {
    const allocator = std.testing.allocator;

    const options = SupervisorOptions{
        .strategy = .one_for_one,
        .max_restarts = 3,
        .max_seconds = 5,
    };

    var supervisor = Supervisor.init(allocator, options);
    defer supervisor.deinit();

    try supervisor.addChild(.{
        .id = "monitor_test",
        .start_fn = struct {
            fn testFn() void {
                std.Thread.sleep(300 * std.time.ns_per_ms);
            }
        }.testFn,
        .restart_type = .permanent,
        .shutdown_timeout_ms = 100,
    });

    try supervisor.start();
    try supervisor.startMonitoring();

    // Wait for process to start
    std.Thread.sleep(150 * std.time.ns_per_ms);

    const stats = supervisor.getStats();
    try std.testing.expect(stats.active_children == 1);

    // Stop monitoring first before shutdown
    supervisor.stopMonitoring();

    // Wait a bit for monitoring thread to fully stop
    std.Thread.sleep(50 * std.time.ns_per_ms);

    try supervisor.shutdown(5000);

    // Verify shutdown completed successfully
    {
        supervisor.mutex.lock();
        defer supervisor.mutex.unlock();
        try std.testing.expect(supervisor.state == .stopped);
    }
}

test "supervisor restart strategies" {
    const allocator = std.testing.allocator;

    // Test one_for_one strategy
    {
        var supervisor = Supervisor.init(allocator, .{
            .strategy = .one_for_one,
            .max_restarts = 3,
            .max_seconds = 5,
        });
        defer {
            supervisor.stopMonitoring();
            std.Thread.sleep(200 * std.time.ns_per_ms);
            supervisor.deinit();
        }

        try supervisor.addChild(.{
            .id = "test1",
            .start_fn = struct {
                fn testFn() void {
                    while (true) {
                        std.Thread.sleep(50 * std.time.ns_per_ms);
                    }
                }
            }.testFn,
            .restart_type = .permanent,
            .shutdown_timeout_ms = 100,
        });

        try supervisor.start();
        try supervisor.startMonitoring();

        // Wait for process to start
        std.Thread.sleep(200 * std.time.ns_per_ms);

        // Force single failure
        {
            const child = supervisor.findChild("test1").?;
            child.mutex.lock();
            child.state = .failed;
            child.mutex.unlock();
        }

        // Wait for restart to complete
        std.Thread.sleep(500 * std.time.ns_per_ms);

        // Get stats with mutex protection
        const stats = supervisor.getStats();
        try std.testing.expectEqual(@as(u32, 1), stats.total_restarts);
        try std.testing.expectEqual(@as(u32, 1), stats.active_children);
    }
}

test "supervisor max restarts" {
    const allocator = std.testing.allocator;
    var supervisor = Supervisor.init(allocator, .{
        .strategy = .one_for_one,
        .max_restarts = 2,
        .max_seconds = 5,
    });
    defer {
        supervisor.stopMonitoring();
        std.Thread.sleep(200 * std.time.ns_per_ms);
        supervisor.deinit();
    }

    try supervisor.addChild(.{
        .id = "test_restart",
        .start_fn = struct {
            fn testFn() void {
                std.Thread.sleep(50 * std.time.ns_per_ms);
            }
        }.testFn,
        .restart_type = .permanent,
        .shutdown_timeout_ms = 100,
    });

    try supervisor.start();
    try supervisor.startMonitoring();

    // Wait for initial start
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // Force exactly two failures
    {
        const child = supervisor.findChild("test_restart").?;
        for (0..2) |_| {
            child.mutex.lock();
            child.state = .failed;
            child.mutex.unlock();
            std.Thread.sleep(200 * std.time.ns_per_ms);
        }
    }

    // Stop monitoring before checking stats
    supervisor.stopMonitoring();
    std.Thread.sleep(200 * std.time.ns_per_ms);

    // Get stats with mutex protection
    supervisor.mutex.lock();
    const stats = supervisor.stats;
    supervisor.mutex.unlock();

    try std.testing.expectEqual(@as(u32, 2), stats.total_restarts);
}

test "supervisor findChild" {
    const allocator = std.testing.allocator;
    var supervisor = Supervisor.init(allocator, .{
        .strategy = .one_for_one,
        .max_restarts = 3,
        .max_seconds = 5,
    });
    defer supervisor.deinit();

    try supervisor.addChild(.{
        .id = "test_find",
        .start_fn = struct {
            fn testFn() void {
                std.Thread.sleep(50 * std.time.ns_per_ms);
            }
        }.testFn,
        .restart_type = .permanent,
        .shutdown_timeout_ms = 100,
    });

    const found = supervisor.findChild("test_find");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("test_find", found.?.spec.id);

    const not_found = supervisor.findChild("nonexistent");
    try std.testing.expect(not_found == null);
}
