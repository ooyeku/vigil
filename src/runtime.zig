const std = @import("std");
const Registry = @import("registry.zig").Registry;
const telemetry = @import("telemetry.zig");
const shutdown_mod = @import("shutdown.zig");
const inbox_api = @import("api/inbox.zig");
const supervisor_builder = @import("api/supervisor_builder.zig");
const ProcessMailbox = @import("messages.zig").ProcessMailbox;

/// Feature flags for an owned Vigil runtime.
///
/// A runtime always allocates the registry, telemetry emitter, and shutdown
/// manager fields. These options decide whether helper APIs actively use
/// telemetry and shutdown behavior.
pub const RuntimeOptions = struct {
    /// Enable telemetry-aware helper construction, such as supervisors created
    /// with `Runtime.supervisor()`.
    telemetry_enabled: bool = true,
    /// Run registered shutdown hooks when `Runtime.shutdown()` is called.
    shutdown_enabled: bool = true,
};

/// Default inbox settings used by `Runtime.inbox`.
pub const InboxOptions = struct {
    /// Maximum number of messages the underlying mailbox should hold.
    capacity: usize = 100,
    /// Enable mailbox priority ordering.
    priority_queues: bool = true,
    /// Enable dead-letter handling for messages that cannot be delivered.
    dead_letter: bool = true,
    /// Default time-to-live for messages created through this inbox.
    /// Set to null to create messages without a default TTL.
    default_ttl_ms: ?u32 = 30_000,
};

/// Owned v2 application runtime.
///
/// `Runtime` is the preferred entry point for new Vigil applications. It owns
/// a local process registry, telemetry emitter, and shutdown manager, which
/// makes it safe to create separate runtimes in tests or embedded services
/// without relying on process-wide globals.
///
/// Typical lifecycle:
/// ```zig
/// var rt = try vigil.runtime(allocator, .{});
/// defer rt.deinit();
///
/// var inbox = try rt.inbox(.{ .capacity = 64 });
/// defer inbox.close();
/// try rt.register("worker", inbox.mailbox);
/// ```
pub const Runtime = struct {
    /// Allocator used by runtime-owned services and helper factories.
    allocator: std.mem.Allocator,
    /// Local name registry for mapping names to raw mailboxes.
    registry: Registry,
    /// Per-runtime telemetry emitter. Prefer this over global telemetry in v2.
    telemetry_emitter: telemetry.TelemetryEmitter,
    /// Per-runtime shutdown hook manager.
    shutdown_manager: shutdown_mod.ShutdownManager,
    /// Feature flags captured at initialization.
    options: RuntimeOptions,
    /// True until `shutdown()` or `deinit()` is called.
    running: std.atomic.Value(bool),

    /// Initialize a runtime with owned services.
    ///
    /// The returned value is stored by value. Call `deinit()` once after all
    /// inboxes/supervisors created from the runtime have been closed or
    /// deinitialized.
    pub fn init(allocator: std.mem.Allocator, options: RuntimeOptions) !Runtime {
        return .{
            .allocator = allocator,
            .registry = Registry.init(allocator),
            .telemetry_emitter = telemetry.TelemetryEmitter.init(allocator),
            .shutdown_manager = shutdown_mod.ShutdownManager.init(allocator),
            .options = options,
            .running = std.atomic.Value(bool).init(true),
        };
    }

    /// Release services owned directly by the runtime.
    ///
    /// This does not close inboxes or stop supervisors created by helper
    /// methods; callers still own those returned values.
    pub fn deinit(self: *Runtime) void {
        self.running.store(false, .release);
        self.shutdown_manager.deinit();
        self.telemetry_emitter.deinit();
        self.registry.deinit();
    }

    /// Return whether the runtime has not been shut down or deinitialized.
    pub fn isRunning(self: *Runtime) bool {
        return self.running.load(.acquire);
    }

    /// Create a high-level inbox using the runtime allocator.
    ///
    /// The caller owns the returned pointer and must call `Inbox.close()`
    /// exactly once. The runtime does not automatically close created inboxes.
    pub fn inbox(self: *Runtime, options: InboxOptions) !*inbox_api.Inbox {
        var builder = inbox_api.inboxBuilder(self.allocator)
            .capacity(options.capacity)
            .priorityQueues(options.priority_queues)
            .deadLetter(options.dead_letter);

        if (options.default_ttl_ms) |ttl_ms| {
            builder = builder.defaultTTL(ttl_ms);
        } else {
            builder.default_ttl_ms_val = null;
        }

        return try builder.build();
    }

    /// Create a supervisor builder preconfigured from runtime options.
    ///
    /// The returned builder is a value. Build and deinitialize the resulting
    /// supervisor according to the supervisor API.
    pub fn supervisor(self: *Runtime) supervisor_builder.SupervisorBuilder {
        var builder = supervisor_builder.supervisor(self.allocator);
        return builder.withTelemetry(self.options.telemetry_enabled);
    }

    /// Register a raw mailbox under a local name.
    ///
    /// Names are copied into the registry. The mailbox itself is not owned by
    /// the registry and must outlive any lookups that use it.
    pub fn register(self: *Runtime, name: []const u8, mailbox: *ProcessMailbox) !void {
        try self.registry.register(name, mailbox);
    }

    /// Look up a local mailbox by name, or null when no entry exists.
    pub fn whereis(self: *Runtime, name: []const u8) ?*ProcessMailbox {
        return self.registry.whereis(name);
    }

    /// Register a function to run during `shutdown()`.
    ///
    /// Hooks must not capture stack references; they are plain function
    /// pointers and may run later during shutdown.
    pub fn onShutdown(self: *Runtime, hook: shutdown_mod.ShutdownHook) !void {
        try self.shutdown_manager.onShutdown(hook);
    }

    /// Mark the runtime as stopped and run shutdown hooks when enabled.
    ///
    /// This is intentionally separate from `deinit()`: call `shutdown()` to
    /// notify the application, then `deinit()` to release runtime resources.
    pub fn shutdown(self: *Runtime) void {
        self.running.store(false, .release);
        if (self.options.shutdown_enabled) {
            self.shutdown_manager.shutdown(.{});
        }
    }
};

/// Convenience constructor for an owned runtime.
pub fn runtime(allocator: std.mem.Allocator, options: RuntimeOptions) !Runtime {
    return Runtime.init(allocator, options);
}

var runtime_shutdown_count = std.atomic.Value(u32).init(0);

fn recordRuntimeShutdown() void {
    _ = runtime_shutdown_count.fetchAdd(1, .monotonic);
}

test "Runtime initializes owned services" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    try std.testing.expect(rt.isRunning());
    try std.testing.expect(rt.whereis("missing") == null);
}

test "Runtime creates and closes inboxes" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var ib = try rt.inbox(.{ .capacity = 4 });
    defer ib.close();

    try ib.send("hello");
    var msg = try ib.recvTimeout(50) orelse return error.ExpectedMessage;
    defer msg.deinit();
    try std.testing.expectEqualStrings("hello", msg.payload.?);
}

test "Runtime registers and resolves owned mailboxes" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var ib = try rt.inbox(.{ .capacity = 4 });
    defer ib.close();

    try rt.register("worker.inbox", ib.mailbox);
    try std.testing.expect(rt.whereis("worker.inbox") == ib.mailbox);
    try std.testing.expect(rt.whereis("missing") == null);
}

test "Runtime supervisor builder inherits telemetry option" {
    var rt_enabled = try Runtime.init(std.testing.allocator, .{ .telemetry_enabled = true });
    defer rt_enabled.deinit();
    var enabled_builder = rt_enabled.supervisor();
    var enabled_sup = enabled_builder.build();
    defer enabled_sup.deinit();
    try std.testing.expect(enabled_sup.options.enable_telemetry);

    var rt_disabled = try Runtime.init(std.testing.allocator, .{ .telemetry_enabled = false });
    defer rt_disabled.deinit();
    var disabled_builder = rt_disabled.supervisor();
    var disabled_sup = disabled_builder.build();
    defer disabled_sup.deinit();
    try std.testing.expect(!disabled_sup.options.enable_telemetry);
}

test "Runtime shutdown honors shutdown_enabled option" {
    runtime_shutdown_count.store(0, .release);

    var enabled = try Runtime.init(std.testing.allocator, .{ .shutdown_enabled = true });
    defer enabled.deinit();
    try enabled.onShutdown(recordRuntimeShutdown);
    enabled.shutdown();
    try std.testing.expect(!enabled.isRunning());
    try std.testing.expectEqual(@as(u32, 1), runtime_shutdown_count.load(.acquire));

    var disabled = try Runtime.init(std.testing.allocator, .{ .shutdown_enabled = false });
    defer disabled.deinit();
    try disabled.onShutdown(recordRuntimeShutdown);
    disabled.shutdown();
    try std.testing.expect(!disabled.isRunning());
    try std.testing.expectEqual(@as(u32, 1), runtime_shutdown_count.load(.acquire));
}
