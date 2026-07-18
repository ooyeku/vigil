//! High-level supervisor builder API for Vigil.
//!
//! Provides a fluent builder pattern for creating and configuring supervisors.
//!
//! Example:
//! ```zig
//! var sup = try vigil.supervisor(allocator)
//!     .strategy(.one_for_one)
//!     .child("worker1", workerFn)
//!     .child("worker2", workerFn)
//!     .build();
//! defer sup.stop();
//! try sup.start();
//! ```

const std = @import("std");
const telemetry = @import("../telemetry.zig");
const compat = @import("../compat.zig");
const supervisor_mod = @import("../supervisor.zig");
const process = @import("../process.zig");

pub const Supervisor = supervisor_mod.Supervisor;
pub const SupervisorOptions = supervisor_mod.SupervisorOptions;
pub const RestartStrategy = supervisor_mod.RestartStrategy;
pub const ChildSpec = process.ChildSpec;
pub const ProcessPriority = process.ProcessPriority;

/// Restart policy for a supervised child.
pub const RestartType = enum {
    /// Always restart the process when it terminates
    permanent,
    /// Restart only if the process terminates abnormally
    transient,
    /// Never restart the process
    temporary,
};

/// Options for one supervised child.
pub const ChildOptions = struct {
    /// Restart behavior after termination.
    restart_type: RestartType = .permanent,
    /// Time allowed for graceful shutdown.
    shutdown_timeout_ms: u32 = 5000,
    /// Child scheduling priority.
    priority: ProcessPriority = .normal,
    /// Optional memory ceiling checked by the lower-level process API.
    max_memory_bytes: ?usize = null,
    /// Optional health check function.
    health_check_fn: ?*const fn () bool = null,
    /// Interval between health checks.
    health_check_interval_ms: u32 = 1000,
};

/// Function called when a child crash is observed.
pub const CrashHandler = *const fn (child_id: []const u8) void;

/// Fluent builder for a `Supervisor`.
///
/// The builder owns no resources by itself, but the supervisor it constructs
/// owns copied child ids. Call `deinit()` on the built supervisor when finished.
pub const SupervisorBuilder = struct {
    /// Allocator used by the built supervisor.
    allocator: std.mem.Allocator,
    /// Restart strategy for the supervisor.
    strategy_val: RestartStrategy = .one_for_one,
    /// Max restarts in the restart window.
    max_restarts_val: u32 = 3,
    /// Restart accounting window in seconds.
    max_seconds_val: u32 = 5,
    /// Lazily-created supervisor while children are added.
    supervisor: ?Supervisor = null,
    /// Optional crash callback.
    crash_handler: ?CrashHandler = null,
    /// Whether built supervisors emit telemetry.
    enable_telemetry: bool = false,
    /// Optional emitter applied to built supervisors. Not owned.
    telemetry_emitter: ?*telemetry.TelemetryEmitter = null,

    /// Create a builder with default supervisor options.
    pub fn init(allocator: std.mem.Allocator) SupervisorBuilder {
        return .{
            .allocator = allocator,
        };
    }

    /// Set the restart strategy.
    pub fn strategy(self: SupervisorBuilder, s: RestartStrategy) SupervisorBuilder {
        var result = self;
        result.strategy_val = s;
        return result;
    }

    /// Set the maximum restarts allowed in the restart window.
    pub fn maxRestarts(self: SupervisorBuilder, count: u32) SupervisorBuilder {
        var result = self;
        result.max_restarts_val = count;
        return result;
    }

    /// Set the restart accounting window in seconds.
    pub fn maxSeconds(self: SupervisorBuilder, seconds: u32) SupervisorBuilder {
        var result = self;
        result.max_seconds_val = seconds;
        return result;
    }

    /// Add a permanent child with default child options.
    pub fn child(self: *SupervisorBuilder, id: []const u8, start_fn: *const fn () void) !*SupervisorBuilder {
        return self.childWithOptions(id, start_fn, .{});
    }

    /// Add a child with explicit options.
    ///
    /// The child id is copied into supervisor-owned memory.
    pub fn childWithOptions(
        self: *SupervisorBuilder,
        id: []const u8,
        start_fn: *const fn () void,
        options: ChildOptions,
    ) !*SupervisorBuilder {
        if (self.supervisor == null) {
            self.supervisor = Supervisor.init(self.allocator, .{
                .strategy = self.strategy_val,
                .max_restarts = self.max_restarts_val,
                .max_seconds = self.max_seconds_val,
                .crash_handler = self.crash_handler,
                .enable_telemetry = self.enable_telemetry,
            });
        }

        const id_copy = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(id_copy);

        // Track this allocation so it can be freed when the supervisor is deinitialized
        try self.supervisor.?.trackAllocatedChildId(id_copy);
        errdefer _ = self.supervisor.?.allocated_child_ids.pop();

        try self.supervisor.?.addChild(.{
            .id = id_copy,
            .start_fn = start_fn,
            .restart_type = @enumFromInt(@intFromEnum(options.restart_type)),
            .shutdown_timeout_ms = options.shutdown_timeout_ms,
            .priority = options.priority,
            .max_memory_bytes = options.max_memory_bytes,
            .health_check_fn = options.health_check_fn,
            .health_check_interval_ms = options.health_check_interval_ms,
        });
        return self;
    }

    /// Add `count` children named `{prefix}_{index}`.
    pub fn childPool(
        self: *SupervisorBuilder,
        prefix: []const u8,
        start_fn: *const fn () void,
        count: usize,
    ) !*SupervisorBuilder {
        for (0..count) |i| {
            const child_id = try std.fmt.allocPrint(self.allocator, "{s}_{d}", .{ prefix, i });
            defer self.allocator.free(child_id);
            _ = try self.child(child_id, start_fn);
        }
        return self;
    }

    /// Set or replace the crash handler.
    pub fn onCrash(self: *SupervisorBuilder, handler: CrashHandler) *SupervisorBuilder {
        self.crash_handler = handler;
        if (self.supervisor) |*sup| {
            sup.options.crash_handler = handler;
        }
        return self;
    }

    /// Enable or disable telemetry on the built supervisor.
    pub fn withTelemetry(self: *SupervisorBuilder, enabled: bool) SupervisorBuilder {
        var result = self.*;
        result.enable_telemetry = enabled;
        if (result.supervisor) |*sup| {
            sup.options.enable_telemetry = enabled;
        }
        return result;
    }

    /// Attach an emitter that built supervisors use for crash telemetry.
    ///
    /// The emitter is not owned and must outlive the built supervisor.
    pub fn withTelemetryEmitter(self: *SupervisorBuilder, emitter: ?*telemetry.TelemetryEmitter) SupervisorBuilder {
        var result = self.*;
        result.telemetry_emitter = emitter;
        if (result.supervisor) |*sup| {
            sup.telemetry_emitter = emitter;
        }
        return result;
    }

    /// Build the supervisor value.
    ///
    /// The returned supervisor is owned by the caller and should be
    /// deinitialized after use.
    pub fn build(self: *SupervisorBuilder) Supervisor {
        if (self.supervisor) |sup| {
            var result = sup;
            self.supervisor = null;
            result.options.crash_handler = self.crash_handler;
            result.options.enable_telemetry = self.enable_telemetry;
            result.telemetry_emitter = self.telemetry_emitter;
            return result;
        }
        var built = Supervisor.init(self.allocator, .{
            .strategy = self.strategy_val,
            .max_restarts = self.max_restarts_val,
            .max_seconds = self.max_seconds_val,
            .crash_handler = self.crash_handler,
            .enable_telemetry = self.enable_telemetry,
        });
        built.telemetry_emitter = self.telemetry_emitter;
        return built;
    }
};

/// Create a new supervisor builder.
pub fn supervisor(allocator: std.mem.Allocator) SupervisorBuilder {
    return SupervisorBuilder.init(allocator);
}

fn dummyWorker() void {
    compat.sleep(1 * std.time.ns_per_ms);
}

fn countCrash(_: []const u8) void {
    // Used to verify builder stores the callback pointer.
}

test "SupervisorBuilder basic creation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var builder = supervisor(allocator);
    const sup = builder.build();

    // Verify builder was created successfully with defaults
    try std.testing.expect(builder.strategy_val == .one_for_one);
    try std.testing.expect(builder.max_restarts_val == 3);
    try std.testing.expect(builder.max_seconds_val == 5);

    // Verify supervisor was created
    try std.testing.expect(sup.children.items.len == 0);
}

test "SupervisorBuilder duplicate child failure keeps tracked ids valid" {
    var builder = supervisor(std.testing.allocator);
    _ = try builder.child("duplicate", dummyWorker);
    try std.testing.expectError(error.AlreadyMonitoring, builder.child("duplicate", dummyWorker));

    var built = builder.build();
    built.deinit();
}

test "SupervisorBuilder transfers ownership when built" {
    var builder = supervisor(std.testing.allocator);
    _ = try builder.child("worker", dummyWorker);

    var first = builder.build();
    defer first.deinit();
    var second = builder.build();
    defer second.deinit();

    try std.testing.expectEqual(@as(usize, 1), first.children.items.len);
    try std.testing.expectEqual(@as(usize, 0), second.children.items.len);
}

test "SupervisorBuilder wires crash handler and telemetry options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var builder = supervisor(allocator);
    builder = builder.withTelemetry(true);
    _ = builder.onCrash(countCrash);
    _ = try builder.child("crashy", dummyWorker);
    var sup = builder.build();
    defer sup.deinit();

    try std.testing.expect(sup.options.crash_handler != null);
    try std.testing.expect(sup.options.enable_telemetry);
}

test "SupervisorBuilder add children" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var builder = supervisor(allocator);
    _ = try builder.child("worker1", dummyWorker);
    _ = try builder.child("worker2", dummyWorker);

    const sup = builder.build();
    try std.testing.expect(sup.children.items.len == 2);
}

test "SupervisorBuilder strategy modification" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var builder = supervisor(allocator);
    builder = builder.strategy(.one_for_all).maxRestarts(5).maxSeconds(30);

    try std.testing.expect(builder.strategy_val == .one_for_all);
    try std.testing.expect(builder.max_restarts_val == 5);
    try std.testing.expect(builder.max_seconds_val == 30);
}

test "SupervisorBuilder all strategies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const strategies = [_]RestartStrategy{ .one_for_one, .one_for_all, .rest_for_one };
    for (strategies) |strat| {
        var builder = supervisor(allocator);
        builder = builder.strategy(strat);
        try std.testing.expect(builder.strategy_val == strat);
    }
}

test "SupervisorBuilder multiple children with different names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var builder = supervisor(allocator);
    _ = try builder.child("worker_a", dummyWorker);
    _ = try builder.child("worker_b", dummyWorker);
    _ = try builder.child("worker_c", dummyWorker);

    const sup = builder.build();
    try std.testing.expect(sup.children.items.len == 3);
    try std.testing.expectEqualSlices(u8, "worker_a", sup.children.items[0].spec.id);
    try std.testing.expectEqualSlices(u8, "worker_b", sup.children.items[1].spec.id);
    try std.testing.expectEqualSlices(u8, "worker_c", sup.children.items[2].spec.id);
}

test "SupervisorBuilder with custom restart limits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var builder = supervisor(allocator);
    builder = builder.maxRestarts(10).maxSeconds(60);

    try std.testing.expect(builder.max_restarts_val == 10);
    try std.testing.expect(builder.max_seconds_val == 60);
}

test "SupervisorBuilder chaining all methods" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var builder = supervisor(allocator);
    builder = builder.strategy(.rest_for_one).maxRestarts(7).maxSeconds(45);
    _ = try builder.child("worker1", dummyWorker);
    _ = try builder.child("worker2", dummyWorker);

    const sup = builder.build();
    try std.testing.expect(builder.strategy_val == .rest_for_one);
    try std.testing.expect(builder.max_restarts_val == 7);
    try std.testing.expect(builder.max_seconds_val == 45);
    try std.testing.expect(sup.children.items.len == 2);
}
