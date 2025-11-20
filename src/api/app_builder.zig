//! High-level application builder API for Vigil 0.3.0+
//! Templates for common application patterns.
//!
//! Example:
//! ```zig
//! var app = try vigil.app(allocator)
//!     .worker("worker1", workerFn)
//!     .workerPool("pool", poolWorkerFn, 5)
//!     .preset(.production)
//!     .build();
//! defer app.shutdown();
//! try app.start();
//! ```

const std = @import("std");
const legacy = @import("../legacy.zig");
const presets = @import("./presets.zig");

pub const Supervisor = legacy.Supervisor;
pub const SupervisorOptions = legacy.SupervisorOptions;
pub const RestartStrategy = legacy.RestartStrategy;
pub const ChildSpec = legacy.ChildSpec;
pub const ProcessPriority = legacy.ProcessPriority;
pub const Preset = presets.Preset;
pub const PresetConfig = presets.PresetConfig;

/// Simple application builder
pub const AppBuilder = struct {
    allocator: std.mem.Allocator,
    supervisor: ?Supervisor = null,
    preset_config: PresetConfig,
    allocated_ids: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator, preset: Preset) !*AppBuilder {
        const app_builder = try allocator.create(AppBuilder);
        errdefer allocator.destroy(app_builder);

        const preset_config = PresetConfig.get(preset);

        app_builder.* = .{
            .allocator = allocator,
            .preset_config = preset_config,
            .allocated_ids = std.ArrayList([]const u8){},
        };

        return app_builder;
    }

    pub fn deinit(self: *AppBuilder) void {
        _ = self;
    }

    pub fn worker(self: *AppBuilder, id: []const u8, start_fn: *const fn () void) !*AppBuilder {
        if (self.supervisor == null) {
            self.supervisor = Supervisor.init(self.allocator, .{
                .strategy = .one_for_one,
                .max_restarts = self.preset_config.max_restarts,
                .max_seconds = self.preset_config.max_seconds,
            });
        }

        const id_copy = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(id_copy);
        try self.allocated_ids.append(self.allocator, id_copy);

        try self.supervisor.?.addChild(.{
            .id = id_copy,
            .start_fn = start_fn,
            .restart_type = .permanent,
            .shutdown_timeout_ms = self.preset_config.shutdown_timeout_ms,
            .priority = .normal,
            .max_memory_bytes = null,
            .health_check_fn = null,
            .health_check_interval_ms = self.preset_config.health_check_interval_ms,
        });
        return self;
    }

    pub fn workerPool(
        self: *AppBuilder,
        name_prefix: []const u8,
        start_fn: *const fn () void,
        count: usize,
    ) !*AppBuilder {
        if (self.supervisor == null) {
            self.supervisor = Supervisor.init(self.allocator, .{
                .strategy = .one_for_one,
                .max_restarts = self.preset_config.max_restarts,
                .max_seconds = self.preset_config.max_seconds,
            });
        }

        for (0..count) |i| {
            const worker_id = try std.fmt.allocPrint(
                self.allocator,
                "{s}_{d}",
                .{ name_prefix, i },
            );
            errdefer self.allocator.free(worker_id);
            try self.allocated_ids.append(self.allocator, worker_id);

            try self.supervisor.?.addChild(.{
                .id = worker_id,
                .start_fn = start_fn,
                .restart_type = .permanent,
                .shutdown_timeout_ms = self.preset_config.shutdown_timeout_ms,
                .priority = .normal,
                .max_memory_bytes = null,
                .health_check_fn = null,
                .health_check_interval_ms = self.preset_config.health_check_interval_ms,
            });
        }
        return self;
    }

    pub fn build(self: *AppBuilder) !void {
        if (self.supervisor == null) {
            self.supervisor = Supervisor.init(self.allocator, .{
                .strategy = .one_for_one,
                .max_restarts = self.preset_config.max_restarts,
                .max_seconds = self.preset_config.max_seconds,
            });
        }
    }

    pub fn start(self: *AppBuilder) !void {
        if (self.supervisor) |*sup| {
            try sup.start();
        }
    }

    pub fn stop(self: *AppBuilder) void {
        if (self.supervisor) |*sup| {
            sup.deinit();
        }
    }

    pub fn shutdown(self: *AppBuilder) void {
        if (self.supervisor) |*sup| {
            sup.shutdown(self.preset_config.shutdown_timeout_ms) catch {};
            sup.deinit();
        }

        // Free all allocated IDs
        for (self.allocated_ids.items) |id| {
            self.allocator.free(id);
        }
        self.allocated_ids.deinit(self.allocator);

        self.allocator.destroy(self);
    }
};

/// Create a new application builder with default preset
pub fn app(allocator: std.mem.Allocator) !*AppBuilder {
    return try AppBuilder.init(allocator, .production);
}

/// Create a new application builder with specific preset
pub fn appWithPreset(allocator: std.mem.Allocator, preset: Preset) !*AppBuilder {
    return try AppBuilder.init(allocator, preset);
}

fn testWorker() void {
    std.Thread.sleep(1 * std.time.ns_per_ms);
}

test "AppBuilder basic creation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var app_builder = try app(allocator);
    try app_builder.build();

    try std.testing.expect(app_builder.preset_config.max_restarts == 3); // production default
}

test "AppBuilder with preset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var app_builder = try appWithPreset(allocator, .development);
    try app_builder.build();

    try std.testing.expect(app_builder.preset_config.max_restarts == 10); // development default
}

test "AppBuilder add worker" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var app_builder = try app(allocator);
    _ = try app_builder.worker("worker1", testWorker);
    try app_builder.build();

    try std.testing.expect(app_builder.supervisor.?.children.items.len == 1);
}

test "AppBuilder add multiple workers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var app_builder = try app(allocator);
    _ = try app_builder.worker("worker1", testWorker);
    _ = try app_builder.worker("worker2", testWorker);
    _ = try app_builder.worker("worker3", testWorker);
    try app_builder.build();

    try std.testing.expect(app_builder.supervisor.?.children.items.len == 3);
}

test "AppBuilder worker pool" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var app_builder = try app(allocator);
    _ = try app_builder.workerPool("pool", testWorker, 5);
    try app_builder.build();

    try std.testing.expect(app_builder.supervisor.?.children.items.len == 5);
}

test "AppBuilder mixed workers and pools" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var app_builder = try app(allocator);
    _ = try app_builder.worker("single", testWorker);
    _ = try app_builder.workerPool("pool", testWorker, 3);
    try app_builder.build();

    try std.testing.expect(app_builder.supervisor.?.children.items.len == 4); // 1 + 3
}

test "AppBuilder all presets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const preset_list = [_]Preset{ .development, .production, .high_availability, .testing };
    for (preset_list) |preset| {
        var app_builder = try appWithPreset(allocator, preset);
        try app_builder.build();
        try std.testing.expect(app_builder.preset_config.max_restarts > 0);
    }
}

test "AppBuilder preset configurations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Development preset
    var dev_app = try appWithPreset(allocator, .development);
    try dev_app.build();
    try std.testing.expect(dev_app.preset_config.max_restarts == 10);
    try std.testing.expect(dev_app.preset_config.max_seconds == 5);

    // Production preset
    var prod_app = try appWithPreset(allocator, .production);
    try prod_app.build();
    try std.testing.expect(prod_app.preset_config.max_restarts == 3);
    try std.testing.expect(prod_app.preset_config.max_seconds == 60);

    // HA preset
    var ha_app = try appWithPreset(allocator, .high_availability);
    try ha_app.build();
    try std.testing.expect(ha_app.preset_config.max_restarts == 5);
    try std.testing.expect(ha_app.preset_config.max_seconds == 30);

    // Testing preset
    var test_app = try appWithPreset(allocator, .testing);
    try test_app.build();
    try std.testing.expect(test_app.preset_config.max_restarts == 1);
    try std.testing.expect(test_app.preset_config.max_seconds == 10);
}
