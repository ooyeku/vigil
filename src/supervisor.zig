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
const std = @import("std");
const Allocator = std.mem.Allocator;
const compat = @import("compat.zig");
const Mutex = compat.Mutex;
const Process = @import("process.zig");
const telemetry = @import("telemetry.zig");

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

/// Callback invoked when the supervisor observes a child failure.
pub const CrashHandler = *const fn (child_id: []const u8) void;

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
    /// Optional callback invoked before restart handling.
    crash_handler: ?CrashHandler = null,
    /// Emit telemetry when child failures are observed.
    enable_telemetry: bool = false,
};

/// Internal restart bookkeeping surfaced through `Supervisor.snapshot()`.
const SupervisorStats = struct {
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

/// Snapshot of one supervised child.
pub const SupervisorChildSnapshot = struct {
    /// Copied child id owned by the enclosing snapshot.
    id: []const u8,
    /// Child process state at snapshot time.
    state: Process.ProcessState,
    /// Restarts recorded for this child.
    restart_count: u32,
};

/// Owned snapshot of a supervisor and its supervised children.
pub const SupervisorSnapshot = struct {
    allocator: Allocator,
    /// Supervisor state at snapshot time.
    state: SupervisorState,
    /// Configured restart strategy.
    strategy: RestartStrategy,
    /// Number of supervised children.
    child_count: usize,
    /// Number of children currently running.
    active_children: usize,
    /// Total restarts since supervisor start.
    total_restarts: u32,
    /// Wall-clock timestamp of the most recent child failure, or zero.
    last_failure_time_ms: i64,
    /// Elapsed supervisor uptime in milliseconds.
    uptime_ms: i64,
    /// Per-child snapshots in registration order.
    children: []SupervisorChildSnapshot,

    /// Release copied child ids and snapshot storage.
    pub fn deinit(self: *SupervisorSnapshot) void {
        for (self.children) |child| {
            self.allocator.free(child.id);
        }
        self.allocator.free(self.children);
    }
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
/// - allocated_child_ids: std.ArrayList([]const u8),
///
/// methods:
/// - init: fn (allocator: Allocator, options: SupervisorOptions) Supervisor,
/// - deinit: fn (self: *Supervisor) void,
/// - addChild: fn (self: *Supervisor, spec: Process.ChildSpec) !void,
/// - start: fn (self: *Supervisor) !void,
/// - stop: fn (self: *Supervisor) void,
/// - startMonitoring: fn (self: *Supervisor) !void,
/// - stopMonitoring: fn (self: *Supervisor) void,
/// - snapshot: fn (self: *Supervisor, allocator: Allocator) !SupervisorSnapshot,
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
    /// Monotonic timestamp used to compute elapsed uptime.
    started_at_ms: i64,
    /// Handle to the monitoring thread
    monitor_thread: ?std.Thread,
    /// Flag indicating shutdown in progress
    is_shutting_down: bool,
    /// Current state of the supervisor
    state: SupervisorState,
    /// Optional emitter for crash telemetry. Not owned.
    telemetry_emitter: ?*telemetry.TelemetryEmitter,
    /// List of child IDs allocated by the builder that need to be freed
    allocated_child_ids: std.ArrayList([]const u8),

    /// Initialize a new supervisor with the given options.
    /// The supervisor will use the provided allocator for memory management.
    pub fn init(allocator: Allocator, options: SupervisorOptions) Supervisor {
        return .{
            .allocator = allocator,
            .children = .empty,
            .options = options,
            .restart_count = 0,
            .last_restart_time = 0,
            .mutex = Mutex{},
            .stats = .{},
            .started_at_ms = compat.monotonicMilliTimestamp(),
            .monitor_thread = null,
            .is_shutting_down = false,
            .state = .initial,
            .telemetry_emitter = null,
            .allocated_child_ids = .empty,
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
        // Free all allocated child IDs (from builder)
        for (self.allocated_child_ids.items) |id| {
            self.allocator.free(id);
        }
        self.allocated_child_ids.deinit(self.allocator);
        self.children.deinit(self.allocator);
    }

    /// Attach an emitter for child-crash telemetry. Not owned.
    pub fn setTelemetryEmitter(self: *Supervisor, emitter: ?*telemetry.TelemetryEmitter) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.telemetry_emitter = emitter;
    }

    /// Convenience method to stop the supervisor with a default timeout.
    /// This is an alias for shutdown(5000) that ignores errors.
    pub fn stop(self: *Supervisor) void {
        self.shutdown(5000) catch {};
    }

    /// Track a child ID allocation for cleanup during deinit.
    /// This is used by the supervisor builder to register allocated IDs.
    pub fn trackAllocatedChildId(self: *Supervisor, id: []const u8) !void {
        try self.allocated_child_ids.append(self.allocator, id);
    }

    /// Add a child process to be supervised.
    /// Returns error.AlreadyMonitoring if a child with the same ID already exists.
    pub fn addChild(self: *Supervisor, spec: Process.ChildSpec) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // ChildProcess values live inside an ArrayList. Growing that list while
        // workers are running would invalidate the pointers held by their
        // thread contexts.
        if (self.state != .initial) return error.InvalidState;

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

        var started: usize = 0;
        for (self.children.items) |*child| {
            child.start() catch |err| {
                for (self.children.items[0..started]) |*started_child| {
                    started_child.stop() catch {};
                }
                return err;
            };
            started += 1;
        }

        self.state = .running;
    }

    /// Start monitoring child processes.
    /// This spawns a monitoring thread that checks process states and handles failures.
    /// Returns error.AlreadyMonitoring if monitoring is already active.
    pub fn startMonitoring(self: *Supervisor) !void {
        self.mutex.lock();
        if (self.monitor_thread != null) {
            self.mutex.unlock();
            return error.AlreadyMonitoring;
        }
        if (self.state != .running) {
            self.mutex.unlock();
            return error.InvalidState;
        }
        self.is_shutting_down = false;
        self.monitor_thread = std.Thread.spawn(.{}, monitorChildren, .{self}) catch |err| {
            self.mutex.unlock();
            return err;
        };
        self.mutex.unlock();
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
        const start_time = compat.monotonicMilliTimestamp();
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

            const elapsed = compat.monotonicMilliTimestamp() - start_time;
            if (elapsed >= timeout_ms) return error.ShutdownTimeout;

            // Sleep without holding the mutex
            compat.sleep(50 * std.time.ns_per_ms);
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

    /// Capture an owned snapshot of the supervision tree.
    ///
    /// The caller owns the returned snapshot and must call `deinit()`.
    pub fn snapshot(self: *Supervisor, allocator: Allocator) !SupervisorSnapshot {
        self.mutex.lock();
        defer self.mutex.unlock();

        const children = try allocator.alloc(SupervisorChildSnapshot, self.children.items.len);
        errdefer allocator.free(children);

        var written: usize = 0;
        errdefer for (children[0..written]) |child| {
            allocator.free(child.id);
        };

        var active: usize = 0;
        for (self.children.items) |*child| {
            const child_state = child.getState();
            if (child_state == .running) active += 1;
            const id_copy = try allocator.dupe(u8, child.spec.id);
            children[written] = .{
                .id = id_copy,
                .state = child_state,
                .restart_count = child.stats.restart_count,
            };
            written += 1;
        }

        return .{
            .allocator = allocator,
            .state = self.state,
            .strategy = self.options.strategy,
            .child_count = children.len,
            .active_children = active,
            .total_restarts = self.stats.total_restarts,
            .last_failure_time_ms = self.stats.last_failure_time,
            .uptime_ms = @max(0, compat.monotonicMilliTimestamp() -| self.started_at_ms),
            .children = children,
        };
    }

    /// Force restart a child
    pub fn restartChild(self: *Supervisor, id: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.children.items) |*child| {
            if (std.mem.eql(u8, child.spec.id, id)) {
                child.stop() catch {};
                try child.start();
                return;
            }
        }
        return error.ChildNotFound;
    }

    /// Suspend a child (pause without stopping)
    pub fn suspendChild(self: *Supervisor, id: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.children.items) |*child| {
            if (std.mem.eql(u8, child.spec.id, id)) {
                return child.sendSignal(.@"suspend");
            }
        }
        return error.ChildNotFound;
    }

    /// Resume a suspended child
    pub fn resumeChild(self: *Supervisor, id: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.children.items) |*child| {
            if (std.mem.eql(u8, child.spec.id, id)) {
                return child.sendSignal(.@"resume");
            }
        }
        return error.ChildNotFound;
    }

    fn notifyChildCrash(self: *Supervisor, child_id: []const u8) void {
        if (self.options.crash_handler) |handler| {
            handler(child_id);
        }

        if (self.options.enable_telemetry) {
            if (self.telemetry_emitter) |emitter| {
                emitter.emit(.{
                    .event_type = .process_crashed,
                    .timestamp_ms = compat.milliTimestamp(),
                    .metadata = child_id,
                });
            }
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
            compat.sleep(100 * std.time.ns_per_ms);

            // Now check children with proper locking
            self.mutex.lock();

            // Check all children while holding the lock
            for (self.children.items) |*child| {
                const child_state = child.getState();
                if (child_state == .failed and child.spec.restart_type != .temporary) {
                    // Handle failure according to restart strategy
                    const current_time = compat.milliTimestamp();
                    self.stats.last_failure_time = current_time;
                    const child_id = child.spec.id;
                    self.mutex.unlock();
                    self.notifyChildCrash(child_id);
                    self.mutex.lock();

                    const restart_time = compat.monotonicMilliTimestamp();
                    const time_diff = restart_time - self.last_restart_time;
                    if (time_diff > @as(i64, self.options.max_seconds) * 1000) {
                        self.restart_count = 0;
                    }

                    self.restart_count +|= 1;
                    if (self.restart_count > self.options.max_restarts) {
                        self.mutex.unlock();
                        return error.TooManyRestarts;
                    }

                    self.last_restart_time = restart_time;

                    // Apply restart strategy with state verification
                    switch (self.options.strategy) {
                        .one_for_one => {
                            child.stop() catch {};
                            try child.start();
                            self.stats.total_restarts +|= 1;
                        },
                        .one_for_all => {
                            for (self.children.items) |*sibling| {
                                sibling.stop() catch {};
                                try sibling.start();
                            }
                            self.stats.total_restarts +|= 1;
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
                            self.stats.total_restarts +|= 1;
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
    const WorkerGate = struct {
        var stop = std.atomic.Value(bool).init(false);

        fn run() void {
            while (!stop.load(.acquire)) {
                compat.sleep(1 * std.time.ns_per_ms);
            }
        }
    };
    WorkerGate.stop.store(false, .release);

    const options = SupervisorOptions{
        .strategy = .one_for_one,
        .max_restarts = 3,
        .max_seconds = 5,
    };

    var supervisor = Supervisor.init(allocator, options);
    defer supervisor.deinit();
    defer WorkerGate.stop.store(true, .release);

    try supervisor.addChild(.{
        .id = "test1",
        .start_fn = WorkerGate.run,
        .restart_type = .permanent,
        .shutdown_timeout_ms = 100,
    });

    try supervisor.start();

    try std.testing.expectError(error.InvalidState, supervisor.addChild(.{
        .id = "late-child",
        .start_fn = WorkerGate.run,
        .restart_type = .temporary,
        .shutdown_timeout_ms = 100,
    }));

    var stats = try supervisor.snapshot(allocator);
    defer stats.deinit();
    try std.testing.expect(stats.active_children == 1);
    try std.testing.expect(stats.total_restarts == 0);
    try std.testing.expect(stats.uptime_ms >= 0);
    try std.testing.expect(stats.uptime_ms < 60_000);

    WorkerGate.stop.store(true, .release);
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
                compat.sleep(300 * std.time.ns_per_ms);
            }
        }.testFn,
        .restart_type = .permanent,
        .shutdown_timeout_ms = 100,
    });

    try supervisor.start();
    try supervisor.startMonitoring();

    // Wait for process to start
    compat.sleep(150 * std.time.ns_per_ms);

    var stats = try supervisor.snapshot(allocator);
    defer stats.deinit();
    try std.testing.expect(stats.active_children == 1);

    // Stop monitoring first before shutdown
    supervisor.stopMonitoring();

    // Wait a bit for monitoring thread to fully stop
    compat.sleep(50 * std.time.ns_per_ms);

    // Monitoring can be restarted after a clean stop.
    try supervisor.startMonitoring();
    try std.testing.expect(!supervisor.is_shutting_down);
    supervisor.stopMonitoring();

    try supervisor.shutdown(5000);

    // Verify shutdown completed successfully
    {
        supervisor.mutex.lock();
        defer supervisor.mutex.unlock();
        try std.testing.expect(supervisor.state == .stopped);
    }
}

var supervisor_crash_count = std.atomic.Value(u32).init(0);
var supervisor_crash_event_count = std.atomic.Value(u32).init(0);

fn recordSupervisorCrash(_: []const u8) void {
    _ = supervisor_crash_count.fetchAdd(1, .monotonic);
}

fn recordSupervisorCrashEvent(event: telemetry.Event) void {
    if (event.event_type == .process_crashed) {
        _ = supervisor_crash_event_count.fetchAdd(1, .monotonic);
    }
}

test "supervisor restart strategies" {
    const allocator = std.testing.allocator;
    const WorkerGate = struct {
        var stop = std.atomic.Value(bool).init(false);

        fn run() void {
            while (!stop.load(.acquire)) {
                compat.sleep(1 * std.time.ns_per_ms);
            }
        }
    };
    WorkerGate.stop.store(false, .release);

    // Test one_for_one strategy
    {
        supervisor_crash_count.store(0, .release);
        supervisor_crash_event_count.store(0, .release);
        var emitter = telemetry.TelemetryEmitter.init(allocator);
        defer emitter.deinit();
        try emitter.on(.process_crashed, recordSupervisorCrashEvent);

        var supervisor = Supervisor.init(allocator, .{
            .strategy = .one_for_one,
            .max_restarts = 3,
            .max_seconds = 5,
            .crash_handler = recordSupervisorCrash,
            .enable_telemetry = true,
        });
        defer {
            WorkerGate.stop.store(true, .release);
            supervisor.stopMonitoring();
            compat.sleep(200 * std.time.ns_per_ms);
            supervisor.deinit();
        }

        supervisor.setTelemetryEmitter(&emitter);
        try supervisor.addChild(.{
            .id = "test1",
            .start_fn = WorkerGate.run,
            .restart_type = .permanent,
            .shutdown_timeout_ms = 100,
        });

        try supervisor.start();
        try supervisor.startMonitoring();

        // Wait for process to start
        compat.sleep(200 * std.time.ns_per_ms);

        // Force single failure
        {
            const child = supervisor.findChild("test1").?;
            child.mutex.lock();
            child.state = .failed;
            child.mutex.unlock();
        }

        // Wait for restart, crash callback, and telemetry to complete.
        var waited_ms: u32 = 0;
        while ((supervisor.stats.total_restarts == 0 or
            supervisor_crash_count.load(.acquire) == 0 or
            supervisor_crash_event_count.load(.acquire) == 0) and waited_ms < 3000) : (waited_ms += 25)
        {
            compat.sleep(25 * std.time.ns_per_ms);
        }

        // Get stats with mutex protection
        var stats = try supervisor.snapshot(allocator);
        defer stats.deinit();
        try std.testing.expectEqual(@as(u32, 1), stats.total_restarts);
        try std.testing.expectEqual(@as(usize, 1), stats.active_children);
        try std.testing.expectEqual(@as(u32, 1), supervisor_crash_count.load(.acquire));
        try std.testing.expectEqual(@as(u32, 1), supervisor_crash_event_count.load(.acquire));
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
        compat.sleep(200 * std.time.ns_per_ms);
        supervisor.deinit();
    }

    try supervisor.addChild(.{
        .id = "test_restart",
        .start_fn = struct {
            fn testFn() void {
                compat.sleep(50 * std.time.ns_per_ms);
            }
        }.testFn,
        .restart_type = .permanent,
        .shutdown_timeout_ms = 100,
    });

    try supervisor.start();
    try supervisor.startMonitoring();

    // Wait for initial start
    compat.sleep(100 * std.time.ns_per_ms);

    // Force exactly two failures
    {
        const child = supervisor.findChild("test_restart").?;
        for (0..2) |_| {
            child.mutex.lock();
            child.state = .failed;
            child.mutex.unlock();
            compat.sleep(200 * std.time.ns_per_ms);
        }
    }

    // Stop monitoring before checking stats
    supervisor.stopMonitoring();
    compat.sleep(200 * std.time.ns_per_ms);

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
                compat.sleep(50 * std.time.ns_per_ms);
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

test "supervisor snapshot captures children and state" {
    const allocator = std.testing.allocator;
    const WorkerGate = struct {
        var stop = std.atomic.Value(bool).init(false);

        fn run() void {
            while (!stop.load(.acquire)) {
                compat.sleep(1 * std.time.ns_per_ms);
            }
        }
    };
    WorkerGate.stop.store(false, .release);

    var supervisor = Supervisor.init(allocator, .{
        .strategy = .one_for_one,
        .max_restarts = 3,
        .max_seconds = 5,
    });
    defer supervisor.deinit();
    defer WorkerGate.stop.store(true, .release);

    try supervisor.addChild(.{
        .id = "snapshot-worker",
        .start_fn = WorkerGate.run,
        .restart_type = .permanent,
        .shutdown_timeout_ms = 100,
    });

    var initial = try supervisor.snapshot(allocator);
    defer initial.deinit();
    try std.testing.expectEqual(SupervisorState.initial, initial.state);
    try std.testing.expectEqual(@as(usize, 1), initial.child_count);
    try std.testing.expectEqual(@as(usize, 0), initial.active_children);
    try std.testing.expectEqualStrings("snapshot-worker", initial.children[0].id);

    try supervisor.start();
    var running = try supervisor.snapshot(allocator);
    defer running.deinit();
    try std.testing.expectEqual(SupervisorState.running, running.state);
    try std.testing.expectEqual(RestartStrategy.one_for_one, running.strategy);
    try std.testing.expectEqual(@as(usize, 1), running.active_children);
    try std.testing.expectEqual(Process.ProcessState.running, running.children[0].state);
    try std.testing.expect(running.uptime_ms >= 0);

    WorkerGate.stop.store(true, .release);
    try supervisor.shutdown(5000);
}
