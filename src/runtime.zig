const std = @import("std");
const Registry = @import("registry.zig").Registry;
const telemetry = @import("telemetry.zig");
const shutdown_mod = @import("shutdown.zig");
const inbox_api = @import("api/inbox.zig");
const supervisor_builder = @import("api/supervisor_builder.zig");
const ProcessMailbox = @import("messages.zig").ProcessMailbox;

pub const RuntimeOptions = struct {
    telemetry_enabled: bool = true,
    shutdown_enabled: bool = true,
};

pub const InboxOptions = struct {
    capacity: usize = 100,
    priority_queues: bool = true,
    dead_letter: bool = true,
    default_ttl_ms: ?u32 = 30_000,
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    registry: Registry,
    telemetry_emitter: telemetry.TelemetryEmitter,
    shutdown_manager: shutdown_mod.ShutdownManager,
    options: RuntimeOptions,
    running: std.atomic.Value(bool),

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

    pub fn deinit(self: *Runtime) void {
        self.running.store(false, .release);
        self.shutdown_manager.deinit();
        self.telemetry_emitter.deinit();
        self.registry.deinit();
    }

    pub fn isRunning(self: *Runtime) bool {
        return self.running.load(.acquire);
    }

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

    pub fn supervisor(self: *Runtime) supervisor_builder.SupervisorBuilder {
        var builder = supervisor_builder.supervisor(self.allocator);
        return builder.withTelemetry(self.options.telemetry_enabled);
    }

    pub fn register(self: *Runtime, name: []const u8, mailbox: *ProcessMailbox) !void {
        try self.registry.register(name, mailbox);
    }

    pub fn whereis(self: *Runtime, name: []const u8) ?*ProcessMailbox {
        return self.registry.whereis(name);
    }

    pub fn onShutdown(self: *Runtime, hook: shutdown_mod.ShutdownHook) !void {
        try self.shutdown_manager.onShutdown(hook);
    }

    pub fn shutdown(self: *Runtime) void {
        self.running.store(false, .release);
        if (self.options.shutdown_enabled) {
            self.shutdown_manager.shutdown(.{});
        }
    }
};

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
