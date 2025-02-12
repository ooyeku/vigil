const std = @import("std");
const vigil = @import("vigil.zig");
const testing = @import("std").testing;

pub const GenServerState = enum {
    initial,
    running,
    stopped,
};

pub fn GenServer(comptime StateType: type) type {
    return struct {
        allocator: std.mem.Allocator,
        mailbox: *vigil.ProcessMailbox,
        state: StateType,
        handler: *const fn (self: *@This(), msg: vigil.Message) anyerror!void,
        init_fn: *const fn (self: *@This()) anyerror!void,
        terminate_fn: *const fn (self: *@This()) void,
        supervisor: ?*vigil.Supervisor = null,
        server_state: GenServerState = .initial,

        const Self = @This();

        /// Initialize a new GenServer
        pub fn init(
            allocator: std.mem.Allocator,
            handler: *const fn (self: *Self, msg: vigil.Message) anyerror!void,
            init_fn: *const fn (self: *Self) anyerror!void,
            terminate_fn: *const fn (self: *Self) void,
            state: StateType,
        ) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            self.* = .{
                .allocator = allocator,
                .mailbox = try vigil.createMailbox(allocator, .{
                    .capacity = 100,
                    .priority = .normal,
                    .default_ttl_ms = 5000,
                }),
                .state = state,
                .handler = handler,
                .init_fn = init_fn,
                .terminate_fn = terminate_fn,
            };

            return self;
        }

        /// Start the GenServer process
        pub fn start(self: *Self) !void {
            if (self.server_state != .initial) return error.AlreadyRunning;

            try self.init_fn(self);
            self.server_state = .running;

            while (self.server_state == .running) {
                if (self.mailbox.receive()) |msg_const| {
                    var msg = msg_const;
                    defer if (msg.metadata.correlation_id == null) {
                        msg.deinit();
                    };
                    try self.handler(self, msg);
                } else |err| switch (err) {
                    error.EmptyMailbox => {
                        std.time.sleep(1 * std.time.ns_per_ms);
                        continue;
                    },
                    else => return err,
                }
            }
        }

        /// Send an asynchronous message to the GenServer
        pub fn cast(self: *Self, msg: vigil.Message) !void {
            try self.mailbox.send(msg);
        }

        /// Send a synchronous message and wait for response
        pub fn call(self: *Self, msg: *vigil.Message, timeout_ms: ?u32) !vigil.Message {
            const correlation_id = try std.fmt.allocPrint(self.allocator, "call_{d}", .{std.time.milliTimestamp()});
            defer self.allocator.free(correlation_id);

            const mailbox_id = try std.fmt.allocPrint(self.allocator, "mailbox_{d}", .{std.time.milliTimestamp()});
            defer self.allocator.free(mailbox_id);

            var msg_copy = try msg.dupe();
            errdefer msg_copy.deinit();

            try msg_copy.setCorrelationId(correlation_id);
            try msg_copy.setReplyTo(mailbox_id);

            try self.cast(msg_copy);

            const start_time = std.time.milliTimestamp();
            while (true) {
                if (timeout_ms) |timeout| {
                    const elapsed = std.time.milliTimestamp() - start_time;
                    if (elapsed > timeout) return error.Timeout;
                }

                if (self.mailbox.receive()) |received_const| {
                    var received = received_const;

                    if (received.metadata.correlation_id) |id| {
                        if (std.mem.eql(u8, id, correlation_id)) {
                            return received;
                        }
                    }

                    received.deinit();
                } else |err| switch (err) {
                    error.EmptyMailbox => {
                        std.time.sleep(1 * std.time.ns_per_ms);
                        continue;
                    },
                    else => return err,
                }
            }
        }

        /// Stop the GenServer
        pub fn stop(self: *Self) void {
            self.server_state = .stopped;
            self.terminate_fn(self);
            // First deinit the mailbox contents
            self.mailbox.deinit();
            // Then destroy the mailbox struct itself since it was created with allocator.create()
            self.allocator.destroy(self.mailbox);
            // Finally destroy the GenServer itself
            self.allocator.destroy(self);
        }

        /// Register with a supervisor
        pub fn supervise(self: *Self, supervisor: *vigil.Supervisor, id: []const u8) !void {
            self.supervisor = supervisor;
            try supervisor.addChild(.{
                .id = id,
                .start_fn = startFn,
                .restart_type = .permanent,
                .shutdown_timeout_ms = 5000,
                .priority = .normal,
            });
        }

        fn startWrapper(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(ctx);
            _ = self.start() catch {};
        }

        fn startFn() void {
            // TODO: Need proper context passing
        }
    };
}

test "GenServer initialization" {
    const allocator = testing.allocator;

    const State = struct { count: u32 };
    const ServerType = GenServer(State);

    const state = State{ .count = 0 };

    const server = try ServerType.init(
        allocator,
        struct {
            fn handle(self: *ServerType, msg: vigil.Message) !void {
                _ = self;
                _ = msg;
            }
        }.handle,
        struct {
            fn init(self: *ServerType) !void {
                _ = self;
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

    try testing.expect(server.mailbox != undefined);
}

test "GenServer message handling" {
    const allocator = testing.allocator;

    const State = struct {
        count: u32,
        received: bool,
    };
    const ServerType = GenServer(State);

    const state = State{
        .count = 0,
        .received = false,
    };

    const server = try ServerType.init(
        allocator,
        struct {
            fn handle(self: *ServerType, msg: vigil.Message) !void {
                if (std.mem.eql(u8, msg.payload.?, "test")) {
                    self.state.received = true;
                    self.server_state = .stopped; // Stop after receiving the message
                }
            }
        }.handle,
        struct {
            fn init(self: *ServerType) !void {
                _ = self;
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

    // Create a copy of the message for the server
    var msg = try vigil.Message.init(allocator, "test_msg", "tester", "test", .info, .normal, 1000);
    const msg_copy = try vigil.Message.init(
        allocator,
        msg.id,
        msg.sender,
        msg.payload,
        msg.signal,
        msg.priority,
        msg.metadata.ttl_ms,
    );
    defer msg.deinit();

    try server.cast(msg_copy);

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *ServerType) void {
            s.start() catch {};
        }
    }.run, .{server});

    // Wait briefly for message processing
    std.time.sleep(100 * std.time.ns_per_ms);

    thread.join();

    try testing.expect(server.state.received);
}

// test "GenServer synchronous call" {
//     const allocator = testing.allocator;

//     const State = struct { count: u32 };
//     const ServerType = GenServer(State);

//     const state = State{ .count = 0 };

//     const server = try ServerType.init(
//         allocator,
//         struct {
//             fn handle(self: *ServerType, msg: vigil.Message) !void {
//                 if (std.mem.eql(u8, msg.payload.?, "ping")) {
//                     const response = try msg.createResponse(allocator, "pong", .info);
//                     try self.mailbox.send(response);
//                 }
//             }
//         }.handle,
//         struct {
//             fn init(self: *ServerType) !void {
//                 _ = self;
//             }
//         }.init,
//         struct {
//             fn terminate(self: *ServerType) void {
//                 _ = self;
//             }
//         }.terminate,
//         state,
//     );
//     defer server.stop();

//     // Start a thread for the server
//     const thread = try std.Thread.spawn(.{}, struct {
//         fn run(s: *ServerType) void {
//             s.start() catch {};
//         }
//     }.run, .{server});
//     defer thread.join();

//     var msg = try vigil.Message.init(allocator, "ping_msg", "tester", "ping", .info, .normal, 1000);
//     defer msg.deinit();

//     // Pass as pointer to avoid implicit copies
//     var response = try server.call(&msg);
//     defer response.deinit();

//     try testing.expect(std.mem.eql(u8, response.payload.?, "pong"));
// }

test "GenServer supervision" {
    const allocator = testing.allocator;

    const State = struct { count: u32 };
    const ServerType = GenServer(State);

    const state = State{ .count = 0 };

    const server = try ServerType.init(
        allocator,
        struct {
            fn handle(self: *ServerType, msg: vigil.Message) !void {
                _ = self;
                _ = msg;
            }
        }.handle,
        struct {
            fn init(self: *ServerType) !void {
                _ = self;
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

    const supervisor = try vigil.createSupervisor(allocator, .{
        .strategy = .one_for_one,
        .max_restarts = 3,
        .max_seconds = 5,
    });
    defer {
        supervisor.deinit();
        allocator.destroy(supervisor);
    }

    try server.supervise(supervisor, "test_gen_server");
    try testing.expect(server.supervisor != null);
}

test "GenServer state management" {
    const allocator = testing.allocator;

    const State = struct { count: u32 };
    const ServerType = GenServer(State);

    const state = State{ .count = 0 };

    const server = try ServerType.init(
        allocator,
        struct {
            fn handle(self: *ServerType, msg: vigil.Message) !void {
                if (std.mem.eql(u8, msg.payload.?, "increment")) {
                    self.state.count += 1;
                    self.server_state = .stopped; // Stop after incrementing
                }
            }
        }.handle,
        struct {
            fn init(self: *ServerType) !void {
                _ = self;
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

    const msg = try vigil.Message.init(allocator, "inc_msg", "tester", "increment", .info, .normal, 1000);
    try server.cast(msg);

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *ServerType) void {
            s.start() catch {};
        }
    }.run, .{server});

    // Wait briefly for message processing
    std.time.sleep(100 * std.time.ns_per_ms);

    thread.join();

    try testing.expect(server.state.count == 1);
}
