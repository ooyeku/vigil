//! Supervisor Tree Module
//!
//! This module provides hierarchical process supervision capabilities, allowing you to build
//! and manage complex supervision trees. It supports priority-based process management,
//! graceful shutdown handling, and comprehensive monitoring.
//!
//! Example:
//! ```zig
//!   const allocator = std.heap.page_allocator;
//!
//! Create root supervisor
//! const root_options = SupervisorOptions{ .strategy = .one_for_all };
//! const root_sup = Supervisor.init(allocator, root_options);
//!
//! Initialize supervision tree
//! var tree = try SupervisorTree.init(allocator, root_sup, "root", .{
//!     .max_depth = 3,
//!     .enable_monitoring = true,
//! });
//! defer tree.deinit();
//!
//! // Add child supervisors
//! try tree.addChild(Supervisor.init(allocator, .{ .strategy = .one_for_one }), "worker_sup");
//! try tree.start();
//! ```
const SupervisorTreeMod = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const vigil = @import("vigil.zig");
const Supervisor = vigil.Supervisor;
const Process = vigil.Process;
const ProcessState = vigil.ProcessState;

/// Comprehensive error set for supervisor tree operations.
/// These errors help identify and handle various failure scenarios
/// that may occur during tree management.
pub const SupervisorTreeError = error{
    /// Supervisor with specified name not found in the tree
    SupervisorNotFound,
    /// Invalid supervisor hierarchy (e.g., circular dependencies)
    InvalidHierarchy,
    /// Attempted to exceed configured maximum tree depth
    MaxDepthExceeded,
    /// Attempted to add supervisor with name that already exists
    DuplicateSupervisor,
    /// Detected circular dependency in supervisor relationships
    CircularDependency,
    /// Failed to complete shutdown within specified timeout
    ShutdownTimeout,
};

/// Configuration options for supervisor tree behavior.
/// Use this to customize how the supervision tree operates and
/// handles various scenarios.
///
/// Fields:
/// - max_depth: u8, // Maximum allowed depth of the supervision hierarchy
/// - enable_monitoring: bool, // Whether to enable automatic monitoring of all supervisors
/// - shutdown_timeout_ms: u32, // Default timeout for graceful shutdown operations in milliseconds
/// - propagate_signals: bool, // Whether signals should propagate up and down the tree
///
/// Example:
/// ```zig
/// const config = TreeConfig{
///     .max_depth = 5,
///     .enable_monitoring = true,
///     .shutdown_timeout_ms = 10_000, // 10 seconds
///     .propagate_signals = true,
/// };
/// ```
pub const TreeConfig = struct {
    /// Maximum allowed depth of the supervision hierarchy
    /// Prevents creation of overly deep trees that might be hard to manage
    max_depth: u8 = 5,

    /// Whether to enable automatic monitoring of all supervisors
    /// When enabled, collects statistics and health information
    enable_monitoring: bool = true,

    /// Default timeout for graceful shutdown operations in milliseconds
    /// Can be overridden in shutdown() calls
    shutdown_timeout_ms: u32 = 5000,

    /// Whether signals should propagate up and down the tree
    /// Useful for coordinated actions across the supervision hierarchy
    propagate_signals: bool = true,
};

/// Statistics collected for monitoring the supervision tree.
/// These metrics help track the health and performance of the
/// supervision hierarchy.
///
/// Fields:
/// - total_supervisors: usize, // Total number of supervisors in the tree
/// - total_processes: usize, // Total number of processes across all supervisors
/// - active_processes: usize, // Number of currently running processes
/// - failed_processes: usize, // Number of processes in failed state
/// - total_restarts: usize, // Total number of process restarts performed
/// - max_depth_reached: u8, // Maximum depth reached in the tree
/// - total_memory_bytes: usize, // Total memory usage of all processes
pub const TreeStats = struct {
    /// Total number of supervisors in the tree
    total_supervisors: usize = 0,
    /// Total number of processes across all supervisors
    total_processes: usize = 0,
    /// Number of currently running processes
    active_processes: usize = 0,
    /// Number of processes in failed state
    failed_processes: usize = 0,
    /// Total number of process restarts performed
    total_restarts: usize = 0,
    /// Maximum depth reached in the tree
    max_depth_reached: u8 = 0,
    /// Total memory usage of all processes
    total_memory_bytes: usize = 0,
};

/// Internal: Supervisor identifier for tracking in the tree.
/// Manages the lifecycle of supervisor names and ensures proper
/// memory management.
///
/// Fields:
/// - name: []const u8, // Unique name of the supervisor
/// - allocator: Allocator, // Memory allocator
///
/// Methods:
/// - init: fn (allocator: Allocator, name: []const u8) !SupervisorId
/// - deinit: fn (self: *SupervisorId) void
const SupervisorId = struct {
    /// Unique name of the supervisor
    name: []const u8,
    /// Allocator for memory management
    allocator: Allocator,

    /// Initialize a new supervisor identifier
    /// Caller must call deinit() when done
    pub fn init(allocator: Allocator, name: []const u8) !SupervisorId {
        const name_copy = try allocator.dupe(u8, name);
        return SupervisorId{
            .name = name_copy,
            .allocator = allocator,
        };
    }

    /// Free resources associated with the identifier
    pub fn deinit(self: *SupervisorId) void {
        self.allocator.free(self.name);
    }
};

/// Internal: Node in the supervisor tree containing a supervisor and its identifier.
/// Represents a single node in the supervision hierarchy.
///
/// Fields:
/// - supervisor: Supervisor, // The supervisor instance
/// - id: SupervisorId, // Identifier for the supervisor
const SupervisorNode = struct {
    /// The supervisor instance
    supervisor: Supervisor,
    /// Identifier for the supervisor
    id: SupervisorId,
};

/// Supervisor tree with hierarchical process management.
/// Provides a robust framework for building and managing complex
/// process supervision hierarchies with monitoring capabilities.
///
/// Key features:
/// - Hierarchical process supervision
/// - Priority-based process management
/// - Built-in monitoring and statistics
/// - Graceful shutdown handling
/// - Signal propagation
///
/// Fields:
/// - allocator: Allocator, // Memory allocator
/// - main: SupervisorNode, // Root supervisor node
/// - children: std.ArrayList(SupervisorNode), // List of child supervisor nodes
/// - config: TreeConfig, // Tree configuration options
/// - stats: TreeStats, // Runtime statistics
/// - mutex: std.Thread.Mutex, // Thread synchronization
///
/// Methods:
/// - init: fn (allocator: Allocator, main_supervisor: Supervisor, main_name: []const u8, config: TreeConfig) !SupervisorTree
/// - deinit: fn (self: *SupervisorTree) void
/// - addChild: fn (self: *SupervisorTree, supervisor: Supervisor, name: []const u8) !void
/// - start: fn (self: *SupervisorTree) !void
/// - shutdown: fn (self: *SupervisorTree, timeout_ms: ?u32) !void
/// - findSupervisor: fn (self: *SupervisorTree, name: []const u8) ?*Supervisor
/// - startMonitoring: fn (self: *SupervisorTree) !void
/// - getStats: fn (self: *SupervisorTree) TreeStats
/// - propagateSignal: fn (self: *SupervisorTree, signal: vigil.ProcessSignal) !void
///
/// Example usage:
/// ```zig
/// // Initialize tree with root supervisor
/// var tree = try SupervisorTree.init(allocator, root_sup, "root", .{});
/// defer tree.deinit();
///
/// // Add child supervisors
/// try tree.addChild(worker_sup, "workers");
/// try tree.addChild(task_sup, "tasks");
///
/// // Start the supervision tree
/// try tree.start();
///
/// // Monitor tree health
/// const stats = tree.getStats();
/// std.debug.print("Active processes: {d}\n", .{stats.active_processes});
///
/// // Graceful shutdown
/// try tree.shutdown(10_000); // 10 second timeout
/// ```
pub const SupervisorTree = struct {
    /// Memory allocator for the tree
    allocator: Allocator,
    /// Root supervisor node
    main: SupervisorNode,
    /// List of child supervisor nodes
    children: std.ArrayList(SupervisorNode),
    /// Tree configuration options
    config: TreeConfig,
    /// Runtime statistics
    stats: TreeStats,
    /// Thread synchronization
    mutex: std.Thread.Mutex,

    /// Initialize a new supervisor tree with the given root supervisor.
    /// The root supervisor forms the base of the supervision hierarchy.
    ///
    /// Parameters:
    /// - allocator: Memory allocator for the tree
    /// - main_supervisor: Root supervisor instance
    /// - main_name: Unique name for the root supervisor
    /// - config: Tree configuration options
    ///
    /// Returns: Initialized SupervisorTree or error
    /// Caller owns the returned tree and must call deinit()
    pub fn init(allocator: Allocator, main_supervisor: Supervisor, main_name: []const u8, config: TreeConfig) !SupervisorTree {
        var main_id = try SupervisorId.init(allocator, main_name);
        errdefer main_id.deinit();

        return SupervisorTree{
            .allocator = allocator,
            .main = .{
                .supervisor = main_supervisor,
                .id = main_id,
            },
            .children = std.ArrayList(SupervisorNode).init(allocator),
            .config = config,
            .stats = .{},
            .mutex = .{},
        };
    }

    /// Clean up resources used by the supervisor tree.
    /// This will properly clean up all supervisors, processes, and allocated memory.
    /// Must be called when the tree is no longer needed to prevent memory leaks.
    pub fn deinit(self: *SupervisorTree) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Cleanup child supervisors
        for (self.children.items) |*child| {
            child.supervisor.deinit();
            child.id.deinit();
        }
        self.children.deinit();

        // Cleanup main supervisor
        self.main.supervisor.deinit();
        self.main.id.deinit();
    }

    /// Add a child supervisor to the tree.
    /// The child supervisor will be managed as part of the supervision hierarchy.
    ///
    /// Parameters:
    /// - supervisor: The supervisor instance to add
    /// - name: Unique name for the supervisor
    ///
    /// Returns: void or error
    /// Possible errors:
    /// - MaxDepthExceeded: Tree depth limit reached
    /// - DuplicateSupervisor: Name already exists
    /// - OutOfMemory: Failed to allocate memory
    ///
    /// Example:
    /// ```zig
    /// const worker_sup = Supervisor.init(allocator, .{
    ///     .strategy = .one_for_one,
    ///     .max_restarts = 3,
    /// });
    /// try tree.addChild(worker_sup, "workers");
    /// ```
    pub fn addChild(self: *SupervisorTree, supervisor: Supervisor, name: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check depth limit
        if (self.stats.max_depth_reached >= self.config.max_depth) {
            return SupervisorTreeError.MaxDepthExceeded;
        }

        // Check for duplicates
        if (std.mem.eql(u8, self.main.id.name, name)) {
            return SupervisorTreeError.DuplicateSupervisor;
        }

        for (self.children.items) |child| {
            if (std.mem.eql(u8, child.id.name, name)) {
                return SupervisorTreeError.DuplicateSupervisor;
            }
        }

        var id = try SupervisorId.init(self.allocator, name);
        errdefer id.deinit();

        try self.children.append(.{
            .supervisor = supervisor,
            .id = id,
        });
        self.stats.total_supervisors += 1;
        self.stats.max_depth_reached += 1;
    }

    /// Start all supervisors in the tree.
    /// This will recursively start the main supervisor and all child supervisors,
    /// initializing the supervision hierarchy.
    ///
    /// If monitoring is enabled, it will also start collecting statistics
    /// and health information for all supervisors.
    ///
    /// Returns: void or error if any supervisor fails to start
    pub fn start(self: *SupervisorTree) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Start main supervisor
        try self.main.supervisor.start();

        // Start child supervisors
        for (self.children.items) |*child| {
            try child.supervisor.start();
        }

        // Start monitoring if enabled
        if (self.config.enable_monitoring) {
            try self.startMonitoring();
        }
    }

    /// Gracefully shutdown the entire supervision tree.
    /// Attempts to gracefully stop all processes and supervisors within
    /// the specified timeout period.
    ///
    /// Parameters:
    /// - timeout_ms: Optional timeout in milliseconds. If null, uses config default
    ///
    /// Returns: void or ShutdownTimeout if shutdown exceeds timeout
    ///
    /// Example:
    /// ```zig
    /// // Shutdown with 5 second timeout
    /// try tree.shutdown(5000);
    ///
    /// // Use default timeout from config
    /// try tree.shutdown(null);
    /// ```
    pub fn shutdown(self: *SupervisorTree, timeout_ms: u32) !void {
        const actual_timeout: u64 = @as(u64, timeout_ms);
        var timer = try std.time.Timer.start();

        // Convert timeout to nanoseconds safely using u64
        const timeout_ns: u64 = actual_timeout * @as(u64, std.time.ns_per_ms);

        self.mutex.lock();
        defer self.mutex.unlock();

        // Stop all child supervisors first
        for (self.children.items) |*child| {
            if (timer.read() > timeout_ns) {
                return error.ShutdownTimeout;
            }
            try child.supervisor.shutdown(timeout_ms);
        }

        // Then stop the main supervisor
        if (timer.read() > timeout_ns) {
            return error.ShutdownTimeout;
        }
        try self.main.supervisor.shutdown(timeout_ms);
    }

    /// Find a supervisor by name in the tree.
    /// Searches both the main supervisor and all child supervisors.
    ///
    /// Parameters:
    /// - name: Name of the supervisor to find
    ///
    /// Returns: Optional pointer to found supervisor
    /// Returns null if no supervisor with the given name exists
    ///
    /// Example:
    /// ```zig
    /// if (tree.findSupervisor("worker_sup")) |sup| {
    ///     try sup.restart();
    /// }
    /// ```
    pub fn findSupervisor(self: *SupervisorTree, name: []const u8) ?*Supervisor {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (std.mem.eql(u8, self.main.id.name, name)) {
            return &self.main.supervisor;
        }

        for (self.children.items) |*child| {
            if (std.mem.eql(u8, child.id.name, name)) {
                return &child.supervisor;
            }
        }

        return null;
    }

    /// Start monitoring the entire supervision tree.
    /// Initializes monitoring for all supervisors and begins collecting
    /// statistics and health information.
    ///
    /// This is automatically called by start() if monitoring is enabled
    /// in the configuration.
    ///
    /// Returns: void or error if monitoring setup fails
    pub fn startMonitoring(self: *SupervisorTree) !void {
        // Update tree-wide statistics
        self.stats.total_processes = self.main.supervisor.children.items.len;
        for (self.children.items) |child| {
            self.stats.total_processes += child.supervisor.children.items.len;
        }

        // Start monitoring threads for each supervisor
        try self.main.supervisor.startMonitoring();
        for (self.children.items) |*child| {
            try child.supervisor.startMonitoring();
        }
    }

    /// Get current statistics for the entire tree.
    /// Collects and aggregates statistics from all supervisors in the tree.
    ///
    /// Returns: TreeStats containing current metrics
    ///
    /// Example:
    /// ```zig
    /// const stats = tree.getStats();
    /// std.debug.print("Active: {d}, Failed: {d}\n", .{
    ///     stats.active_processes,
    ///     stats.failed_processes,
    /// });
    /// ```
    pub fn getStats(self: *SupervisorTree) TreeStats {
        self.mutex.lock();
        defer self.mutex.unlock();

        var stats = self.stats;
        stats.active_processes = 0;
        stats.failed_processes = 0;
        stats.total_restarts = 0;
        stats.total_memory_bytes = 0;

        // Collect stats from main supervisor
        const main_stats = self.main.supervisor.getStats();
        stats.active_processes += main_stats.active_children;
        stats.total_restarts += main_stats.total_restarts;

        // Collect stats from child supervisors
        for (self.children.items) |*child| {
            var sup = &child.supervisor;
            const child_stats = sup.getStats();
            stats.active_processes += child_stats.active_children;
            stats.total_restarts += child_stats.total_restarts;
        }

        return stats;
    }

    /// Propagate a signal through the supervision tree.
    /// Sends the specified signal to all processes in the tree if signal
    /// propagation is enabled in the configuration.
    ///
    /// Parameters:
    /// - signal: The process signal to propagate
    ///
    /// Returns: void or error if signal propagation fails
    ///
    /// Example:
    /// ```zig
    /// // Gracefully restart all processes
    /// try tree.propagateSignal(.restart);
    ///
    /// // Suspend all processes
    /// try tree.propagateSignal(.suspend);
    /// ```
    pub fn propagateSignal(self: *SupervisorTree, signal: vigil.ProcessSignal) !void {
        if (!self.config.propagate_signals) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        // Send signal to main supervisor's processes
        for (self.main.supervisor.children.items) |*process| {
            try process.sendSignal(signal);
        }

        // Send signal to child supervisors' processes
        for (self.children.items) |*child| {
            for (child.supervisor.children.items) |*process| {
                try process.sendSignal(signal);
            }
        }
    }
};

test "initialize supervisor tree" {
    const allocator = std.testing.allocator;
    const options = vigil.SupervisorOptions{
        .strategy = .one_for_one,
        .max_restarts = 3,
        .max_seconds = 5,
    };

    const supervisor_1 = Supervisor.init(allocator, options);
    const supervisor_2 = Supervisor.init(allocator, options);
    const supervisor_3 = Supervisor.init(allocator, options);

    var sup_tree = try SupervisorTree.init(allocator, supervisor_1, "main", .{
        .max_depth = 3,
        .enable_monitoring = true,
    });
    defer sup_tree.deinit();

    try sup_tree.addChild(supervisor_2, "child1");
    try sup_tree.addChild(supervisor_3, "child2");

    try std.testing.expect(sup_tree.children.items.len == 2);
    try std.testing.expect(sup_tree.stats.total_supervisors == 2);
}

test "supervisor tree depth limit" {
    const allocator = std.testing.allocator;
    const options = vigil.SupervisorOptions{
        .strategy = .one_for_one,
        .max_restarts = 3,
        .max_seconds = 5,
    };

    var sup_tree = try SupervisorTree.init(allocator, Supervisor.init(allocator, options), "main", .{
        .max_depth = 2,
        .enable_monitoring = true,
    });
    defer sup_tree.deinit();

    // Add supervisors up to depth limit
    try sup_tree.addChild(Supervisor.init(allocator, options), "child1");
    try sup_tree.addChild(Supervisor.init(allocator, options), "child2");

    // This should fail due to depth limit
    try std.testing.expectError(
        SupervisorTreeError.MaxDepthExceeded,
        sup_tree.addChild(Supervisor.init(allocator, options), "child3"),
    );
}

test "supervisor tree duplicate check" {
    const allocator = std.testing.allocator;
    const options = vigil.SupervisorOptions{
        .strategy = .one_for_one,
        .max_restarts = 3,
        .max_seconds = 5,
    };

    var sup_tree = try SupervisorTree.init(allocator, Supervisor.init(allocator, options), "main", .{});
    defer sup_tree.deinit();

    try sup_tree.addChild(Supervisor.init(allocator, options), "sup1");
    try std.testing.expectError(
        SupervisorTreeError.DuplicateSupervisor,
        sup_tree.addChild(Supervisor.init(allocator, options), "sup1"),
    );
}
