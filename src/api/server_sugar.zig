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
const compat = @import("../compat.zig");

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
        const Wrapper = @This();
        const Self = GenServer(StateType);

        pub const Handle = struct {
            ptr: *Self,
            thread: ?std.Thread,

            pub fn cast(self: *Handle, payload: []const u8) !void {
                try Wrapper.castPayload(self.ptr, payload);
            }

            pub fn call(self: *Handle, payload: []const u8, options: CallOptions) !Message {
                return try Wrapper.callPayload(self.ptr, payload, options);
            }

            pub fn stop(self: *Handle) void {
                self.ptr.stop();
            }

            pub fn join(self: *Handle) void {
                if (self.thread) |thread| {
                    thread.join();
                    self.thread = null;
                }
            }

            pub fn deinit(self: *Handle) void {
                self.stop();
                self.join();
                self.ptr.deinit();
            }
        };

        pub fn init(allocator: std.mem.Allocator, initial_state: StateType) !*Self {
            return try Self.init(
                allocator,
                Handlers.handle,
                Handlers.init,
                Handlers.terminate,
                initial_state,
            );
        }

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
