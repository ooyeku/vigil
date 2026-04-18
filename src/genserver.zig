const std = @import("std");
const vigil = @import("vigil.zig");
const checkpoint_mod = @import("checkpoint.zig");
const compat = @import("compat.zig");
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

        /// Thread-safe map of correlation_id -> reply mailbox for the call/reply pattern.
        reply_mailboxes: std.StringHashMap(*vigil.ProcessMailbox),
        reply_mutex: compat.Mutex = .{},

        /// Optional state checkpointing
        checkpointer: ?checkpoint_mod.Checkpointer = null,
        checkpoint_id: ?[]const u8 = null,
        checkpoint_interval_ms: u32 = 30_000,
        checkpoint_fns: ?CheckpointFns = null,
        last_checkpoint_ms: i64 = 0,

        const Self = @This();

        /// Thread-safe storage for passing context to supervised start functions.
        pub var current_context: std.atomic.Value(?*anyopaque) = std.atomic.Value(?*anyopaque).init(null);

        /// Serialization/deserialization callbacks for state checkpointing.
        pub const CheckpointFns = struct {
            serialize: *const fn (state: *const StateType, allocator: std.mem.Allocator) anyerror![]u8,
            deserialize: *const fn (data: []const u8, allocator: std.mem.Allocator) anyerror!StateType,
        };

        /// Initialize a new GenServer.
        /// Caller must call deinit() when done (after stop() + thread join).
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
                .reply_mailboxes = std.StringHashMap(*vigil.ProcessMailbox).init(allocator),
            };

            return self;
        }

        /// Free all resources. Call after stop() and after the server thread has joined.
        pub fn deinit(self: *Self) void {
            self.cleanupReplyMailboxes();
            if (self.checkpoint_id) |id| {
                self.allocator.free(id);
            }
            self.mailbox.deinit();
            self.allocator.destroy(self.mailbox);
            self.allocator.destroy(self);
        }

        /// Start the GenServer message loop (blocks until stopped).
        pub fn start(self: *Self) !void {
            if (self.server_state != .initial) return error.AlreadyRunning;

            try self.init_fn(self);
            self.server_state = .running;
            self.last_checkpoint_ms = compat.milliTimestamp();

            while (self.server_state == .running) {
                if (self.mailbox.receive()) |msg_const| {
                    var msg = msg_const;

                    if (self.server_state != .running or (msg.signal != null and msg.signal.? == .terminate)) {
                        msg.deinit();
                        break;
                    }

                    defer msg.deinit();
                    try self.handler(self, msg);

                    self.maybeCheckpoint();
                } else |err| switch (err) {
                    error.EmptyMailbox => {
                        compat.sleep(1 * std.time.ns_per_ms);
                        continue;
                    },
                    else => return err,
                }
            }

            // Save final checkpoint before terminating
            self.saveCheckpoint();
            self.terminate_fn(self);
            self.server_state = .stopped;
        }

        /// Send an asynchronous message to the GenServer
        pub fn cast(self: *Self, msg: vigil.Message) !void {
            try self.mailbox.send(msg);
        }

        /// Send a synchronous message and wait for response.
        /// The handler must call self.reply(msg, payload) to send a response
        /// back to the caller's dedicated reply mailbox.
        pub fn call(self: *Self, msg: *vigil.Message, timeout_ms: ?u32) !vigil.Message {
            const correlation_id = try std.fmt.allocPrint(self.allocator, "call_{d}", .{compat.milliTimestamp()});
            errdefer self.allocator.free(correlation_id);

            // Create a temporary reply mailbox dedicated to this call
            const reply_mbx = try self.allocator.create(vigil.ProcessMailbox);
            errdefer self.allocator.destroy(reply_mbx);
            reply_mbx.* = vigil.ProcessMailbox.init(self.allocator, .{
                .capacity = 1,
                .priority_queues = false,
                .enable_deadletter = false,
            });

            // Store mapping so reply() on the server thread can find it
            {
                self.reply_mutex.lock();
                defer self.reply_mutex.unlock();
                try self.reply_mailboxes.put(correlation_id, reply_mbx);
            }

            // Prepare and send message with correlation ID
            var msg_copy = try msg.dupe();
            errdefer msg_copy.deinit();
            try msg_copy.setCorrelationId(correlation_id);
            try self.cast(msg_copy);

            // Wait on the dedicated reply mailbox (not the server's mailbox)
            const start_time = compat.milliTimestamp();
            while (true) {
                if (timeout_ms) |timeout| {
                    if (compat.milliTimestamp() - start_time > timeout) {
                        self.cleanupReplyEntry(correlation_id);
                        return error.Timeout;
                    }
                }

                if (reply_mbx.receive()) |response| {
                    self.cleanupReplyEntry(correlation_id);
                    return response;
                } else |err| switch (err) {
                    error.EmptyMailbox => {
                        compat.sleep(1 * std.time.ns_per_ms);
                        continue;
                    },
                    else => return err,
                }
            }
        }

        /// Reply to a call() request from within the message handler.
        /// Sends the response payload to the caller's dedicated reply mailbox.
        pub fn reply(self: *Self, original_msg: vigil.Message, payload: []const u8) !void {
            const corr_id = original_msg.metadata.correlation_id orelse return error.InvalidMessage;

            self.reply_mutex.lock();
            const reply_mbx = self.reply_mailboxes.get(corr_id);
            self.reply_mutex.unlock();

            if (reply_mbx) |mbx| {
                var response = try vigil.Message.init(
                    self.allocator,
                    "reply",
                    "genserver",
                    payload,
                    .info,
                    .normal,
                    null,
                );
                errdefer response.deinit();
                try response.setCorrelationId(corr_id);
                try mbx.send(response);
            } else {
                return error.InvalidMessage;
            }
        }

        fn cleanupReplyEntry(self: *Self, correlation_id: []const u8) void {
            self.reply_mutex.lock();
            const removed = self.reply_mailboxes.fetchRemove(correlation_id);
            self.reply_mutex.unlock();

            if (removed) |entry| {
                var mbx = entry.value;
                mbx.deinit();
                self.allocator.destroy(mbx);
                self.allocator.free(entry.key);
            }
        }

        fn cleanupReplyMailboxes(self: *Self) void {
            self.reply_mutex.lock();
            defer self.reply_mutex.unlock();

            var it = self.reply_mailboxes.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.*.deinit();
                self.allocator.destroy(entry.value_ptr.*);
                self.allocator.free(entry.key_ptr.*);
            }
            self.reply_mailboxes.deinit();
        }

        /// Configure state checkpointing.
        /// If a checkpoint already exists, the state is immediately restored.
        pub fn setCheckpointer(
            self: *Self,
            ckpt: checkpoint_mod.Checkpointer,
            id: []const u8,
            interval_ms: u32,
            fns: CheckpointFns,
        ) !void {
            self.checkpointer = ckpt;
            self.checkpoint_id = try self.allocator.dupe(u8, id);
            self.checkpoint_interval_ms = interval_ms;
            self.checkpoint_fns = fns;

            // Try to restore from existing checkpoint
            if (try ckpt.load(id, self.allocator)) |data| {
                defer self.allocator.free(data);
                self.state = try fns.deserialize(data, self.allocator);
            }
        }

        fn maybeCheckpoint(self: *Self) void {
            if (self.checkpointer == null or self.checkpoint_fns == null) return;
            const now = compat.milliTimestamp();
            if (now - self.last_checkpoint_ms < self.checkpoint_interval_ms) return;
            self.last_checkpoint_ms = now;
            self.saveCheckpoint();
        }

        fn saveCheckpoint(self: *Self) void {
            const ckpt = self.checkpointer orelse return;
            const fns = self.checkpoint_fns orelse return;
            const id = self.checkpoint_id orelse return;

            const data = fns.serialize(&self.state, self.allocator) catch return;
            defer self.allocator.free(data);
            ckpt.save(id, data) catch {};
        }

        /// Register the GenServer with the global registry
        pub fn register(self: *Self, name: []const u8) !void {
            if (vigil.global_registry) |reg| {
                try reg.register(name, self.mailbox);
            } else {
                return error.GlobalRegistryNotInitialized;
            }
        }

        /// Schedule a message to be sent to self after a delay
        pub fn schedule(self: *Self, msg: vigil.Message, delay_ms: u32) !void {
            try vigil.Timer.sendAfter(self.allocator, delay_ms, self.mailbox, msg);
        }

        /// Signal the GenServer to stop.
        /// If running, sends a terminate signal to the message loop.
        /// After calling stop(), join the server thread, then call deinit().
        pub fn stop(self: *Self) void {
            switch (self.server_state) {
                .initial => {
                    self.server_state = .stopped;
                },
                .running => {
                    self.server_state = .stopped;
                    const msg = vigil.Message.init(self.allocator, "stop", "system", null, .terminate, .critical, null) catch return;
                    self.mailbox.send(msg) catch {};
                },
                .stopped => {},
            }
        }

        /// Register with a supervisor
        pub fn supervise(self: *Self, supervisor: *vigil.Supervisor, id: []const u8) !void {
            self.supervisor = supervisor;

            current_context.store(@ptrCast(self), .release);

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
            if (current_context.load(.acquire)) |ctx| {
                const self: *Self = @ptrCast(@alignCast(ctx));
                _ = self.start() catch {};
            }
        }

        pub fn getContext() ?*anyopaque {
            return current_context.load(.acquire);
        }
    };
}

test "GenServer initialization" {
    const allocator = testing.allocator;

    const State = struct { count: u32 };
    const ServerType = GenServer(State);

    const server = try ServerType.init(
        allocator,
        struct {
            fn handle(self: *ServerType, msg: vigil.Message) !void {
                _ = self;
                _ = msg;
            }
        }.handle,
        struct {
            fn init_cb(self: *ServerType) !void {
                _ = self;
            }
        }.init_cb,
        struct {
            fn terminate(self: *ServerType) void {
                _ = self;
            }
        }.terminate,
        State{ .count = 0 },
    );
    server.stop();
    server.deinit();
}

test "GenServer message handling" {
    const allocator = testing.allocator;

    const Context = struct {
        received: bool = false,
        mutex: compat.Mutex = .{},
    };
    var context = Context{};

    const State = struct { ctx: *Context };
    const ServerType = GenServer(State);

    const server = try ServerType.init(
        allocator,
        struct {
            fn handle(self: *ServerType, msg: vigil.Message) !void {
                if (std.mem.eql(u8, msg.payload.?, "test")) {
                    self.state.ctx.mutex.lock();
                    defer self.state.ctx.mutex.unlock();
                    self.state.ctx.received = true;
                    self.server_state = .stopped;
                }
            }
        }.handle,
        struct {
            fn init_cb(self: *ServerType) !void {
                _ = self;
            }
        }.init_cb,
        struct {
            fn terminate(self: *ServerType) void {
                _ = self;
            }
        }.terminate,
        State{ .ctx = &context },
    );

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

    thread.join();
    server.deinit();

    context.mutex.lock();
    defer context.mutex.unlock();
    try testing.expect(context.received);
}

test "GenServer synchronous call" {
    const allocator = testing.allocator;

    const State = struct { count: u32 };
    const ServerType = GenServer(State);

    const server = try ServerType.init(
        allocator,
        struct {
            fn handle(self: *ServerType, msg: vigil.Message) !void {
                if (msg.payload) |payload| {
                    if (std.mem.eql(u8, payload, "ping")) {
                        try self.reply(msg, "pong");
                    }
                }
            }
        }.handle,
        struct {
            fn init_cb(self: *ServerType) !void {
                _ = self;
            }
        }.init_cb,
        struct {
            fn terminate(self: *ServerType) void {
                _ = self;
            }
        }.terminate,
        State{ .count = 0 },
    );

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *ServerType) void {
            s.start() catch {};
        }
    }.run, .{server});

    // Give server time to start
    compat.sleep(10 * std.time.ns_per_ms);

    var msg = try vigil.Message.init(allocator, "ping_msg", "tester", "ping", .info, .normal, 5000);
    defer msg.deinit();

    var response = try server.call(&msg, 2000);
    defer response.deinit();

    try testing.expectEqualSlices(u8, "pong", response.payload.?);

    // Stop server after call completes
    server.stop();
    thread.join();
    server.deinit();
}

test "GenServer supervision" {
    const allocator = testing.allocator;

    const State = struct { count: u32 };
    const ServerType = GenServer(State);

    const server = try ServerType.init(
        allocator,
        struct {
            fn handle(self: *ServerType, msg: vigil.Message) !void {
                _ = self;
                _ = msg;
            }
        }.handle,
        struct {
            fn init_cb(self: *ServerType) !void {
                _ = self;
            }
        }.init_cb,
        struct {
            fn terminate(self: *ServerType) void {
                _ = self;
            }
        }.terminate,
        State{ .count = 0 },
    );

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

    server.stop();
    server.deinit();
}

test "GenServer state management" {
    const allocator = testing.allocator;

    const Context = struct {
        count: u32 = 0,
        mutex: compat.Mutex = .{},
    };
    var context = Context{};

    const State = struct { ctx: *Context };
    const ServerType = GenServer(State);

    const server = try ServerType.init(
        allocator,
        struct {
            fn handle(self: *ServerType, msg: vigil.Message) !void {
                if (std.mem.eql(u8, msg.payload.?, "increment")) {
                    self.state.ctx.mutex.lock();
                    defer self.state.ctx.mutex.unlock();
                    self.state.ctx.count += 1;
                    self.server_state = .stopped;
                }
            }
        }.handle,
        struct {
            fn init_cb(self: *ServerType) !void {
                _ = self;
            }
        }.init_cb,
        struct {
            fn terminate(self: *ServerType) void {
                _ = self;
            }
        }.terminate,
        State{ .ctx = &context },
    );

    const msg = try vigil.Message.init(allocator, "inc_msg", "tester", "increment", .info, .normal, 1000);
    try server.cast(msg);

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *ServerType) void {
            s.start() catch {};
        }
    }.run, .{server});

    thread.join();
    server.deinit();

    context.mutex.lock();
    defer context.mutex.unlock();
    try testing.expect(context.count == 1);
}

test "GenServer checkpointing" {
    const allocator = testing.allocator;

    const State = struct { count: u32 };
    const ServerType = GenServer(State);

    var mem_ckpt = checkpoint_mod.MemoryCheckpointer.init(allocator);
    defer mem_ckpt.deinit();

    const ckpt = mem_ckpt.toCheckpointer();

    // Save a checkpoint manually to simulate prior state
    try ckpt.save("test_server", "42");

    const server = try ServerType.init(
        allocator,
        struct {
            fn handle(self: *ServerType, msg: vigil.Message) !void {
                _ = self;
                _ = msg;
            }
        }.handle,
        struct {
            fn init_cb(self: *ServerType) !void {
                _ = self;
            }
        }.init_cb,
        struct {
            fn terminate(self: *ServerType) void {
                _ = self;
            }
        }.terminate,
        State{ .count = 0 },
    );

    try server.setCheckpointer(ckpt, "test_server", 1000, .{
        .serialize = struct {
            fn serialize(state: *const State, alloc: std.mem.Allocator) ![]u8 {
                return try std.fmt.allocPrint(alloc, "{d}", .{state.count});
            }
        }.serialize,
        .deserialize = struct {
            fn deserialize(data: []const u8, _: std.mem.Allocator) !State {
                const count = try std.fmt.parseInt(u32, data, 10);
                return State{ .count = count };
            }
        }.deserialize,
    });

    // State should have been restored from checkpoint
    try testing.expectEqual(@as(u32, 42), server.state.count);

    server.stop();
    server.deinit();
}
