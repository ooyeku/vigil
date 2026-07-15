//! Vigil operations toolkit.
//!
//! Small, focused demos of the v2.2 "Operate and Recover" APIs:
//!
//!   zig build run                        run every demo
//!   zig build run -- job-queue           resilient job queue
//!   zig build run -- retry-client        retry/backoff dependency client
//!   zig build run -- dead-letter-replay  dead-letter inspection and replay
//!   zig build run -- introspection       runtime introspection endpoint
//!   zig build run -- checkpoint          checkpointed state machine

const std = @import("std");
const vigil = @import("vigil");

const Demo = struct {
    name: []const u8,
    summary: []const u8,
    run: *const fn (std.mem.Allocator) anyerror!void,
};

const demos = [_]Demo{
    .{ .name = "job-queue", .summary = "resilient job queue with poison handling", .run = runJobQueue },
    .{ .name = "retry-client", .summary = "retry/backoff dependency client", .run = runRetryClient },
    .{ .name = "dead-letter-replay", .summary = "dead-letter inspection and replay", .run = runDeadLetterReplay },
    .{ .name = "introspection", .summary = "runtime introspection endpoint", .run = runIntrospection },
    .{ .name = "checkpoint", .summary = "checkpointed state machine", .run = runCheckpoint },
};

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.skip(); // program name

    const selected = args.next();

    if (selected) |name| {
        for (&demos) |demo| {
            if (std.mem.eql(u8, demo.name, name)) {
                try runDemo(allocator, demo);
                return;
            }
        }
        std.debug.print("unknown demo: {s}\n\navailable demos:\n", .{name});
        for (&demos) |demo| {
            std.debug.print("  {s: <20} {s}\n", .{ demo.name, demo.summary });
        }
        return error.UnknownDemo;
    }

    for (&demos) |demo| {
        try runDemo(allocator, demo);
    }
}

fn runDemo(allocator: std.mem.Allocator, demo: Demo) !void {
    std.debug.print("\n=== {s}: {s} ===\n\n", .{ demo.name, demo.summary });
    try demo.run(allocator);
}

// --- job-queue -------------------------------------------------------------
//
// A worker consumes jobs from a bounded inbox. Failed jobs are dead-lettered;
// transient failures are replayed once, while jobs that keep failing cross the
// poison threshold and stay quarantined until an operator discards them.

fn runJobQueue(allocator: std.mem.Allocator) !void {
    var rt = try vigil.runtime(allocator, .{});
    defer rt.deinit();

    var jobs = try rt.inbox(.{
        .capacity = 16,
        .dead_letter_capacity = 16,
        .max_delivery_attempts = 2,
    });
    defer jobs.close();
    try rt.register("jobs.inbox", jobs.mailbox);

    const job_names = [_][]const u8{
        "resize-image-101",
        "send-invoice-102",
        "corrupt-payload-103", // fails on every attempt
        "sync-crm-104",
    };
    for (job_names) |job| {
        try jobs.send(job);
    }
    std.debug.print("enqueued {d} jobs\n", .{try jobs.queueDepth()});

    // First pass: handle everything once; failures go to the dead-letter queue.
    try drainJobQueue(jobs);

    // Operator pass: replay retained failures. Transient jobs succeed on the
    // second delivery attempt; the corrupt job crosses max_delivery_attempts
    // and is retained as poison.
    var retained = try jobs.deadLetters(allocator);
    defer retained.deinit();
    for (retained.entries) |entry| {
        const result = try jobs.replayDeadLetter(entry.id);
        std.debug.print("replay #{d} ({s}): {s}\n", .{
            entry.id,
            entry.message.payload orelse "<signal>",
            @tagName(result.status),
        });
    }
    try drainJobQueue(jobs);

    const report = try rt.health(allocator);
    std.debug.print("health: {s} (dead-lettered {d}, poison {d})\n", .{
        @tagName(report.status),
        report.dead_lettered_messages,
        report.poison_messages,
    });

    const discarded = try jobs.discardAllDeadLetters();
    std.debug.print("operator discarded {d} poison job(s)\n", .{discarded});
    const recovered = try rt.health(allocator);
    std.debug.print("health after cleanup: {s}\n", .{@tagName(recovered.status)});
}

fn drainJobQueue(jobs: *vigil.Inbox) !void {
    while (try jobs.recvTimeout(10)) |msg| {
        const payload = msg.payload orelse {
            msg.deinit();
            continue;
        };
        if (std.mem.indexOf(u8, payload, "corrupt") != null or msg.metadata.attempt_count < 2 and std.mem.indexOf(u8, payload, "sync") != null) {
            // Simulated handler failure: hand the message back to the queue's
            // dead-letter storage instead of dropping it on the floor.
            const notice = try jobs.deadLetter(msg, .delivery_failed);
            std.debug.print("worker failed {s} (attempt {d}{s})\n", .{
                payload,
                notice.attempt_count,
                if (notice.poisoned) ", poisoned" else "",
            });
        } else {
            std.debug.print("worker completed {s}\n", .{payload});
            msg.deinit();
        }
    }
}

// --- retry-client -----------------------------------------------------------
//
// A dependency client wraps calls in a reliability policy: bounded retries
// with jittered exponential backoff, a circuit breaker, and a fallback. The
// simulated clock makes the run deterministic and instant.

fn runRetryClient(allocator: std.mem.Allocator) !void {
    var breaker = try vigil.CircuitBreaker.init(allocator, "billing-api", .{
        .failure_threshold = 3,
        .reset_timeout_ms = 30_000,
    });
    defer breaker.deinit();

    const Client = struct {
        injector: vigil.FaultInjector,
        clock: vigil.SimulatedClock,

        fn fetchQuote(ctx: *@This()) anyerror!u32 {
            try ctx.injector.call();
            return 4_200;
        }

        fn cachedQuote(_: *@This(), failure: vigil.PolicyFailure) anyerror!u32 {
            std.debug.print("fallback engaged after {s}\n", .{@tagName(failure.outcome)});
            return 3_999;
        }

        fn clockHook(ctx: *@This()) i64 {
            return ctx.clock.now();
        }

        fn sleepHook(ctx: *@This(), nanoseconds: u64) void {
            ctx.clock.sleep(nanoseconds);
        }
    };

    // The dependency fails twice, then recovers.
    var client = Client{
        .injector = vigil.FaultInjector.init(.{ .fail_first = 2, .error_value = error.BillingUnavailable }),
        .clock = vigil.SimulatedClock.init(0),
    };

    const result = vigil.executePolicy(Client, u32, &client, Client.fetchQuote, .{
        .retry = .{
            .max_attempts = 4,
            .backoff = .{ .jittered = .{
                .base = .{ .initial_ms = 50, .multiplier = 2, .max_ms = 1_000 },
                .jitter_ms = 25,
            } },
        },
        .timeout_ms = 5_000,
        .circuit_breaker = &breaker,
        .fallback = Client.cachedQuote,
        .clock = Client.clockHook,
        .sleeper = Client.sleepHook,
    });

    switch (result) {
        .success => |success| std.debug.print(
            "quote: {d} cents after {d} attempt(s), {d} retries, {d}ms simulated\n",
            .{ success.value, success.report.attempts, success.report.retries, success.report.elapsed_ms },
        ),
        .fallback => |fallback| std.debug.print("served cached quote {d}\n", .{fallback.value}),
        else => std.debug.print("dependency permanently unavailable\n", .{}),
    }

    // A persistently failing dependency opens the breaker, and later calls
    // fail fast without touching the dependency at all.
    var down = Client{
        .injector = vigil.FaultInjector.init(.{ .fail_first = 100, .error_value = error.BillingUnavailable }),
        .clock = vigil.SimulatedClock.init(0),
    };
    for (0..2) |_| {
        _ = vigil.executePolicy(Client, u32, &down, Client.fetchQuote, .{
            .retry = .{ .max_attempts = 2 },
            .circuit_breaker = &breaker,
            .clock = Client.clockHook,
            .sleeper = Client.sleepHook,
        });
    }

    const diagnostics = breaker.snapshot();
    std.debug.print("breaker '{s}': {s} ({d} open transitions, {d} lifetime failures)\n", .{
        diagnostics.circuit_id,
        @tagName(diagnostics.state),
        diagnostics.open_transitions,
        diagnostics.total_failures,
    });

    const guarded = vigil.executePolicy(Client, u32, &down, Client.fetchQuote, .{
        .circuit_breaker = &breaker,
        .clock = Client.clockHook,
        .sleeper = Client.sleepHook,
    });
    switch (guarded) {
        .circuit_open => |failure| std.debug.print(
            "fail-fast: circuit open, dependency spared after {d} attempt(s)\n",
            .{failure.attempts},
        ),
        else => std.debug.print("unexpected: breaker admitted the call\n", .{}),
    }
}

// --- dead-letter-replay ------------------------------------------------------
//
// An operator workflow: inspect retained dead letters without consuming them,
// replay what looks transient, and discard what is confirmed poison.

fn runDeadLetterReplay(allocator: std.mem.Allocator) !void {
    var rt = try vigil.runtime(allocator, .{});
    defer rt.deinit();
    try rt.enableTimeline(32);

    var orders = try rt.inbox(.{
        .capacity = 8,
        .dead_letter_capacity = 8,
        .max_delivery_attempts = 3,
    });
    defer orders.close();

    // Three deliveries fail downstream.
    for ([_][]const u8{ "order-311", "order-312", "order-313" }) |order| {
        try orders.send(order);
        const msg = (try orders.recvTimeout(10)).?;
        _ = try orders.deadLetter(msg, .delivery_failed);
    }

    var retained = try orders.deadLetters(allocator);
    defer retained.deinit();
    std.debug.print("retained dead letters: {d}\n", .{retained.entries.len});
    for (retained.entries) |entry| {
        std.debug.print("  #{d} {s} reason={s} attempts={d} poisoned={}\n", .{
            entry.id,
            entry.message.payload orelse "<signal>",
            @tagName(entry.reason),
            entry.message.metadata.attempt_count,
            entry.poisoned,
        });
    }

    // Replay the first entry, discard the second, leave the third retained.
    const replayed = try orders.replayDeadLetter(retained.entries[0].id);
    std.debug.print("replay #{d}: {s}\n", .{ retained.entries[0].id, @tagName(replayed.status) });
    const dropped = try orders.discardDeadLetter(retained.entries[1].id);
    std.debug.print("discard #{d}: {}\n", .{ retained.entries[1].id, dropped });

    std.debug.print("active queue after replay: {d} message(s)\n", .{try orders.queueDepth()});
    std.debug.print("still retained: {d} dead letter(s)\n", .{try orders.deadLetterCount()});

    // The lifecycle left an audit trail on the runtime timeline.
    if (try rt.timelineSnapshot(allocator)) |snapshot_const| {
        var snapshot = snapshot_const;
        defer snapshot.deinit();
        std.debug.print("timeline recorded {d} lifecycle event(s):\n", .{snapshot.entries.len});
        for (snapshot.entries) |entry| {
            std.debug.print("  #{d} {s}\n", .{ entry.sequence, @tagName(entry.event_type) });
        }
    }
}

// --- introspection -----------------------------------------------------------
//
// Everything a `GET /debug` or `STATUS` command needs: health, per-inbox
// queue statistics, non-consuming message peeks, route tables, subscriptions,
// and the recent-event timeline, rendered from one runtime.

fn runIntrospection(allocator: std.mem.Allocator) !void {
    var rt = try vigil.runtime(allocator, .{});
    defer rt.deinit();
    try rt.enableTimeline(16);

    var intake = try rt.inbox(.{ .capacity = 8 });
    defer intake.close();
    try rt.register("orders.intake", intake.mailbox);

    var shipping = try rt.inbox(.{ .capacity = 8 });
    defer shipping.close();
    try rt.register("orders.shipping", shipping.mailbox);

    try intake.send("order-501");
    try intake.send("order-502");
    try shipping.send("ship-771");

    // Non-consuming queue inspection.
    var queued = try intake.peekMessages(allocator);
    defer queued.deinit();
    std.debug.print("orders.intake queue (without consuming):\n", .{});
    for (queued.entries) |entry| {
        std.debug.print("  {s} priority={s} payload={d}B attempts={d}\n", .{
            entry.id,
            @tagName(entry.priority),
            entry.payload_len,
            entry.attempt_count,
        });
    }

    // Route-table inspection for a keyed worker pool.
    var pool = try vigil.ProcessGroup.init(allocator, "fulfillment");
    defer pool.deinit();
    try pool.add("intake-worker", intake);
    try pool.add("shipping-worker", shipping);
    std.debug.print("fulfillment route table:\n", .{});
    for ([_][]const u8{ "customer-1", "customer-2", "customer-3" }) |key| {
        const member = (try pool.routeMemberForKey(allocator, key)).?;
        defer allocator.free(member);
        std.debug.print("  {s} -> {s}\n", .{ key, member });
    }

    // Subscription inspection.
    var broker = vigil.PubSubBroker.init(allocator);
    defer broker.deinit();
    var subscriber = vigil.Subscriber.init(allocator, shipping);
    defer subscriber.deinit();
    try subscriber.subscribe(&.{ "orders.*", "alerts.#" });
    try broker.subscribe(&subscriber);

    var broker_snapshot = try broker.snapshot(allocator);
    defer broker_snapshot.deinit();
    std.debug.print("pubsub subscriptions ({d} subscriber(s)):\n", .{broker_snapshot.subscriber_count});
    for (broker_snapshot.subscribers) |sub| {
        for (sub.patterns) |pattern| {
            std.debug.print("  {s} (queue depth {d})\n", .{ pattern, sub.queue_depth });
        }
    }

    // The full structured dump — what a status endpoint would return.
    const dump = try rt.debugDump(allocator);
    defer allocator.free(dump);
    std.debug.print("\n{s}", .{dump});
}

// --- checkpoint ---------------------------------------------------------------
//
// A tiny order state machine persists its state through a `Checkpointer`
// after every transition, then recovers from the checkpoint after a simulated
// crash.

fn runCheckpoint(allocator: std.mem.Allocator) !void {
    const OrderPhase = enum { received, picked, boxed, shipped };

    const OrderMachine = struct {
        phase: OrderPhase,
        transitions: u32,

        fn encode(self: @This(), buffer: []u8) ![]const u8 {
            return std.fmt.bufPrint(buffer, "{s}:{d}", .{ @tagName(self.phase), self.transitions });
        }

        fn decode(state: []const u8) !@This() {
            const split = std.mem.indexOfScalar(u8, state, ':') orelse return error.CorruptCheckpoint;
            const phase = std.meta.stringToEnum(OrderPhase, state[0..split]) orelse return error.CorruptCheckpoint;
            const transitions = try std.fmt.parseInt(u32, state[split + 1 ..], 10);
            return .{ .phase = phase, .transitions = transitions };
        }

        fn advance(self: *@This()) void {
            self.phase = switch (self.phase) {
                .received => .picked,
                .picked => .boxed,
                .boxed => .shipped,
                .shipped => .shipped,
            };
            self.transitions += 1;
        }
    };

    var store = vigil.MemoryCheckpointer.init(allocator);
    defer store.deinit();
    const checkpointer = store.toCheckpointer();

    var machine = OrderMachine{ .phase = .received, .transitions = 0 };
    var buffer: [64]u8 = undefined;

    // Advance twice, checkpointing after each transition.
    for (0..2) |_| {
        machine.advance();
        try checkpointer.save("order-899", try machine.encode(&buffer));
        std.debug.print("checkpointed at {s} ({d} transitions)\n", .{
            @tagName(machine.phase),
            machine.transitions,
        });
    }

    // Simulated crash: in-memory state is gone.
    machine = OrderMachine{ .phase = .received, .transitions = 0 };
    std.debug.print("crash! machine reset to {s}\n", .{@tagName(machine.phase)});

    // Recovery: load the last checkpoint and continue.
    const saved = (try checkpointer.load("order-899", allocator)) orelse return error.MissingCheckpoint;
    defer allocator.free(saved);
    machine = try OrderMachine.decode(saved);
    std.debug.print("recovered at {s} ({d} transitions)\n", .{
        @tagName(machine.phase),
        machine.transitions,
    });

    machine.advance();
    try checkpointer.save("order-899", try machine.encode(&buffer));
    std.debug.print("resumed and reached {s} ({d} transitions)\n", .{
        @tagName(machine.phase),
        machine.transitions,
    });

    checkpointer.delete("order-899");
    std.debug.print("checkpoint cleaned up after terminal state\n", .{});
}

test "demo table stays consistent" {
    for (&demos) |demo| {
        try std.testing.expect(demo.name.len > 0);
        try std.testing.expect(demo.summary.len > 0);
    }
}
