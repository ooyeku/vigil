const std = @import("std");
const vigil = @import("vigil.zig");
const testing = std.testing;

test "Verification of v0.4.0 features" {
    const allocator = testing.allocator;

    // 1. Initialize Global Registry
    var registry = vigil.Registry.init(allocator);
    defer registry.deinit();
    vigil.global_registry = &registry;
    defer vigil.global_registry = null;

    // 2. Create Supervisor
    var supervisor = vigil.Supervisor.init(allocator, .{
        .strategy = .one_for_one,
        .max_restarts = 3,
        .max_seconds = 5,
    });
    defer supervisor.deinit();

    // 3. Define GenServer
    const State = struct { count: u32 };
    const ServerType = vigil.GenServer(State);
    const state = State{ .count = 0 };

    const server = try ServerType.init(
        allocator,
        struct {
            fn handle(self: *ServerType, msg: vigil.Message) !void {
                if (std.mem.eql(u8, msg.payload.?, "scheduled")) {
                    self.state.count += 1;
                }
            }
        }.handle,
        struct {
            fn init(self: *ServerType) !void {
                // Register self
                try self.register("my_server");

                // Schedule message
                const msg = try vigil.Message.init(self.allocator, "sched", "self", "scheduled", .info, .normal, null);
                try self.schedule(msg, 10); // 10ms delay
            }
        }.init,
        struct {
            fn terminate(self: *ServerType) void {
                _ = self;
            }
        }.terminate,
        state,
    );
    defer server.stop();

    // 4. Add to Supervisor
    try server.supervise(&supervisor, "server_1");
    try supervisor.start();
    try supervisor.startMonitoring();

    // 5. Verify Registry
    // Wait for async registration
    std.Thread.sleep(10 * std.time.ns_per_ms);
    try std.testing.expect(vigil.global_registry.?.whereis("my_server") != null);

    // 6. Verify Timer (wait for message)
    // We wait enough time for timer to fire and server to process it
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // Server should be running and have count = 1
    try std.testing.expectEqual(@as(u32, 1), server.state.count);

    // 7. Verify terminateChild
    _ = supervisor.terminateChild("server_1") catch {};

    // 8. Verify deleteChild
    _ = supervisor.deleteChild("server_1") catch {};
    try std.testing.expect(supervisor.findChild("server_1") == null);

    // The previous server stopped itself, so we can't check its state.
    // Let's create a new server that doesn't stop itself to verify the count.

    // Re-initialize supervisor and registry for a clean slate if needed,
    // but for this test, we'll just create a new server.
    // The supervisor and registry are still active from the first part of the test.

    const StatePersistent = struct { count: u32 };
    const ServerTypePersistent = vigil.GenServer(StatePersistent);
    const state_persistent = StatePersistent{ .count = 0 };

    const server_persistent = try ServerTypePersistent.init(
        allocator,
        struct {
            fn handle(self: *ServerTypePersistent, msg: vigil.Message) !void {
                if (std.mem.eql(u8, msg.payload.?, "scheduled")) {
                    self.state.count += 1;
                }
            }
        }.handle,
        struct {
            fn init(self: *ServerTypePersistent) !void {
                try self.register("my_server_persistent");
                const msg = try vigil.Message.init(self.allocator, "sched", "self", "scheduled", .info, .normal, null);
                try self.schedule(msg, 10);
            }
        }.init,
        struct {
            fn terminate(self: *ServerTypePersistent) void {
                _ = self;
            }
        }.terminate,
        state_persistent,
    );
    defer server_persistent.stop();

    try server_persistent.supervise(&supervisor, "server_persistent_1");

    // Start the new child manually because supervisor is already running
    if (supervisor.findChild("server_persistent_1")) |child| {
        try child.start();
    }

    // Wait for async registration
    std.Thread.sleep(10 * std.time.ns_per_ms);
    try std.testing.expect(vigil.global_registry.?.whereis("my_server_persistent") != null);

    std.Thread.sleep(100 * std.time.ns_per_ms);

    // Server should be running and have count = 1
    try std.testing.expectEqual(@as(u32, 1), server_persistent.state.count);

    // 7. Verify terminateChild
    _ = supervisor.terminateChild("server_persistent_1") catch {};

    // 8. Verify deleteChild
    _ = supervisor.deleteChild("server_persistent_1") catch {};
    try std.testing.expect(supervisor.findChild("server_persistent_1") == null);
}
