//! Webhook relay: one cohesive service built on the v2.2 "Operate and
//! Recover" toolkit.
//!
//! The relay drains a queue of outbound webhooks and delivers each one to its
//! destination endpoint. Every delivery attempt runs under a reliability
//! policy (bounded retries with exponential backoff and a deadline), passes
//! through the endpoint's bulkhead so one slow destination cannot absorb every
//! worker, and is guarded by the endpoint's circuit breaker so a dead
//! destination fails fast instead of being hammered.
//!
//! Deliveries that still fail are quarantined in the queue's dead-letter
//! storage, where an operator can inspect them without consuming them, replay
//! them once the endpoint recovers, and discard the ones that turn out to be
//! poison. The whole run leaves an audit trail on the runtime event timeline,
//! and the closing status report comes straight from `Runtime.debugDump()`.
//!
//! Time is simulated, so the demo (and its tests) run instantly and
//! deterministically: every backoff sleep advances a `SimulatedClock` instead
//! of blocking the thread.
//!
//!   zig build run
//!   zig build test

const std = @import("std");
const vigil = @import("vigil");

/// A simulated webhook destination with its own failure schedule, circuit
/// breaker, and delivery bulkhead.
const Endpoint = struct {
    name: []const u8,
    injector: vigil.FaultInjector,
    breaker: vigil.CircuitBreaker,
    bulkhead: vigil.Bulkhead,
    delivered: u32,

    fn init(allocator: std.mem.Allocator, name: []const u8, plan: vigil.FaultPlan) !Endpoint {
        return .{
            .name = name,
            .injector = vigil.FaultInjector.init(plan),
            .breaker = try vigil.CircuitBreaker.init(allocator, name, .{
                .failure_threshold = 5,
                .reset_timeout_ms = 30_000,
            }),
            .bulkhead = try vigil.Bulkhead.init(.{ .max_concurrent = 2 }),
            .delivered = 0,
        };
    }

    fn deinit(self: *Endpoint) void {
        self.breaker.deinit();
    }
};

/// Context for one policy-protected delivery.
const Delivery = struct {
    endpoint: *Endpoint,
    clock: *vigil.SimulatedClock,
    payload: []const u8,

    /// One delivery attempt: take a bulkhead permit, then call the endpoint.
    /// Malformed webhooks fail no matter how healthy the endpoint is.
    fn attempt(ctx: *Delivery) anyerror!void {
        try ctx.endpoint.bulkhead.acquire();
        defer ctx.endpoint.bulkhead.release();

        if (std.mem.indexOf(u8, ctx.payload, "malformed") != null) {
            return error.MalformedPayload;
        }
        try ctx.endpoint.injector.call();
    }

    fn clockHook(ctx: *Delivery) i64 {
        return ctx.clock.now();
    }

    fn sleepHook(ctx: *Delivery, nanoseconds: u64) void {
        ctx.clock.sleep(nanoseconds);
    }
};

/// The delivery policy every webhook runs under: three attempts with
/// exponential backoff, a hard deadline, and the endpoint's circuit breaker.
fn deliveryOptions(breaker: *vigil.CircuitBreaker) vigil.PolicyOptions(Delivery, void) {
    return .{
        .retry = .{
            .max_attempts = 3,
            .backoff = .{ .exponential = .{ .initial_ms = 100, .multiplier = 2, .max_ms = 1_000 } },
        },
        .timeout_ms = 10_000,
        .circuit_breaker = breaker,
        .clock = Delivery.clockHook,
        .sleeper = Delivery.sleepHook,
    };
}

const DispatchOutcome = struct {
    delivered: usize = 0,
    dead_lettered: usize = 0,
};

fn endpointFor(endpoints: []const *Endpoint, payload: []const u8) ?*Endpoint {
    const sep = std.mem.indexOfScalar(u8, payload, ':') orelse return null;
    for (endpoints) |endpoint| {
        if (std.mem.eql(u8, endpoint.name, payload[0..sep])) return endpoint;
    }
    return null;
}

/// Drain the queue once. Successful deliveries are counted per endpoint;
/// failures are quarantined in the queue's dead-letter storage.
fn dispatchQueue(
    queue: *vigil.Inbox,
    endpoints: []const *Endpoint,
    clock: *vigil.SimulatedClock,
    verbose: bool,
) !DispatchOutcome {
    var outcome = DispatchOutcome{};

    while (try queue.recvTimeout(5)) |msg| {
        const payload = msg.payload orelse {
            msg.deinit();
            continue;
        };
        const endpoint = endpointFor(endpoints, payload) orelse {
            msg.deinit();
            continue;
        };

        var delivery = Delivery{ .endpoint = endpoint, .clock = clock, .payload = payload };
        const result = vigil.executePolicy(Delivery, void, &delivery, Delivery.attempt, deliveryOptions(&endpoint.breaker));

        switch (result) {
            .success, .fallback => |success| {
                endpoint.delivered += 1;
                outcome.delivered += 1;
                if (verbose) std.debug.print("delivered {s} ({d} attempt(s), {d}ms)\n", .{
                    payload,
                    success.report.attempts,
                    success.report.elapsed_ms,
                });
                msg.deinit();
            },
            .circuit_open => |failure| {
                if (verbose) std.debug.print("fail-fast {s}: circuit open after {d} attempt(s), endpoint spared\n", .{
                    payload,
                    failure.attempts,
                });
                _ = try queue.deadLetter(msg, .delivery_failed);
                outcome.dead_lettered += 1;
            },
            .timeout, .permanent_failure => |failure| {
                if (verbose) std.debug.print("failed {s}: {s} after {d} attempt(s)\n", .{
                    payload,
                    @tagName(failure.outcome),
                    failure.attempts,
                });
                _ = try queue.deadLetter(msg, .delivery_failed);
                outcome.dead_lettered += 1;
            },
        }
    }
    return outcome;
}

fn printEndpointStatus(endpoints: []const *Endpoint) void {
    for (endpoints) |endpoint| {
        const breaker = endpoint.breaker.snapshot();
        const pool = endpoint.bulkhead.snapshot();
        std.debug.print("  {s}: breaker={s} (opened {d}x, {d} lifetime failures)  pool={d}/{d} in flight ({d} rejected)  delivered={d}\n", .{
            endpoint.name,
            @tagName(breaker.state),
            breaker.open_transitions,
            breaker.total_failures,
            pool.in_flight,
            pool.max_concurrent,
            pool.total_rejected,
            endpoint.delivered,
        });
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    std.debug.print("\n=== webhook relay: operate and recover, end to end ===\n\n", .{});

    var rt = try vigil.runtime(allocator, .{});
    defer rt.deinit();
    try rt.enableTimeline(32);

    var queue = try rt.inbox(.{
        .capacity = 16,
        .dead_letter_capacity = 16,
        .max_delivery_attempts = 2,
        .default_ttl_ms = null,
    });
    defer queue.close();
    try rt.register("webhooks.outbound", queue.mailbox);

    // billing hiccups on every second call, so retries visibly earn their
    // keep; analytics is hard down until the operator "fixes" it.
    var billing = try Endpoint.init(allocator, "billing", .{ .fail_every = 2, .error_value = error.EndpointHiccup });
    defer billing.deinit();
    var analytics = try Endpoint.init(allocator, "analytics", .{ .fail_first = 100, .error_value = error.EndpointDown });
    defer analytics.deinit();
    const endpoints = [_]*Endpoint{ &billing, &analytics };

    var clock = vigil.SimulatedClock.init(0);

    // --- Phase 1: dispatch with analytics down --------------------------------
    std.debug.print("--- phase 1: dispatch (analytics is down) ---\n", .{});
    for ([_][]const u8{
        "billing:invoice.created#1001",
        "billing:invoice.paid#1002",
        "analytics:signup#2001",
        "analytics:pageview#2002",
        "analytics:malformed#2003",
    }) |webhook| {
        try queue.send(webhook);
    }

    const first_pass = try dispatchQueue(queue, &endpoints, &clock, true);
    std.debug.print("phase 1: {d} delivered, {d} quarantined ({d}ms simulated)\n\n", .{
        first_pass.delivered,
        first_pass.dead_lettered,
        clock.now(),
    });

    // Burst protection: with the delivery pool saturated, further calls are
    // rejected immediately instead of queueing behind a slow endpoint.
    try billing.bulkhead.acquire();
    try billing.bulkhead.acquire();
    var burst = Delivery{ .endpoint = &billing, .clock = &clock, .payload = "billing:burst#1003" };
    const rejected = Delivery.attempt(&burst);
    std.debug.print("burst probe with saturated pool: {!}\n\n", .{rejected});
    billing.bulkhead.release();
    billing.bulkhead.release();

    // --- Phase 2: operator view ------------------------------------------------
    std.debug.print("--- phase 2: operator inspects the damage ---\n", .{});
    printEndpointStatus(&endpoints);

    var retained = try queue.deadLetters(allocator);
    defer retained.deinit();
    std.debug.print("quarantined webhooks ({d}):\n", .{retained.entries.len});
    for (retained.entries) |entry| {
        std.debug.print("  #{d} {s} (attempts={d}, poisoned={})\n", .{
            entry.id,
            entry.message.payload orelse "<signal>",
            entry.message.metadata.attempt_count,
            entry.poisoned,
        });
    }
    std.debug.print("\n", .{});

    // --- Phase 3: recovery and replay -------------------------------------------
    std.debug.print("--- phase 3: analytics recovers; operator replays ---\n", .{});
    analytics.injector = vigil.FaultInjector.init(.{});
    analytics.breaker.forceClose();

    for (retained.entries) |entry| {
        const replayed = try queue.replayDeadLetter(entry.id);
        std.debug.print("replay #{d}: {s}\n", .{ entry.id, @tagName(replayed.status) });
    }

    const second_pass = try dispatchQueue(queue, &endpoints, &clock, true);
    std.debug.print("phase 3: {d} delivered, {d} still failing\n\n", .{
        second_pass.delivered,
        second_pass.dead_lettered,
    });

    // The malformed webhook failed on its second delivery attempt, so it is
    // now classified as poison: replay refuses it and the operator discards.
    var still_retained = try queue.deadLetters(allocator);
    defer still_retained.deinit();
    for (still_retained.entries) |entry| {
        const refused = try queue.replayDeadLetter(entry.id);
        std.debug.print("replay #{d} ({s}): {s}\n", .{
            entry.id,
            entry.message.payload orelse "<signal>",
            @tagName(refused.status),
        });
    }
    const discarded = try queue.discardAllDeadLetters();
    std.debug.print("discarded {d} poison webhook(s)\n\n", .{discarded});

    // --- Phase 4: status report --------------------------------------------------
    std.debug.print("--- phase 4: status report ---\n", .{});
    printEndpointStatus(&endpoints);
    std.debug.print("\n", .{});

    const dump = try rt.debugDump(allocator);
    defer allocator.free(dump);
    std.debug.print("{s}", .{dump});
}

// --- tests: the same logic, deterministic and instant -------------------------

test "delivery retries are deterministic on the simulated clock" {
    var endpoint = try Endpoint.init(std.testing.allocator, "flaky", .{ .fail_first = 2 });
    defer endpoint.deinit();
    var clock = vigil.SimulatedClock.init(0);

    var delivery = Delivery{ .endpoint = &endpoint, .clock = &clock, .payload = "flaky:evt#1" };
    const result = vigil.executePolicy(Delivery, void, &delivery, Delivery.attempt, deliveryOptions(&endpoint.breaker));

    switch (result) {
        .success => |success| {
            try std.testing.expectEqual(@as(u32, 3), success.report.attempts);
            try std.testing.expectEqual(@as(u32, 2), success.report.retries);
            // Exponential backoff: 100ms + 200ms, all simulated, none slept.
            try std.testing.expectEqual(@as(i64, 300), success.report.elapsed_ms);
            try std.testing.expectEqual(@as(i64, 300), clock.now());
        },
        else => return error.ExpectedSuccess,
    }

    // Every attempt took and returned a bulkhead permit.
    const pool = endpoint.bulkhead.snapshot();
    try std.testing.expectEqual(@as(u32, 0), pool.in_flight);
    try std.testing.expectEqual(@as(u64, 3), pool.total_admitted);
}

test "failed webhooks are quarantined, replayable, and poison is refused" {
    const allocator = std.testing.allocator;

    var rt = try vigil.runtime(allocator, .{});
    defer rt.deinit();
    var queue = try rt.inbox(.{
        .capacity = 8,
        .dead_letter_capacity = 8,
        .max_delivery_attempts = 2,
        .default_ttl_ms = null,
    });
    defer queue.close();

    var endpoint = try Endpoint.init(allocator, "crm", .{ .fail_first = 100 });
    defer endpoint.deinit();
    const endpoints = [_]*Endpoint{&endpoint};
    var clock = vigil.SimulatedClock.init(0);

    // Down endpoint: both webhooks end up quarantined, nothing delivered.
    try queue.send("crm:contact.created#1");
    try queue.send("crm:malformed#2");
    const down = try dispatchQueue(queue, &endpoints, &clock, false);
    try std.testing.expectEqual(@as(usize, 0), down.delivered);
    try std.testing.expectEqual(@as(usize, 2), down.dead_lettered);
    try std.testing.expectEqual(@as(usize, 2), try queue.deadLetterCount());

    // Recovery: replay everything; the healthy webhook delivers, the
    // malformed one fails its second attempt and is now poison.
    endpoint.injector = vigil.FaultInjector.init(.{});
    endpoint.breaker.forceClose();

    var retained = try queue.deadLetters(allocator);
    defer retained.deinit();
    for (retained.entries) |entry| {
        const replayed = try queue.replayDeadLetter(entry.id);
        try std.testing.expectEqual(vigil.DeadLetterReplayStatus.replayed, replayed.status);
    }

    const recovered = try dispatchQueue(queue, &endpoints, &clock, false);
    try std.testing.expectEqual(@as(usize, 1), recovered.delivered);
    try std.testing.expectEqual(@as(usize, 1), recovered.dead_lettered);

    // The survivor is poisoned: replay refuses it, discard removes it.
    var poisoned = try queue.deadLetters(allocator);
    defer poisoned.deinit();
    try std.testing.expectEqual(@as(usize, 1), poisoned.entries.len);
    try std.testing.expect(poisoned.entries[0].poisoned);
    const refused = try queue.replayDeadLetter(poisoned.entries[0].id);
    try std.testing.expectEqual(vigil.DeadLetterReplayStatus.poison, refused.status);
    try std.testing.expectEqual(@as(usize, 1), try queue.discardAllDeadLetters());
    try std.testing.expectEqual(@as(usize, 0), try queue.deadLetterCount());
}

test "a dead endpoint trips the breaker and later webhooks fail fast" {
    const allocator = std.testing.allocator;

    var rt = try vigil.runtime(allocator, .{});
    defer rt.deinit();
    var queue = try rt.inbox(.{
        .capacity = 8,
        .dead_letter_capacity = 8,
        .max_delivery_attempts = 3,
        .default_ttl_ms = null,
    });
    defer queue.close();

    var endpoint = try Endpoint.init(allocator, "dead", .{ .fail_first = 100 });
    defer endpoint.deinit();
    const endpoints = [_]*Endpoint{&endpoint};
    var clock = vigil.SimulatedClock.init(0);

    // Three webhooks at three attempts each would be nine calls; the breaker
    // (threshold 5) opens partway through, so later webhooks are rejected
    // without touching the endpoint at all.
    try queue.send("dead:evt#1");
    try queue.send("dead:evt#2");
    try queue.send("dead:evt#3");
    const outcome = try dispatchQueue(queue, &endpoints, &clock, false);
    try std.testing.expectEqual(@as(usize, 3), outcome.dead_lettered);

    try std.testing.expectEqual(vigil.CircuitState.open, endpoint.breaker.getState());
    try std.testing.expect(endpoint.injector.callCount() < 9);

    const diagnostics = endpoint.breaker.snapshot();
    try std.testing.expectEqual(@as(u32, 1), diagnostics.open_transitions);
    try std.testing.expect(diagnostics.last_transition_time_ms > 0);
}
