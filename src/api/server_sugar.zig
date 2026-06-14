//! High-level GenServer sugar API for Vigil.
//!
//! Simplified handler pattern for creating GenServers.
//!
//! Example:
//! ```zig
//! const MyState = struct { counter: u32 };
//! const MyServer = vigil.server(MyState, struct {
//!     pub fn init(_: *vigil.GenServer(MyState)) !void {}
//!     pub fn handle(_: *vigil.GenServer(MyState), _: vigil.Message) !void {}
//!     pub fn terminate(_: *vigil.GenServer(MyState)) void {}
//! });
//! ```

const std = @import("std");
const legacy = @import("../legacy.zig");
const compat = @import("../compat.zig");

pub const Message = legacy.Message;
pub const GenServer = legacy.GenServer;

/// Options for synchronous `call` requests.
pub const CallOptions = struct {
    /// Optional timeout in milliseconds.
    timeout: ?u32 = 5000,
};

/// Options for asynchronous `cast` requests.
pub const CastOptions = struct {};

/// Generate a typed GenServer wrapper from state and handlers.
///
/// `Handlers` must provide functions compatible with the lower-level
/// `GenServer(StateType)` callbacks:
/// - `init(*GenServer(StateType)) !void`
/// - `handle(*GenServer(StateType), Message) !void`
/// - `terminate(*GenServer(StateType)) void`
pub fn server(comptime StateType: type, comptime Handlers: type) type {
    return struct {
        const Wrapper = @This();
        const Self = GenServer(StateType);

        /// Running server handle returned by `spawn`.
        ///
        /// Call `deinit()` to stop, join, and release the underlying server.
        pub const Handle = struct {
            /// Underlying GenServer pointer.
            ptr: *Self,
            /// Worker thread running `GenServer.start`.
            thread: ?std.Thread,

            /// Send an asynchronous payload message.
            pub fn cast(self: *Handle, payload: []const u8) !void {
                try Wrapper.castPayload(self.ptr, payload);
            }

            /// Send a synchronous payload request.
            pub fn call(self: *Handle, payload: []const u8, options: CallOptions) !Message {
                return try Wrapper.callPayload(self.ptr, payload, options);
            }

            /// Request server stop.
            pub fn stop(self: *Handle) void {
                self.ptr.stop();
            }

            /// Join the server thread if it is still running.
            pub fn join(self: *Handle) void {
                if (self.thread) |thread| {
                    thread.join();
                    self.thread = null;
                }
            }

            /// Stop, join, and deinitialize the server.
            pub fn deinit(self: *Handle) void {
                self.stop();
                self.join();
                self.ptr.deinit();
            }
        };

        /// Allocate and initialize the underlying GenServer.
        pub fn init(allocator: std.mem.Allocator, initial_state: StateType) !*Self {
            return try Self.init(
                allocator,
                Handlers.handle,
                Handlers.init,
                Handlers.terminate,
                initial_state,
            );
        }

        /// Allocate, initialize, and start the GenServer in a new thread.
        pub fn spawn(allocator: std.mem.Allocator, initial_state: StateType) !Handle {
            const ptr = try init(allocator, initial_state);
            errdefer ptr.deinit();

            const thread = try std.Thread.spawn(.{}, struct {
                fn run(s: *Self) void {
                    s.start() catch {};
                }
            }.run, .{ptr});

            return .{
                .ptr = ptr,
                .thread = thread,
            };
        }

        /// Send an asynchronous payload to an initialized server.
        pub fn castPayload(self: *Self, payload: []const u8) !void {
            const id = try std.fmt.allocPrint(self.allocator, "cast_{d}", .{compat.milliTimestamp()});
            defer self.allocator.free(id);

            var message = try Message.init(
                self.allocator,
                id,
                "anonymous",
                payload,
                null,
                .normal,
                null,
            );
            errdefer message.deinit();

            try self.cast(message);
        }

        /// Send a synchronous payload request to an initialized server.
        pub fn callPayload(self: *Self, payload: []const u8, options: CallOptions) !Message {
            const id = try std.fmt.allocPrint(self.allocator, "call_{d}", .{compat.milliTimestamp()});
            defer self.allocator.free(id);

            var message = try Message.init(
                self.allocator,
                id,
                "anonymous",
                payload,
                null,
                .normal,
                null,
            );
            defer message.deinit();
            return try self.call(&message, options.timeout);
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

const CallState = struct {};

const CallHandlers = struct {
    pub fn init(self: *GenServer(CallState)) !void {
        _ = self;
    }

    pub fn handle(self: *GenServer(CallState), msg: Message) !void {
        if (msg.payload) |payload| {
            if (std.mem.eql(u8, payload, "ping")) {
                try self.reply(msg, "pong");
            }
        }
    }

    pub fn terminate(self: *GenServer(CallState)) void {
        _ = self;
    }
};

test "server sugar basic creation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const Server = server(TestState, TestHandlers);
    var srv = try Server.init(allocator, .{});
    defer srv.deinit();

    try std.testing.expect(srv.state.counter == 0);
}

test "server sugar spawn runs message loop and joins cleanly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const Server = server(TestState, TestHandlers);
    var handle = try Server.spawn(allocator, .{});
    defer handle.deinit();

    try handle.cast("increment");
    compat.sleep(20 * std.time.ns_per_ms);

    try std.testing.expectEqual(@as(u32, 1), handle.ptr.state.counter);

    handle.stop();
    handle.join();
}

test "server sugar call waits for handler reply" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const Server = server(CallState, CallHandlers);
    var handle = try Server.spawn(allocator, .{});
    defer handle.deinit();

    compat.sleep(10 * std.time.ns_per_ms);

    var response = try handle.call("ping", .{ .timeout = 500 });
    defer response.deinit();

    try std.testing.expectEqualStrings("pong", response.payload.?);
}

test "server sugar state management" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const Server = server(TestState, TestHandlers);
    var srv = try Server.init(allocator, .{ .counter = 10 });
    defer srv.deinit();

    try std.testing.expect(srv.state.counter == 10);
}

test "server sugar multiple servers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const Server = server(TestState, TestHandlers);

    var srv1 = try Server.init(allocator, .{ .counter = 1 });
    defer srv1.deinit();

    var srv2 = try Server.init(allocator, .{ .counter = 2 });
    defer srv2.deinit();

    try std.testing.expect(srv1.state.counter == 1);
    try std.testing.expect(srv2.state.counter == 2);
}
