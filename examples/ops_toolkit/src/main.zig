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
    .{ .name = "worker-pool", .summary = "high-throughput worker pool with batch receives", .run = runWorkerPool },
    .{ .name = "metrics-collector", .summary = "telemetry counters collected from runtime events", .run = runMetricsCollector },
    .{ .name = "distributed-registry", .summary = "two-node name resolution over loopback TCP", .run = runDistributedRegistry },
    .{ .name = "pubsub-pipeline", .summary = "pub/sub notification pipeline with batch publish", .run = runPubSubPipeline },
    .{ .name = "graceful-drain", .summary = "drain in-flight work before shutdown", .run = runGracefulDrain },
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

/// High-throughput worker pool: a throughput-profile inbox feeding worker
/// threads that drain with batch receives, routed through a process group.
fn runWorkerPool(allocator: std.mem.Allocator) !void {
    std.debug.print("\n--- worker pool: throughput profile + recvBatch ---\n", .{});

    const worker_count = 4;
    const job_count: u64 = 100_000;

    var rt = try vigil.runtime(allocator, .{});
    defer rt.deinit();

    var group = try vigil.ProcessGroup.init(allocator, "pool");
    defer group.deinit();

    var inboxes: [worker_count]*vigil.Inbox = undefined;
    for (&inboxes, 0..) |*slot, i| {
        slot.* = try rt.inboxWithProfile(.throughput, 4096);
        var name_buf: [16]u8 = undefined;
        try group.add(try std.fmt.bufPrint(&name_buf, "w{d}", .{i}), slot.*);
    }
    defer for (inboxes) |ib| ib.close();

    const Worker = struct {
        inbox: *vigil.Inbox,
        processed: u64 = 0,

        fn run(self: *@This()) void {
            var buffer: [64]vigil.Message = undefined;
            while (true) {
                const got = self.inbox.recvBatch(&buffer) catch return;
                if (got == 0) {
                    const msg = self.inbox.recvTimeout(50) catch return orelse return;
                    msg.deinit();
                    self.processed += 1;
                    continue;
                }
                for (buffer[0..got]) |m| m.deinit();
                self.processed += got;
            }
        }
    };

    var workers: [worker_count]Worker = undefined;
    var threads: [worker_count]std.Thread = undefined;
    for (&workers, &threads, inboxes) |*w, *t, ib| {
        w.* = .{ .inbox = ib };
        t.* = try std.Thread.spawn(.{}, Worker.run, .{w});
    }

    const start_ms = vigil.compat.monotonicMilliTimestamp();
    var dispatched: u64 = 0;
    while (dispatched < job_count) : (dispatched += 1) {
        group.roundRobin("job") catch continue;
    }
    for (threads) |t| t.join();
    const elapsed = vigil.compat.monotonicMilliTimestamp() - start_ms;

    var processed: u64 = 0;
    for (workers) |w| processed += w.processed;
    std.debug.print("dispatched {d} jobs to {d} workers in {d}ms ({d}/s), processed {d}\n", .{
        job_count,
        worker_count,
        elapsed,
        if (elapsed > 0) job_count * 1000 / @as(u64, @intCast(elapsed)) else job_count,
        processed,
    });
}

var collector_counts = [_]u32{0} ** 3;

fn collectDeadLetter(_: vigil.telemetry.Event) void {
    collector_counts[0] += 1;
}
fn collectReplay(_: vigil.telemetry.Event) void {
    collector_counts[1] += 1;
}
fn collectDiscard(_: vigil.telemetry.Event) void {
    collector_counts[2] += 1;
}

/// Metrics collector: subscribe counters to runtime telemetry and render a
/// scrape-style report, the shape you would export to a metrics endpoint.
fn runMetricsCollector(allocator: std.mem.Allocator) !void {
    std.debug.print("\n--- metrics collector: counters from telemetry ---\n", .{});
    collector_counts = [_]u32{0} ** 3;

    var rt = try vigil.runtime(allocator, .{});
    defer rt.deinit();
    try rt.telemetry_emitter.on(.message_dead_lettered, collectDeadLetter);
    try rt.telemetry_emitter.on(.message_replayed, collectReplay);
    try rt.telemetry_emitter.on(.message_discarded, collectDiscard);

    var ib = try rt.inbox(.{ .capacity = 8, .max_delivery_attempts = 3, .default_ttl_ms = null });
    defer ib.close();

    // Generate some lifecycle traffic.
    try ib.send("event-1");
    try ib.send("event-2");
    const first = try ib.recv();
    const notice = try ib.deadLetter(first, .delivery_failed);
    _ = try ib.replayDeadLetter(notice.id);
    const second = try ib.recv();
    const renotice = try ib.deadLetter(second, .delivery_failed);
    _ = try ib.discardDeadLetter(renotice.id);

    const mailbox_metrics = ib.metrics();
    const flow = ib.flowMetrics();
    std.debug.print("vigil_messages_received {d}\n", .{mailbox_metrics.messages_received});
    std.debug.print("vigil_messages_dead_lettered_total {d}\n", .{collector_counts[0]});
    std.debug.print("vigil_messages_replayed_total {d}\n", .{collector_counts[1]});
    std.debug.print("vigil_messages_discarded_total {d}\n", .{collector_counts[2]});
    std.debug.print("vigil_flow_accepted_total {d}\n", .{flow.accepted});
}

/// Distributed registry: two nodes in one process resolving names over real
/// loopback TCP with persistent connections.
fn runDistributedRegistry(allocator: std.mem.Allocator) !void {
    std.debug.print("\n--- distributed registry: two-node resolution ---\n", .{});

    var node_a = try vigil.DistributedRegistry.init(allocator, .{
        .cluster_nodes = &.{},
        .listen_port = 39461,
        .sync_interval_ms = 20,
    });
    defer node_a.deinit();
    var mailbox = vigil.ProcessMailbox.init(allocator, .{ .capacity = 4 });
    defer mailbox.deinit();
    try node_a.register("payments_service", &mailbox, .global);
    try node_a.startSync();
    defer node_a.stopSync();

    var node_b = try vigil.DistributedRegistry.init(allocator, .{
        .cluster_nodes = &.{"127.0.0.1:39461"},
        .listen_port = 39462,
        .sync_interval_ms = 20,
    });
    defer node_b.deinit();

    var found: ?vigil.RemoteProcessInfo = null;
    var waited: u32 = 0;
    while (found == null and waited < 3_000) : (waited += 20) {
        found = node_b.queryPeers("payments_service");
        if (found == null) vigil.compat.sleep(20 * std.time.ns_per_ms);
    }

    if (found) |info| {
        std.debug.print("node B resolved payments_service at {s}:{d}\n", .{ info.node_address, info.node_port });
    } else {
        std.debug.print("resolution failed (port busy?)\n", .{});
        return;
    }

    var state = try node_b.snapshot(allocator);
    defer state.deinit();
    std.debug.print("peer alive={} reconnects={d} queries={d} cache_hits={d}\n", .{
        state.peers[0].is_alive,
        state.peers[0].reconnects,
        state.peer_queries,
        state.cache_hits,
    });
}

/// Pub/sub notification pipeline: one producer fanning out to specialized
/// consumers by topic pattern, using batch publish.
fn runPubSubPipeline(allocator: std.mem.Allocator) !void {
    std.debug.print("\n--- pub/sub pipeline: pattern fanout + batch publish ---\n", .{});

    var rt = try vigil.runtime(allocator, .{});
    defer rt.deinit();
    var broker = vigil.PubSubBroker.init(allocator);
    defer broker.deinit();
    broker.setTelemetryEmitter(&rt.telemetry_emitter);

    var email_inbox = try rt.inbox(.{ .capacity = 128, .default_ttl_ms = null });
    defer email_inbox.close();
    var audit_inbox = try rt.inbox(.{ .capacity = 128, .default_ttl_ms = null });
    defer audit_inbox.close();

    var email = vigil.Subscriber.init(allocator, email_inbox);
    defer email.deinit();
    try email.subscribe(&.{"user.signup"});
    var audit = vigil.Subscriber.init(allocator, audit_inbox);
    defer audit.deinit();
    try audit.subscribe(&.{"user.#"});
    try broker.subscribe(&email);
    try broker.subscribe(&audit);

    // A signup burst goes out in one matching pass per subscriber.
    const burst = [_][]const u8{ "alice", "bob", "carol" };
    _ = try broker.publishBatch("user.signup", &burst);
    _ = try broker.publish("user.deleted", "mallory");

    std.debug.print("email queue: {d} (signups only)\n", .{try email_inbox.queueDepth()});
    std.debug.print("audit queue: {d} (all user events)\n", .{try audit_inbox.queueDepth()});

    var snap = try broker.snapshot(allocator);
    defer snap.deinit();
    std.debug.print("broker: {d} published, {d} delivered, {d} failed\n", .{
        snap.total_publishes,
        snap.total_delivered,
        snap.total_failed,
    });
}

/// Graceful drain: stop accepting, let a consumer finish queued work, run
/// shutdown hooks, and report whether everything drained in time.
fn runGracefulDrain(allocator: std.mem.Allocator) !void {
    std.debug.print("\n--- graceful drain: finish in-flight work, then stop ---\n", .{});

    var rt = try vigil.runtime(allocator, .{});
    defer rt.deinit();
    _ = try rt.timers();

    var ib = try rt.inbox(.{ .capacity = 32, .default_ttl_ms = null });
    defer ib.close();
    try rt.register("drain.work", ib.mailbox);
    for (0..10) |_| try ib.send("in-flight-job");

    const Consumer = struct {
        fn run(target: *vigil.Inbox) void {
            var handled: u32 = 0;
            while (handled < 10) {
                const msg = target.recvTimeout(200) catch return orelse return;
                msg.deinit();
                handled += 1;
                vigil.compat.sleep(5 * std.time.ns_per_ms);
            }
        }
    };
    const consumer = try std.Thread.spawn(.{}, Consumer.run, .{ib});

    std.debug.print("draining with 10 jobs queued...\n", .{});
    const drained = try rt.drain(2_000);
    consumer.join();

    std.debug.print("drained={} accepting={} timers_running={}\n", .{
        drained,
        rt.isRunning(),
        rt.timer_svc.?.snapshot().running,
    });
}
