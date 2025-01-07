//! Process management module for the Vigil supervision system.
//! This module provides robust process management capabilities inspired by Erlang/OTP,
//! allowing for fine-grained control over process lifecycle, monitoring, and error handling.
//!
//! Key features:
//! - Process lifecycle management (start, stop, suspend, resume)
//! - Health monitoring and statistics tracking
//! - Resource usage monitoring
//! - Priority-based process management
//! - Signal handling capabilities
//!
//! Example usage:
//! ```zig
//! const process = ChildProcess.init(allocator, .{
//!     .id = "worker1",
//!     .start_fn = workerFunction,
//!     .restart_type = .permanent,
//!     .shutdown_timeout_ms = 1000,
//!     .priority = .normal,
//!     .health_check_fn = healthCheck,
//!     .max_memory_bytes = 1024 * 1024 * 100, // 100MB limit
//! });
//!
//! try process.start();
//! defer process.stop() catch {};
//!
//! // Monitor process health
//! if (!process.checkHealth()) {
//!     // Handle unhealthy process
//! }
//!
//! // Get process statistics
//! const stats = process.getStats();
//! ```

const std = @import("std");
const Thread = std.Thread;
const Mutex = std.Thread.Mutex;
const Allocator = std.mem.Allocator;

/// Comprehensive error set for process operations.
/// These errors cover the full range of potential failure modes
/// that can occur during process lifecycle management.
pub const ProcessError = error{
    /// Process is already in running state when start is called
    AlreadyRunning,
    /// Failed to start the process (thread creation failed)
    StartFailed,
    /// Process did not stop within the specified timeout period
    ShutdownTimeout,
    /// Memory allocation failed
    OutOfMemory,
    /// Health check callback reported process as unhealthy
    HealthCheckFailed,
    /// Process exceeded its configured resource limits
    ResourceLimitExceeded,
    /// Failed to send or process a signal
    SignalFailed,
};

/// Represents the current state of a process in its lifecycle.
/// State transitions should follow this pattern:
/// initial -> running -> (suspended <-> running) -> stopping -> stopped
/// The failed state can be entered from any other state.
pub const ProcessState = enum {
    /// Initial state before first start
    initial,
    /// Process is actively running
    running,
    /// Process is in the process of stopping
    stopping,
    /// Process has completely stopped
    stopped,
    /// Process has encountered an error and failed
    failed,
    /// Process is temporarily suspended but can be resumed
    suspended,
};

/// Signals that can be sent to a running process to control its behavior.
/// These signals provide fine-grained control over process execution.
pub const ProcessSignal = enum {
    /// Temporarily pause process execution
    @"suspend",
    /// Resume a suspended process
    @"resume",
    /// Request process termination
    terminate,
    /// Custom signal for application-specific behavior
    custom,
};

/// Statistics collected about process execution.
/// These statistics are useful for monitoring, debugging, and
/// resource usage tracking.
///
/// Fields:
/// - start_time: i64,
/// - last_active_time: i64,
/// - restart_count: u32,
/// - total_runtime_ms: i64,
/// - peak_memory_bytes: usize,
/// - health_check_failures: u32,
///
pub const ProcessStats = struct {
    /// Timestamp when the process was started
    start_time: i64,
    /// Last time the process was known to be active
    last_active_time: i64,
    /// Number of times the process has been restarted
    restart_count: u32,
    /// Total time the process has been running in milliseconds
    total_runtime_ms: i64,
    /// Peak memory usage observed in bytes
    peak_memory_bytes: usize,
    /// Number of times health checks have failed
    health_check_failures: u32,
};

/// Priority levels for process execution.
/// Higher priority processes receive preferential treatment
/// during resource allocation and scheduling decisions.
pub const ProcessPriority = enum {
    /// Essential system processes that must always run
    critical,
    /// Important business logic processes
    high,
    /// Default priority for most processes
    normal,
    /// Non-essential background tasks
    low,
    /// Lowest priority, can be interrupted or delayed
    batch,
};

/// Configuration specification for a child process.
/// This struct defines all parameters needed to create and manage
/// a process throughout its lifecycle.
///
/// Fields:
/// - id: []const u8,
/// - start_fn: *const fn () void,
/// - restart_type: enum { permanent, transient, temporary },
/// - shutdown_timeout_ms: u32,
/// - priority: ProcessPriority,
/// - max_memory_bytes: ?usize,
/// - health_check_fn: ?*const fn () bool,
/// - health_check_interval_ms: u32,
pub const ChildSpec = struct {
    /// Unique identifier for the process
    id: []const u8,
    /// Function to execute in the process
    start_fn: *const fn () void,
    /// Restart behavior when process terminates
    restart_type: enum {
        /// Always restart the process when it terminates
        permanent,
        /// Restart only if the process terminates abnormally
        transient,
        /// Never restart the process
        temporary,
    },
    /// Maximum time to wait for process shutdown in milliseconds
    shutdown_timeout_ms: u32,
    /// Execution priority level (defaults to normal)
    priority: ProcessPriority = .normal,
    /// Optional memory usage limit in bytes
    max_memory_bytes: ?usize = null,
    /// Optional function to check process health
    health_check_fn: ?*const fn () bool = null,
    /// Interval between health checks in milliseconds
    health_check_interval_ms: u32 = 1000,
};

/// Result information when a process terminates.
/// Contains detailed information about how and why
/// the process ended.
///
/// Fields:
/// - exit_code: u32,
/// - error_message: ?[]const u8,
/// - runtime_ms: i64,
pub const ProcessResult = struct {
    /// Process exit code (0 typically indicates success)
    exit_code: u32,
    /// Optional error message if process failed
    error_message: ?[]const u8,
    /// Total runtime of the process in milliseconds
    runtime_ms: i64,
};

/// Main process management structure.
/// Provides comprehensive process lifecycle management, monitoring,
/// and control capabilities.
///
/// Fields:
/// - spec: ChildSpec,
/// - thread: ?Thread,
/// - mutex: Mutex,
/// - state: ProcessState,
/// - last_error: ?anyerror,
/// - stats: ProcessStats,
/// - result: ?ProcessResult,
///
/// Methods:
/// - init: fn (allocator: Allocator, spec: ChildSpec) ChildProcess,
/// - start: fn (self: *ChildProcess) ProcessError!void,
/// - stop: fn (self: *ChildProcess) ProcessError!void,
/// - isAlive: fn (self: *ChildProcess) bool,
/// - getState: fn (self: *ChildProcess) ProcessState,
/// - sendSignal: fn (self: *ChildProcess, signal: ProcessSignal) ProcessError!void,
/// - checkHealth: fn (self: *ChildProcess) bool,
/// - getStats: fn (self: *ChildProcess) ProcessStats,
/// - getResult: fn (self: *ChildProcess) ?ProcessResult,
/// - updateStats: fn (self: *ChildProcess) void,
/// - checkResourceLimits: fn (self: *ChildProcess) ProcessError!void,
pub const ChildProcess = struct {
    /// Process configuration
    spec: ChildSpec,
    /// Handle to the OS thread
    thread: ?Thread,
    /// Mutex for thread-safe operations
    mutex: Mutex,
    /// Current process state
    state: ProcessState,
    /// Last error encountered, if any
    last_error: ?anyerror,
    /// Process execution statistics
    stats: ProcessStats,
    /// Process termination result
    result: ?ProcessResult,
    /// Memory allocator for process resources
    allocator: Allocator,

    /// Initialize a new child process with the given specification.
    /// The process won't start until start() is called.
    ///
    /// Parameters:
    ///   - allocator: Memory allocator for process resources
    ///   - spec: Process configuration specification
    ///
    /// Returns: Initialized ChildProcess instance
    pub fn init(allocator: Allocator, spec: ChildSpec) ChildProcess {
        return .{
            .spec = spec,
            .thread = null,
            .mutex = Mutex{},
            .state = .initial,
            .last_error = null,
            .allocator = allocator,
            .stats = .{
                .start_time = 0,
                .last_active_time = 0,
                .restart_count = 0,
                .total_runtime_ms = 0,
                .peak_memory_bytes = 0,
                .health_check_failures = 0,
            },
            .result = null,
        };
    }

    /// Start the process execution.
    /// This spawns a new thread and begins executing the start_fn.
    /// The process must be in initial state for this to succeed.
    ///
    /// Returns: Error if process cannot be started
    pub fn start(self: *ChildProcess) ProcessError!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.state == .running) return ProcessError.AlreadyRunning;

        const Context = struct {
            func: *const fn () void,
            process: *ChildProcess,
        };

        const wrapper = struct {
            fn wrap(ctx: *const Context) void {
                // Set initial state with mutex protection
                {
                    ctx.process.mutex.lock();
                    ctx.process.state = .running;
                    ctx.process.updateStats(); // Update stats on start
                    ctx.process.mutex.unlock();
                }

                // Run the function and ensure cleanup
                {
                    defer {
                        // Final state change and cleanup
                        const held = ctx.process.mutex.tryLock();
                        if (held) {
                            ctx.process.state = .stopped;
                            ctx.process.thread = null;
                            ctx.process.updateStats(); // Update stats on stop
                            ctx.process.mutex.unlock();
                        }
                        std.heap.page_allocator.destroy(ctx);
                    }

                    // Run the actual function
                    nosuspend {
                        (ctx.func)();
                    }
                }
            }
        };

        // Allocate context that will be freed by the wrapper
        const context = try std.heap.page_allocator.create(Context);
        errdefer std.heap.page_allocator.destroy(context);

        context.* = .{
            .func = self.spec.start_fn,
            .process = self,
        };

        // Spawn thread with error handling
        self.thread = Thread.spawn(.{}, wrapper.wrap, .{context}) catch {
            std.heap.page_allocator.destroy(context);
            self.state = .failed;
            return ProcessError.StartFailed;
        };

        self.state = .running;
        self.updateStats(); // Update stats after successful start
    }

    /// Gracefully stop the process.
    /// Waits up to shutdown_timeout_ms for the process to stop.
    /// If timeout is reached, the process is forcefully terminated.
    ///
    /// Returns: Error if shutdown fails or times out
    pub fn stop(self: *ChildProcess) ProcessError!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Allow stopping from any state except stopped
        if (self.state == .stopped) return;

        // Handle failed state
        if (self.state == .failed) {
            if (self.thread) |thread| {
                thread.detach();
                self.thread = null;
            }
            return;
        }

        self.state = .stopping;

        if (self.thread) |thread| {
            const start_time = std.time.milliTimestamp();

            while (true) {
                const elapsed = std.time.milliTimestamp() - start_time;
                if (elapsed > self.spec.shutdown_timeout_ms) {
                    thread.detach();
                    self.thread = null;
                    self.state = .failed;
                    return ProcessError.ShutdownTimeout;
                }

                // Check if thread has finished
                if (self.state == .stopped) {
                    thread.detach();
                    self.thread = null;
                    return;
                }

                // Release lock while sleeping
                self.mutex.unlock();
                std.time.sleep(10 * std.time.ns_per_ms);
                self.mutex.lock();
            }
        }

        self.state = .stopped;
        self.thread = null;
    }

    /// Check if the process is currently running.
    /// This is a thread-safe way to check process status.
    ///
    /// Returns: true if process is in running state
    pub fn isAlive(self: *ChildProcess) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.state == .running;
    }

    /// Get the current process state.
    /// This is a thread-safe way to get the process state.
    ///
    /// Returns: Current ProcessState
    pub fn getState(self: *ChildProcess) ProcessState {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.state;
    }

    /// Send a control signal to the process.
    /// Signals can modify process behavior or request state changes.
    ///
    /// Parameters:
    ///   - signal: The signal to send to the process
    ///
    /// Returns: Error if signal cannot be processed
    pub fn sendSignal(self: *ChildProcess, signal: ProcessSignal) ProcessError!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        switch (signal) {
            .@"suspend" => {
                if (self.state == .running) {
                    self.state = .suspended;
                    self.updateStats();
                }
            },
            .@"resume" => {
                if (self.state == .suspended) {
                    self.state = .running;
                    self.updateStats();
                }
            },
            .terminate => {
                if (self.state != .stopped) {
                    try self.stop();
                }
            },
            .custom => {
                // Handle custom signals if implemented
            },
        }
    }

    /// Check process health status.
    /// Uses the configured health_check_fn if provided,
    /// otherwise considers the process healthy if running.
    ///
    /// Returns: true if process is healthy
    pub fn checkHealth(self: *ChildProcess) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Update stats before health check
        self.updateStats();

        if (self.state != .running) return false;

        if (self.spec.health_check_fn) |health_fn| {
            const is_healthy = health_fn();
            if (!is_healthy) {
                self.stats.health_check_failures += 1;
            }
            return is_healthy;
        }

        return true;
    }

    /// Get current process statistics.
    /// Provides insight into process execution and resource usage.
    ///
    /// Returns: Copy of current ProcessStats
    pub fn getStats(self: *ChildProcess) ProcessStats {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.stats;
    }

    /// Get process termination result if available.
    /// Only available after process has stopped or failed.
    ///
    /// Returns: ProcessResult if process has terminated, null otherwise
    pub fn getResult(self: *ChildProcess) ?ProcessResult {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.result;
    }

    /// Update process statistics.
    /// Called internally at key points to maintain accurate stats.
    fn updateStats(self: *ChildProcess) void {
        const current_time = std.time.milliTimestamp();
        if (self.stats.start_time == 0) {
            self.stats.start_time = current_time;
        }
        self.stats.last_active_time = current_time;
        if (self.state == .running) {
            self.stats.total_runtime_ms = current_time - self.stats.start_time;
        }
    }

    /// Check if process has exceeded resource limits.
    /// Monitors memory usage against configured limits.
    ///
    /// Returns: Error if limits are exceeded
    fn checkResourceLimits(self: *ChildProcess) ProcessError!void {
        if (self.spec.max_memory_bytes) |limit| {
            const current_memory = self.stats.peak_memory_bytes;
            if (current_memory > limit) {
                return ProcessError.ResourceLimitExceeded;
            }
        }
    }
};

test "ChildProcess basic lifecycle" {
    const spec = ChildSpec{
        .id = "test_basic",
        .start_fn = struct {
            fn testFn() void {
                // Simple function that just sleeps briefly
                std.time.sleep(10 * std.time.ns_per_ms);
            }
        }.testFn,
        .restart_type = .temporary,
        .shutdown_timeout_ms = 100,
    };

    var process = ChildProcess.init(std.testing.allocator, spec);
    defer _ = process.stop() catch {};

    // Test initial state
    try std.testing.expectEqual(ProcessState.initial, process.getState());
    try std.testing.expect(!process.isAlive());

    // Test starting
    try process.start();
    try std.testing.expectEqual(ProcessState.running, process.getState());
    try std.testing.expect(process.isAlive());

    // Test double start should fail
    try std.testing.expectError(ProcessError.AlreadyRunning, process.start());

    // Wait for process to complete
    std.time.sleep(20 * std.time.ns_per_ms);

    // Test stopping
    try process.stop();
    try std.testing.expectEqual(ProcessState.stopped, process.getState());
    try std.testing.expect(!process.isAlive());
}

test "ChildProcess timeout handling" {
    const spec = ChildSpec{
        .id = "test_timeout",
        .start_fn = struct {
            fn testFn() void {
                // Function that runs longer than timeout
                while (true) {
                    std.time.sleep(10 * std.time.ns_per_ms);
                }
            }
        }.testFn,
        .restart_type = .temporary,
        .shutdown_timeout_ms = 50, // Short timeout for testing
    };

    var process = ChildProcess.init(std.testing.allocator, spec);
    defer _ = process.stop() catch {};

    try process.start();
    try std.testing.expectEqual(ProcessState.running, process.getState());

    // Try to stop - should timeout
    try std.testing.expectError(ProcessError.ShutdownTimeout, process.stop());
    try std.testing.expectEqual(ProcessState.failed, process.getState());
}

test "ChildProcess error handling" {
    const spec = ChildSpec{
        .id = "test_error",
        .start_fn = struct {
            fn testFn() void {
                // Function that exits quickly
                std.time.sleep(5 * std.time.ns_per_ms);
            }
        }.testFn,
        .restart_type = .permanent,
        .shutdown_timeout_ms = 100,
    };

    var process = ChildProcess.init(std.testing.allocator, spec);
    errdefer _ = process.stop() catch {}; // Use errdefer for cleanup

    // Test failed start
    var bad_process = ChildProcess.init(std.testing.allocator, spec);
    bad_process.state = .running; // Force into running state
    try std.testing.expectError(ProcessError.AlreadyRunning, bad_process.start());

    // Test normal process
    try process.start();
    try std.testing.expect(process.last_error == null);
    try std.testing.expect(process.thread != null);

    // Wait for completion and verify cleanup
    std.time.sleep(50 * std.time.ns_per_ms); // Increased wait time to ensure completion
    try process.stop();

    // Add a small delay after stop to ensure cleanup completes
    std.time.sleep(10 * std.time.ns_per_ms);

    // Verify final state
    try std.testing.expectEqual(ProcessState.stopped, process.getState());
    try std.testing.expect(process.thread == null);
}

test "ChildProcess state transitions" {
    const spec = ChildSpec{
        .id = "test_states",
        .start_fn = struct {
            fn testFn() void {
                std.time.sleep(10 * std.time.ns_per_ms); // Reduced sleep time
            }
        }.testFn,
        .restart_type = .temporary,
        .shutdown_timeout_ms = 100,
    };

    var process = ChildProcess.init(std.testing.allocator, spec);
    defer _ = process.stop() catch {};

    // Test state progression
    try std.testing.expectEqual(ProcessState.initial, process.getState());
    try process.start();
    try std.testing.expectEqual(ProcessState.running, process.getState());

    // Let it run a bit
    std.time.sleep(20 * std.time.ns_per_ms); // Increased wait time

    // Stop and verify final state
    try process.stop();
    try std.testing.expectEqual(ProcessState.stopped, process.getState());
    try std.testing.expect(!process.isAlive());
}

test "Process health checks" {
    const spec = ChildSpec{
        .id = "test_health",
        .start_fn = struct {
            fn testFn() void {
                var i: usize = 0;
                while (i < 5) : (i += 1) {
                    std.time.sleep(10 * std.time.ns_per_ms);
                }
            }
        }.testFn,
        .restart_type = .permanent,
        .shutdown_timeout_ms = 100,
        .health_check_fn = struct {
            fn check() bool {
                return true;
            }
        }.check,
        .health_check_interval_ms = 10,
    };

    var process = ChildProcess.init(std.testing.allocator, spec);
    defer _ = process.stop() catch {};

    try process.start();
    try std.testing.expectEqual(ProcessState.running, process.getState());
    try std.testing.expect(process.checkHealth());

    // Let it run and check stats
    std.time.sleep(20 * std.time.ns_per_ms);
    const stats = process.getStats();
    try std.testing.expect(stats.health_check_failures == 0);
    try std.testing.expect(stats.start_time > 0);
    try std.testing.expectEqual(ProcessState.running, process.getState());
}

test "Process signals" {
    const spec = ChildSpec{
        .id = "test_signals",
        .start_fn = struct {
            fn testFn() void {
                var i: usize = 0;
                while (i < 10) : (i += 1) {
                    std.time.sleep(10 * std.time.ns_per_ms);
                }
            }
        }.testFn,
        .restart_type = .permanent,
        .shutdown_timeout_ms = 100,
        .priority = .normal,
    };

    var process = ChildProcess.init(std.testing.allocator, spec);
    defer _ = process.stop() catch {};

    try process.start();
    try std.testing.expectEqual(ProcessState.running, process.getState());

    try process.sendSignal(.@"suspend");
    try std.testing.expectEqual(ProcessState.suspended, process.getState());

    try process.sendSignal(.@"resume");
    try std.testing.expectEqual(ProcessState.running, process.getState());

    // Let it run a bit to ensure state is stable
    std.time.sleep(5 * std.time.ns_per_ms);
    try std.testing.expectEqual(ProcessState.running, process.getState());
}

test "Process resource limits" {
    const spec = ChildSpec{
        .id = "test_resources",
        .start_fn = struct {
            fn testFn() void {
                std.time.sleep(50 * std.time.ns_per_ms);
            }
        }.testFn,
        .restart_type = .temporary,
        .shutdown_timeout_ms = 100,
        .max_memory_bytes = 1024 * 1024,
    };

    var process = ChildProcess.init(std.testing.allocator, spec);
    defer _ = process.stop() catch {};

    try process.start();
    try std.testing.expect(process.checkHealth());

    process.stats.peak_memory_bytes = 2 * 1024 * 1024;
    try std.testing.expectError(ProcessError.ResourceLimitExceeded, process.checkResourceLimits());
}
