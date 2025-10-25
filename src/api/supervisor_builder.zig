//! High-level supervisor builder API for Vigil 0.3.0+
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
const legacy = @import("../legacy.zig");

pub const Supervisor = legacy.Supervisor;
pub const SupervisorOptions = legacy.SupervisorOptions;
pub const RestartStrategy = legacy.RestartStrategy;
pub const ChildSpec = legacy.ChildSpec;
pub const ProcessPriority = legacy.ProcessPriority;

/// High-level supervisor builder
pub const SupervisorBuilder = struct {
    allocator: std.mem.Allocator,
    strategy_val: RestartStrategy = .one_for_one,
    max_restarts_val: u32 = 3,
    max_seconds_val: u32 = 5,
    supervisor: ?Supervisor = null,

    pub fn init(allocator: std.mem.Allocator) SupervisorBuilder {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SupervisorBuilder) void {
        _ = self;
    }

    pub fn strategy(self: SupervisorBuilder, s: RestartStrategy) SupervisorBuilder {
        var result = self;
        result.strategy_val = s;
        return result;
    }

    pub fn maxRestarts(self: SupervisorBuilder, count: u32) SupervisorBuilder {
        var result = self;
        result.max_restarts_val = count;
        return result;
    }

    pub fn maxSeconds(self: SupervisorBuilder, seconds: u32) SupervisorBuilder {
        var result = self;
        result.max_seconds_val = seconds;
        return result;
    }

    pub fn child(self: *SupervisorBuilder, id: []const u8, start_fn: *const fn () void) !*SupervisorBuilder {
        if (self.supervisor == null) {
            self.supervisor = Supervisor.init(self.allocator, .{
                .strategy = self.strategy_val,
                .max_restarts = self.max_restarts_val,
                .max_seconds = self.max_seconds_val,
            });
        }

        const id_copy = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(id_copy);

        try self.supervisor.?.addChild(.{
            .id = id_copy,
            .start_fn = start_fn,
            .restart_type = .permanent,
            .shutdown_timeout_ms = 5000,
            .priority = .normal,
            .max_memory_bytes = null,
            .health_check_fn = null,
            .health_check_interval_ms = 1000,
        });
        return self;
    }

    pub fn build(self: SupervisorBuilder) Supervisor {
        if (self.supervisor) |sup| {
            return sup;
        }
        return Supervisor.init(self.allocator, .{
            .strategy = self.strategy_val,
            .max_restarts = self.max_restarts_val,
            .max_seconds = self.max_seconds_val,
        });
    }
};

/// Create a new supervisor builder
pub fn supervisor(allocator: std.mem.Allocator) SupervisorBuilder {
    return SupervisorBuilder.init(allocator);
}

fn dummyWorker() void {
    std.Thread.sleep(1 * std.time.ns_per_ms);
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
