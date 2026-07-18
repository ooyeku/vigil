const std = @import("std");
const vigil = @import("vigil.zig");
const checkpoint_mod = @import("checkpoint.zig");
const compat = @import("compat.zig");
const testing = @import("std").testing;

pub const GenServerState = enum(u8) {
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
        server_state: std.atomic.Value(GenServerState) = std.atomic.Value(GenServerState).init(.initial),
        next_correlation_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(1),

        /// Thread-safe map of correlation_id -> reply mailbox for the call/reply pattern.
        reply_mailboxes: std.StringHashMap(*vigil.ProcessMailbox),
        reply_mutex: compat.Mutex = .{},

        /// Optional timer service used by `schedule()`. Not owned.
        timer_service: ?*vigil.TimerService = null,

        /// Optional state checkpointing
        checkpointer: ?checkpoint_mod.Checkpointer = null,
        checkpoint_id: ?[]const u8 = null,
        checkpoint_interval_ms: u32 = 30_000,
        checkpoint_fns: ?CheckpointFns = null,
        last_checkpoint_ms: i64 = 0,

        const Self = @This();

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

            const mailbox = try allocator.create(vigil.ProcessMailbox);
            errdefer allocator.destroy(mailbox);
            mailbox.* = vigil.ProcessMailbox.init(allocator, .{
                .capacity = 100,
                .priority_queues = true,
                .enable_deadletter = true,
                .default_ttl_ms = 5000,
            });

            self.* = .{
                .allocator = allocator,
                .mailbox = mailbox,
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
            if (self.server_state.cmpxchgStrong(.initial, .running, .acq_rel, .acquire) != null) {
                return error.AlreadyRunning;
            }

            self.init_fn(self) catch |err| {
                self.server_state.store(.initial, .release);
                return err;
            };
            self.last_checkpoint_ms = compat.monotonicMilliTimestamp();
            defer {
                // Every successful initialization has exactly one matching
                // termination path, including handler and mailbox failures.
                self.saveCheckpoint();
                self.terminate_fn(self);
                self.server_state.store(.stopped, .release);
            }

            while (self.server_state.load(.acquire) == .running) {
                if (self.mailbox.receive()) |msg_const| {
                    var msg = msg_const;

                    if (self.server_state.load(.acquire) != .running or (msg.signal != null and msg.signal.? == .terminate)) {
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
        }

        /// Send an asynchronous message to the GenServer
        pub fn cast(self: *Self, msg: vigil.Message) !void {
            if (self.server_state.load(.acquire) == .stopped) {
                msg.deinit();
                return error.NotRunning;
            }
            try self.mailbox.send(msg);
        }

        /// Send a synchronous message and wait for response.
        /// The handler must call self.reply(msg, payload) to send a response
        /// back to the caller's dedicated reply mailbox.
        pub fn call(self: *Self, msg: *vigil.Message, timeout_ms: ?u32) !vigil.Message {
            if (self.server_state.load(.acquire) == .stopped) return error.NotRunning;

            const sequence = self.next_correlation_id.fetchAdd(1, .monotonic);
            const correlation_id = try std.fmt.allocPrint(
                self.allocator,
                "call_{d}_{d}",
                .{ compat.milliTimestamp(), sequence },
            );
            var correlation_owned = true;
            errdefer if (correlation_owned) self.allocator.free(correlation_id);

            // Create a temporary reply mailbox dedicated to this call
            const reply_mbx = try self.allocator.create(vigil.ProcessMailbox);
            var reply_mailbox_owned = true;
            errdefer if (reply_mailbox_owned) {
                reply_mbx.deinit();
                self.allocator.destroy(reply_mbx);
            };
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
            correlation_owned = false;
            reply_mailbox_owned = false;

            // Prepare and send message with correlation ID
            var msg_copy = msg.dupe() catch |err| {
                self.cleanupReplyEntry(correlation_id);
                return err;
            };
            msg_copy.setCorrelationId(correlation_id) catch |err| {
                msg_copy.deinit();
                self.cleanupReplyEntry(correlation_id);
                return err;
            };
            self.cast(msg_copy) catch |err| {
                self.cleanupReplyEntry(correlation_id);
                return err;
            };

            // Wait on the dedicated reply mailbox (not the server's mailbox)
            const start_time = compat.monotonicMilliTimestamp();
            var first_poll = true;
            while (true) {
                if (timeout_ms) |timeout| {
                    if ((timeout == 0 and !first_poll) or
                        (timeout != 0 and compat.monotonicMilliTimestamp() - start_time >= timeout))
                    {
                        self.cleanupReplyEntry(correlation_id);
                        return error.Timeout;
                    }
                }

                if (reply_mbx.receive()) |response| {
                    self.cleanupReplyEntry(correlation_id);
                    return response;
                } else |err| switch (err) {
                    error.EmptyMailbox => {},
                    else => {
                        self.cleanupReplyEntry(correlation_id);
                        return err;
                    },
                }

                first_poll = false;
                if (self.server_state.load(.acquire) == .stopped) {
                    self.cleanupReplyEntry(correlation_id);
                    return error.NotRunning;
                }
                compat.sleep(1 * std.time.ns_per_ms);
            }
        }

        /// Reply to a call() request from within the message handler.
        /// Sends the response payload to the caller's dedicated reply mailbox.
        pub fn reply(self: *Self, original_msg: vigil.Message, payload: []const u8) !void {
            const corr_id = original_msg.metadata.correlation_id orelse return error.InvalidMessage;

            self.reply_mutex.lock();
            defer self.reply_mutex.unlock();

            if (self.reply_mailboxes.get(corr_id)) |mbx| {
                var response = try vigil.Message.init(
                    self.allocator,
                    "reply",
                    "genserver",
                    payload,
                    .info,
                    .normal,
                    null,
                );
                response.setCorrelationId(corr_id) catch |err| {
                    response.deinit();
                    return err;
                };
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
            const id_copy = try self.allocator.dupe(u8, id);
            errdefer self.allocator.free(id_copy);

            // Try to restore from existing checkpoint
            var restored_state: ?StateType = null;
            if (try ckpt.load(id, self.allocator)) |data| {
                defer self.allocator.free(data);
                restored_state = try fns.deserialize(data, self.allocator);
            }

            if (self.checkpoint_id) |old_id| self.allocator.free(old_id);
            self.checkpointer = ckpt;
            self.checkpoint_id = id_copy;
            self.checkpoint_interval_ms = interval_ms;
            self.checkpoint_fns = fns;
            if (restored_state) |state| self.state = state;
        }

        fn maybeCheckpoint(self: *Self) void {
            if (self.checkpointer == null or self.checkpoint_fns == null) return;
            const now = compat.monotonicMilliTimestamp();
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

        /// Register the GenServer with an explicit registry.
        pub fn register(self: *Self, registry: *vigil.Registry, name: []const u8) !void {
            try registry.register(name, self.mailbox);
        }

        /// Attach a timer service used by `schedule()`. Not owned.
        pub fn setTimerService(self: *Self, service: ?*vigil.TimerService) void {
            self.timer_service = service;
        }

        /// Schedule a message to be sent to self after a delay.
        ///
        /// Requires a timer service attached with `setTimerService()`
        /// (typically `Runtime.timers()`); returns `error.NoTimerService`
        /// otherwise. The message is consumed on success and on error.
        pub fn schedule(self: *Self, msg: vigil.Message, delay_ms: u32) !void {
            const service = self.timer_service orelse {
                msg.deinit();
                return error.NoTimerService;
            };
            _ = try service.sendAfter(delay_ms, self.mailbox, msg);
        }

        /// Signal the GenServer to stop.
        /// If running, sends a terminate signal to the message loop.
        /// After calling stop(), join the server thread, then call deinit().
        pub fn stop(self: *Self) void {
            switch (self.server_state.load(.acquire)) {
                .initial => {
                    self.server_state.store(.stopped, .release);
                },
                .running => {
                    self.server_state.store(.stopped, .release);
                    const msg = vigil.Message.init(self.allocator, "stop", "system", null, .terminate, .critical, null) catch return;
                    self.mailbox.send(msg) catch {};
                },
                .stopped => {},
            }
        }

        /// Register with a supervisor
        pub fn supervise(self: *Self, supervisor: *vigil.Supervisor, id: []const u8) !void {
            try supervisor.addChild(.{
                .id = id,
                .start_fn = unusedStartFn,
                .start_context_fn = startContextFn,
                .restart_type = .permanent,
                .shutdown_timeout_ms = 5000,
                .priority = .normal,
                .context = self,
            });
            self.supervisor = supervisor;
        }

        fn unusedStartFn() void {}

        fn startContextFn(context: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(context.?));
            _ = self.start() catch {};
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

test "GenServer handler failure still terminates and stops lifecycle" {
    const State = struct {};
    const ServerType = GenServer(State);
    const Recorder = struct {
        var terminations = std.atomic.Value(u32).init(0);

        fn handle(_: *ServerType, _: vigil.Message) !void {
            return error.HandlerFailed;
        }

        fn init(_: *ServerType) !void {}

        fn terminate(_: *ServerType) void {
            _ = terminations.fetchAdd(1, .monotonic);
        }
    };
    Recorder.terminations.store(0, .release);

    const server = try ServerType.init(testing.allocator, Recorder.handle, Recorder.init, Recorder.terminate, .{});
    defer server.deinit();
    const message = try vigil.Message.init(testing.allocator, "failure", "test", "payload", null, .normal, null);
    try server.cast(message);

    try testing.expectError(error.HandlerFailed, server.start());
    try testing.expectEqual(GenServerState.stopped, server.server_state.load(.acquire));
    try testing.expectEqual(@as(u32, 1), Recorder.terminations.load(.acquire));
}

test "GenServer checkpointer reconfiguration rolls back on restore failure" {
    const ServerType = GenServer(u32);
    const Callbacks = struct {
        fn handle(_: *ServerType, _: vigil.Message) !void {}
        fn init(_: *ServerType) !void {}
        fn terminate(_: *ServerType) void {}

        fn serialize(state: *const u32, allocator: std.mem.Allocator) ![]u8 {
            return std.fmt.allocPrint(allocator, "{d}", .{state.*});
        }

        fn deserialize(data: []const u8, _: std.mem.Allocator) !u32 {
            return std.fmt.parseInt(u32, data, 10);
        }
    };

    const server = try ServerType.init(testing.allocator, Callbacks.handle, Callbacks.init, Callbacks.terminate, 1);
    defer server.deinit();
    var memory = checkpoint_mod.MemoryCheckpointer.init(testing.allocator);
    defer memory.deinit();
    const ckpt = memory.toCheckpointer();
    const fns = ServerType.CheckpointFns{
        .serialize = Callbacks.serialize,
        .deserialize = Callbacks.deserialize,
    };

    try server.setCheckpointer(ckpt, "old", 10, fns);
    try ckpt.save("bad", "not-a-number");
    try testing.expectError(error.InvalidCharacter, server.setCheckpointer(ckpt, "bad", 20, fns));
    try testing.expectEqualStrings("old", server.checkpoint_id.?);
    try testing.expectEqual(@as(u32, 10), server.checkpoint_interval_ms);
    try testing.expectEqual(@as(u32, 1), server.state);
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
                    self.server_state.store(.stopped, .release);
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

test "GenServer timed out call releases reply resources once" {
    const allocator = testing.allocator;
    const State = struct {};
    const ServerType = GenServer(State);

    const server = try ServerType.init(
        allocator,
        struct {
            fn handle(_: *ServerType, _: vigil.Message) !void {}
        }.handle,
        struct {
            fn init_cb(_: *ServerType) !void {}
        }.init_cb,
        struct {
            fn terminate(_: *ServerType) void {}
        }.terminate,
        .{},
    );
    defer server.deinit();

    var request_message = try vigil.Message.init(
        allocator,
        "timeout",
        "test",
        "no reply",
        null,
        .normal,
        null,
    );
    defer request_message.deinit();

    try testing.expectError(error.Timeout, server.call(&request_message, 1));
}

test "GenServer rejects casts and calls after it has stopped" {
    const ServerType = GenServer(struct {});
    const Callbacks = struct {
        fn handle(_: *ServerType, _: vigil.Message) !void {}
        fn init(_: *ServerType) !void {}
        fn terminate(_: *ServerType) void {}
    };

    const server = try ServerType.init(testing.allocator, Callbacks.handle, Callbacks.init, Callbacks.terminate, .{});
    defer server.deinit();
    server.stop();

    const cast_message = try vigil.Message.init(testing.allocator, "cast", "test", "payload", null, .normal, null);
    try testing.expectError(error.NotRunning, server.cast(cast_message));

    var call_message = try vigil.Message.init(testing.allocator, "call", "test", "payload", null, .normal, null);
    defer call_message.deinit();
    try testing.expectError(error.NotRunning, server.call(&call_message, null));
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

    var supervisor = vigil.Supervisor.init(allocator, .{
        .strategy = .one_for_one,
        .max_restarts = 3,
        .max_seconds = 5,
    });
    defer supervisor.deinit();

    try server.supervise(&supervisor, "test_gen_server");
    try testing.expect(server.supervisor != null);

    server.stop();
    server.deinit();
}

test "GenServer supervision keeps per-child context for same state type" {
    const State = struct { starts: std.atomic.Value(u32) };
    const ServerType = GenServer(State);
    const Callbacks = struct {
        fn handle(_: *ServerType, _: vigil.Message) !void {}
        fn init(server: *ServerType) !void {
            _ = server.state.starts.fetchAdd(1, .monotonic);
        }
        fn terminate(_: *ServerType) void {}
    };

    const first = try ServerType.init(testing.allocator, Callbacks.handle, Callbacks.init, Callbacks.terminate, .{ .starts = std.atomic.Value(u32).init(0) });
    const second = try ServerType.init(testing.allocator, Callbacks.handle, Callbacks.init, Callbacks.terminate, .{ .starts = std.atomic.Value(u32).init(10) });
    var supervisor = vigil.Supervisor.init(testing.allocator, .{
        .strategy = .one_for_one,
        .max_restarts = 3,
        .max_seconds = 5,
    });

    try first.supervise(&supervisor, "first");
    try second.supervise(&supervisor, "second");
    try supervisor.start();

    var waited: u32 = 0;
    while ((first.state.starts.load(.acquire) != 1 or second.state.starts.load(.acquire) != 11) and waited < 100) : (waited += 1) {
        compat.sleep(1 * std.time.ns_per_ms);
    }
    try testing.expectEqual(GenServerState.running, first.server_state.load(.acquire));
    try testing.expectEqual(GenServerState.running, second.server_state.load(.acquire));
    try testing.expectEqual(@as(u32, 1), first.state.starts.load(.acquire));
    try testing.expectEqual(@as(u32, 11), second.state.starts.load(.acquire));

    first.stop();
    second.stop();
    try supervisor.shutdown(1000);
    first.deinit();
    second.deinit();
    supervisor.deinit();
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
                    self.server_state.store(.stopped, .release);
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
