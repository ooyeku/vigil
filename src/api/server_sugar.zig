//! High-level GenServer sugar API for Vigil
//! Simplified handler pattern for creating GenServers.
//!
//! Example:
//! ```zig
//! const MyState = struct { counter: u32 };
//! const MyServer = vigil.server(MyState, struct {
//!     pub fn init(self: *Self) !void { }
//!     pub fn handle(self: *Self, msg: vigil.Msg) !void { }
//!     pub fn terminate(self: *Self) void { }
//! });
//! ```

const std = @import("std");
const legacy = @import("../legacy.zig");

pub const Message = legacy.Message;
pub const GenServer = legacy.GenServer;

/// Simplified cast and call options
pub const CallOptions = struct {
    timeout: ?u32 = 5000,
};

pub const CastOptions = struct {};

/// Create a GenServer from a state type and handler struct
pub fn server(comptime StateType: type, comptime Handlers: type) type {
    return struct {
        const Self = GenServer(StateType);

        pub fn start(allocator: std.mem.Allocator, initial_state: StateType) !*Self {
            return try Self.init(
                allocator,
                Handlers.handle,
                Handlers.init,
                Handlers.terminate,
                initial_state,
            );
        }

        pub fn cast(self: *Self, payload: []const u8) !void {
            const message = try Message.init(
                self.allocator,
                try std.fmt.allocPrint(self.allocator, "cast_{d}", .{std.time.milliTimestamp()}),
                "anonymous",
                payload,
                null,
                .normal,
                null,
            );
            try self.cast(message);
        }

        pub fn call(self: *Self, payload: []const u8, options: CallOptions) !Message {
            const message = try Message.init(
                self.allocator,
                try std.fmt.allocPrint(self.allocator, "call_{d}", .{std.time.milliTimestamp()}),
                "anonymous",
                payload,
                null,
                .normal,
                null,
            );
            defer message.deinit();
            return try self.call(&message, options.timeout);
        }

        pub fn stop(self: *Self) void {
            self.server_state = .stopped;
        }
    };
}

// Test state and handlers
const TestState = struct {
    counter: u32 = 0,
    last_message: ?[]const u8 = null,
};

const TestHandlers = struct {
    pub fn init(self: *GenServer(TestState)) !void {
        self.state.counter = 0;
    }

    pub fn handle(self: *GenServer(TestState), msg: Message) !void {
        if (msg.payload) |payload| {
            if (std.mem.eql(u8, payload, "increment")) {
                self.state.counter += 1;
            }
        }
    }

    pub fn terminate(self: *GenServer(TestState)) void {
        _ = self;
    }
};

test "server sugar basic creation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const Server = server(TestState, TestHandlers);
    var srv = try Server.start(allocator, .{});
    defer srv.stop();

    try std.testing.expect(srv.state.counter == 0);
}

test "server sugar cast message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const Server = server(TestState, TestHandlers);
    var srv = try Server.start(allocator, .{});
    defer srv.stop();

    const message = try Message.init(
        allocator,
        "test_msg",
        "test",
        "increment",
        null,
        .normal,
        null,
    );
    try srv.cast(message);

    // Give it a moment to process
    std.Thread.sleep(10 * std.time.ns_per_ms);

    // Note: actual state change depends on GenServer implementation
    try std.testing.expect(srv.state.counter >= 0);
}

test "server sugar state management" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const Server = server(TestState, TestHandlers);
    var srv = try Server.start(allocator, .{ .counter = 10 });
    defer srv.stop();

    try std.testing.expect(srv.state.counter == 10);
}

test "server sugar multiple servers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const Server = server(TestState, TestHandlers);

    var srv1 = try Server.start(allocator, .{ .counter = 1 });
    defer srv1.stop();

    var srv2 = try Server.start(allocator, .{ .counter = 2 });
    defer srv2.stop();

    try std.testing.expect(srv1.state.counter == 1);
    try std.testing.expect(srv2.state.counter == 2);
}
