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
        return supervisor_builder
            .supervisor(self.allocator)
            .withTelemetry(self.options.telemetry_enabled);
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
