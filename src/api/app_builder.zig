//! High-level application builder API for Vigil.
//!
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
const compat = @import("../compat.zig");
const supervisor_mod = @import("../supervisor.zig");
const process = @import("../process.zig");
const presets = @import("./presets.zig");

pub const Supervisor = supervisor_mod.Supervisor;
pub const SupervisorOptions = supervisor_mod.SupervisorOptions;
pub const RestartStrategy = supervisor_mod.RestartStrategy;
pub const ChildSpec = process.ChildSpec;
pub const ProcessPriority = process.ProcessPriority;
pub const Preset = presets.Preset;
pub const PresetConfig = presets.PresetConfig;

/// Builder for a simple supervised worker application.
///
/// `AppBuilder` is heap-allocated by `app()` and `appWithPreset()`. Call
/// `shutdown()` when finished; it stops/deinitializes the supervisor, frees
/// copied worker ids, and destroys the builder itself.
pub const AppBuilder = struct {
    /// Allocator used for the builder, worker ids, and supervisor internals.
    allocator: std.mem.Allocator,
    /// Lazily-created supervisor.
    supervisor: ?Supervisor = null,
    /// Concrete settings selected from the chosen preset.
    preset_config: PresetConfig,
    /// Worker ids allocated by the app builder.
    allocated_ids: std.ArrayList([]const u8),

    /// Allocate a new app builder for `preset`.
    pub fn init(allocator: std.mem.Allocator, preset: Preset) !*AppBuilder {
        const app_builder = try allocator.create(AppBuilder);
        errdefer allocator.destroy(app_builder);

        const preset_config = PresetConfig.get(preset);

        app_builder.* = .{
            .allocator = allocator,
            .preset_config = preset_config,
            .allocated_ids = .empty,
        };

        return app_builder;
    }

    /// Add one permanent worker child.
    ///
    /// The id is copied and later freed by `shutdown()`.
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
        errdefer _ = self.allocated_ids.pop();

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

    /// Add `count` workers named `{name_prefix}_{index}`.
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
            errdefer _ = self.allocated_ids.pop();

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

    /// Ensure the underlying supervisor has been created.
    pub fn build(self: *AppBuilder) !void {
        if (self.supervisor == null) {
            self.supervisor = Supervisor.init(self.allocator, .{
                .strategy = .one_for_one,
                .max_restarts = self.preset_config.max_restarts,
                .max_seconds = self.preset_config.max_seconds,
            });
        }
    }

    /// Start the underlying supervisor if present.
    pub fn start(self: *AppBuilder) !void {
        if (self.supervisor) |*sup| {
            try sup.start();
        }
    }

    /// Deinitialize the underlying supervisor without destroying the builder.
    ///
    /// Most applications should call `shutdown()` instead.
    pub fn stop(self: *AppBuilder) void {
        if (self.supervisor) |*sup| {
            sup.deinit();
            self.supervisor = null;
        }
    }

    /// Shut down the application and destroy the builder.
    ///
    /// After this call, the `AppBuilder` pointer is invalid.
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

/// Create an application builder using the production preset.
pub fn app(allocator: std.mem.Allocator) !*AppBuilder {
    return try AppBuilder.init(allocator, .production);
}

/// Create an application builder using an explicit preset.
pub fn appWithPreset(allocator: std.mem.Allocator, preset: Preset) !*AppBuilder {
    return try AppBuilder.init(allocator, preset);
}

fn testWorker() void {
    compat.sleep(1 * std.time.ns_per_ms);
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

test "AppBuilder duplicate worker failure keeps cleanup ownership valid" {
    var app_builder = try app(std.testing.allocator);
    _ = try app_builder.worker("duplicate", testWorker);
    try std.testing.expectError(error.AlreadyMonitoring, app_builder.worker("duplicate", testWorker));
    app_builder.shutdown();
}

test "AppBuilder stop can be followed by shutdown" {
    var app_builder = try app(std.testing.allocator);
    _ = try app_builder.worker("worker", testWorker);
    app_builder.stop();
    app_builder.shutdown();
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
