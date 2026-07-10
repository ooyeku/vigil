const std = @import("std");
const vigil = @import("vigil");

const OrderStatus = enum {
    fulfilled,
    rejected,
    throttled,
    dependency_unavailable,
};

const PaymentDecision = enum {
    authorized,
    unavailable,
};

const Order = struct {
    id: []const u8,
    customer: []const u8,
    amount_cents: u32,
    priority: vigil.MessagePriority,
    inventory_ok: bool,
    payment_ok: bool,
};

const Summary = struct {
    accepted: usize = 0,
    fulfilled: usize = 0,
    rejected: usize = 0,
    throttled: usize = 0,
    dependency_unavailable: usize = 0,
    routed_jobs: usize = 0,
    published_deliveries: usize = 0,
    audit_messages: usize = 0,
    alert_messages: usize = 0,

    fn terminalCount(self: Summary) usize {
        return self.fulfilled + self.rejected + self.throttled + self.dependency_unavailable;
    }
};

const PaymentAttempt = struct {
    gateway_available: bool,

    fn authorize(self: *PaymentAttempt) anyerror!PaymentDecision {
        if (!self.gateway_available) return error.PaymentGatewayUnavailable;
        return .authorized;
    }

    fn fallback(_: *PaymentAttempt, _: vigil.PolicyFailure) anyerror!PaymentDecision {
        return .unavailable;
    }
};

const PaymentPolicyResult = struct {
    decision: PaymentDecision,
    report: vigil.PolicyReport,
};

fn riskBand(order: Order) []const u8 {
    if (!order.payment_ok) return "payment-risk";
    if (!order.inventory_ok) return "inventory-risk";
    if (order.amount_cents >= 50_000) return "high-value";
    return "standard";
}

fn eventTopic(status: OrderStatus) []const u8 {
    return switch (status) {
        .fulfilled => "orders.fulfilled",
        .rejected => "orders.failed",
        .throttled => "system.alert",
        .dependency_unavailable => "orders.failed",
    };
}

fn shouldEmitCircuitOpened(previous: vigil.CircuitState, current: vigil.CircuitState) bool {
    return previous != .open and current == .open;
}

fn telemetryPrinter(event: vigil.telemetry.Event) void {
    std.debug.print("  telemetry: {s}", .{@tagName(event.event_type)});
    if (event.metadata) |metadata| {
        std.debug.print(" ({s})", .{metadata});
    }
    std.debug.print("\n", .{});
}

fn shutdownHook() void {
    std.debug.print("  shutdown: closed showcase runtime services\n", .{});
}

fn emit(rt: *vigil.Runtime, event_type: vigil.telemetry.EventType, metadata: []const u8) void {
    rt.telemetry_emitter.emit(.{
        .event_type = event_type,
        .timestamp_ms = 0,
        .metadata = metadata,
    });
}

fn publish(
    broker: *vigil.pubsub.PubSubBroker,
    summary: *Summary,
    topic: []const u8,
    payload: []const u8,
) !void {
    const result = try broker.publish(topic, payload);
    summary.published_deliveries += result.delivered;
    std.debug.print("  pubsub: {s} -> {d} subscriber(s)\n", .{ topic, result.delivered });
}

fn drainInbox(name: []const u8, inbox: *vigil.Inbox) !usize {
    var drained: usize = 0;
    while (try inbox.recvTimeout(1)) |msg| {
        var owned = msg;
        defer owned.deinit();

        drained += 1;
        std.debug.print("  {s}: {s}\n", .{ name, owned.payload orelse "<signal>" });
    }
    return drained;
}

fn paymentPolicyReport(result: vigil.PolicyResult(PaymentDecision)) PaymentPolicyResult {
    return switch (result) {
        .success => |success| .{
            .decision = success.value,
            .report = success.report,
        },
        .fallback => |fallback| .{
            .decision = fallback.value,
            .report = fallback.report,
        },
        .timeout => |failure| .{
            .decision = .unavailable,
            .report = failure.report(),
        },
        .circuit_open => |failure| .{
            .decision = .unavailable,
            .report = failure.report(),
        },
        .permanent_failure => |failure| .{
            .decision = .unavailable,
            .report = failure.report(),
        },
    };
}

fn processOrder(
    rt: *vigil.Runtime,
    broker: *vigil.pubsub.PubSubBroker,
    fulfillment_group: *vigil.ProcessGroup,
    intake: *vigil.Inbox,
    limiter: *vigil.RateLimiter,
    payment_breaker: *vigil.CircuitBreaker,
    summary: *Summary,
    order: Order,
) !void {
    var envelope = try vigil.msg(order.id)
        .from("checkout-api")
        .priority(order.priority)
        .ttl(30_000)
        .withCorrelation(order.id)
        .replyTo("orders.intake")
        .build(rt.allocator);
    defer envelope.deinit();

    try intake.send(envelope.payload.?);
    emit(rt, .message_sent, order.id);

    std.debug.print(
        "order {s:<7} customer={s:<6} amount=${d}.{d:0>2} risk={s}\n",
        .{
            order.id,
            order.customer,
            order.amount_cents / 100,
            order.amount_cents % 100,
            riskBand(order),
        },
    );

    if (!limiter.allow()) {
        summary.throttled += 1;
        try publish(broker, summary, eventTopic(.throttled), "checkout pressure: intake throttled");
        std.debug.print("  decision: throttled before payment\n", .{});
        return;
    }

    summary.accepted += 1;

    var payment_attempt = PaymentAttempt{ .gateway_available = order.payment_ok };
    const previous_state = payment_breaker.getState();
    const payment_result = vigil.executePolicy(
        PaymentAttempt,
        PaymentDecision,
        &payment_attempt,
        PaymentAttempt.authorize,
        .{
            .retry = .{
                .max_attempts = 2,
                .backoff = .{ .exponential = .{
                    .initial_ms = 2,
                    .multiplier = 2,
                    .max_ms = 8,
                } },
            },
            .timeout_ms = 250,
            .circuit_breaker = payment_breaker,
            .fallback = PaymentAttempt.fallback,
        },
    );
    const payment = paymentPolicyReport(payment_result);
    const current_state = payment_breaker.getState();

    if (shouldEmitCircuitOpened(previous_state, current_state)) {
        emit(rt, .circuit_opened, "payment-gateway");
    }

    if (payment.decision == .unavailable) {
        summary.dependency_unavailable += 1;
        try publish(broker, summary, eventTopic(.dependency_unavailable), "payment circuit open");
        const fallback_from = payment.report.fallback_from orelse payment.report.outcome;
        std.debug.print(
            "  decision: payment unavailable via policy outcome={s} fallback_from={s} attempts={d} retries={d}\n",
            .{ @tagName(payment.report.outcome), @tagName(fallback_from), payment.report.attempts, payment.report.retries },
        );
        return;
    }

    if (!order.inventory_ok) {
        summary.rejected += 1;
        try publish(broker, summary, eventTopic(.rejected), "inventory reservation failed");
        std.debug.print("  decision: rejected by inventory service\n", .{});
        return;
    }

    try fulfillment_group.roundRobin(order.id);
    summary.routed_jobs += 1;
    summary.fulfilled += 1;
    try publish(broker, summary, eventTopic(.fulfilled), order.id);
    std.debug.print("  decision: routed to fulfillment group\n", .{});
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    std.debug.print("\n=== Vigil Showcase: resilient order pipeline ===\n\n", .{});

    var rt = try vigil.runtime(allocator, .{});
    defer rt.deinit();
    try rt.telemetry_emitter.on(.message_sent, telemetryPrinter);
    try rt.telemetry_emitter.on(.message_dead_lettered, telemetryPrinter);
    try rt.telemetry_emitter.on(.message_replayed, telemetryPrinter);
    try rt.telemetry_emitter.on(.poison_message_detected, telemetryPrinter);
    try rt.telemetry_emitter.on(.circuit_opened, telemetryPrinter);
    try rt.onShutdown(shutdownHook);

    var intake = try rt.inbox(.{ .capacity = 8 });
    defer intake.close();

    var fulfillment_a = try rt.inbox(.{ .capacity = 8 });
    defer fulfillment_a.close();

    var fulfillment_b = try rt.inbox(.{ .capacity = 8 });
    defer fulfillment_b.close();

    var audit = try vigil.inboxBuilder(allocator)
        .capacity(8)
        .withBackpressure(.{
            .strategy = .drop_oldest,
            .high_watermark = 6,
            .low_watermark = 3,
        })
        .build();
    defer audit.close();

    var alerts = try rt.inbox(.{ .capacity = 8 });
    defer alerts.close();

    var recovery = try rt.inbox(.{
        .capacity = 1,
        .dead_letter_capacity = 8,
        .max_delivery_attempts = 3,
    });
    defer recovery.close();

    try rt.register("orders.intake", intake.mailbox);
    try rt.register("orders.fulfillment.a", fulfillment_a.mailbox);
    try rt.register("orders.fulfillment.b", fulfillment_b.mailbox);
    try rt.register("ops.audit", audit.mailbox);
    try rt.register("ops.alerts", alerts.mailbox);
    try rt.register("ops.recovery", recovery.mailbox);

    var fulfillment_group = try vigil.ProcessGroup.init(allocator, "fulfillment");
    defer fulfillment_group.deinit();
    try fulfillment_group.add("pack-a", fulfillment_a);
    try fulfillment_group.add("pack-b", fulfillment_b);

    var ops_group = try vigil.ProcessGroup.init(allocator, "operations");
    defer ops_group.deinit();
    try ops_group.add("audit", audit);
    try ops_group.add("alerts", alerts);

    var broker = vigil.pubsub.PubSubBroker.init(allocator);
    defer broker.deinit();

    var audit_sub = vigil.Subscriber.init(allocator, audit);
    defer audit_sub.deinit();
    try audit_sub.subscribe(&[_][]const u8{ "orders.#", "system.#" });
    try broker.subscribe(&audit_sub);

    var alert_sub = vigil.Subscriber.init(allocator, alerts);
    defer alert_sub.deinit();
    try alert_sub.subscribe(&[_][]const u8{ "orders.failed", "system.alert" });
    try broker.subscribe(&alert_sub);

    var limiter = vigil.RateLimiter.init(6);
    var payment_breaker = try vigil.CircuitBreaker.init(allocator, "payment-gateway", .{
        .failure_threshold = 2,
        .reset_timeout_ms = 1_000,
    });
    defer payment_breaker.deinit();

    var summary = Summary{};
    const boot = try ops_group.broadcast("system boot: order pipeline online");
    std.debug.print("operations broadcast delivered to {d} inbox(es)\n\n", .{boot.delivered});

    const orders = [_]Order{
        .{ .id = "ord-001", .customer = "ada", .amount_cents = 12_499, .priority = .normal, .inventory_ok = true, .payment_ok = true },
        .{ .id = "ord-002", .customer = "linus", .amount_cents = 72_000, .priority = .high, .inventory_ok = true, .payment_ok = true },
        .{ .id = "ord-003", .customer = "grace", .amount_cents = 4_299, .priority = .normal, .inventory_ok = false, .payment_ok = true },
        .{ .id = "ord-004", .customer = "marg", .amount_cents = 9_900, .priority = .high, .inventory_ok = true, .payment_ok = false },
        .{ .id = "ord-005", .customer = "kath", .amount_cents = 31_500, .priority = .normal, .inventory_ok = true, .payment_ok = false },
        .{ .id = "ord-006", .customer = "alan", .amount_cents = 6_500, .priority = .normal, .inventory_ok = true, .payment_ok = true },
        .{ .id = "ord-007", .customer = "barb", .amount_cents = 2_100, .priority = .low, .inventory_ok = true, .payment_ok = true },
    };

    for (orders) |order| {
        try processOrder(&rt, &broker, &fulfillment_group, intake, &limiter, &payment_breaker, &summary, order);
        std.debug.print("\n", .{});
    }

    try recovery.send("primary job");
    try recovery.send("retained recovery job");
    var dead_letters = try recovery.deadLetters(allocator);
    const recovery_id = dead_letters.entries[0].id;
    std.debug.print("dead-letter recovery: retained={d} id={d}\n", .{ dead_letters.entries.len, recovery_id });
    dead_letters.deinit();

    var primary_job = try recovery.recv();
    primary_job.deinit();
    const replay = try recovery.replayDeadLetter(recovery_id);
    std.debug.print("dead-letter recovery: replay={s}\n\n", .{@tagName(replay.status)});
    var recovered_job = try recovery.recv();
    recovered_job.deinit();

    std.debug.print("registry lookup: orders.intake is {s}\n\n", .{
        if (rt.whereis("orders.intake") != null) "registered" else "missing",
    });

    std.debug.print("fulfillment inboxes:\n", .{});
    _ = try drainInbox("  pack-a", fulfillment_a);
    _ = try drainInbox("  pack-b", fulfillment_b);

    std.debug.print("\naudit stream (drop-oldest backpressure keeps newest signals):\n", .{});
    summary.audit_messages = try drainInbox("  audit", audit);

    std.debug.print("\nalert stream:\n", .{});
    summary.alert_messages = try drainInbox("  alerts", alerts);

    std.debug.print(
        \\
        \\summary:
        \\  accepted={d}
        \\  fulfilled={d}
        \\  rejected={d}
        \\  throttled={d}
        \\  dependency_unavailable={d}
        \\  routed_jobs={d}
        \\  pubsub_deliveries={d}
        \\  audit_messages={d}
        \\  alert_messages={d}
        \\  terminal_outcomes={d}
        \\
    , .{
        summary.accepted,
        summary.fulfilled,
        summary.rejected,
        summary.throttled,
        summary.dependency_unavailable,
        summary.routed_jobs,
        summary.published_deliveries,
        summary.audit_messages,
        summary.alert_messages,
        summary.terminalCount(),
    });

    rt.shutdown();
}

test "riskBand classifies operational risk" {
    const standard = Order{ .id = "a", .customer = "c", .amount_cents = 4_200, .priority = .normal, .inventory_ok = true, .payment_ok = true };
    const high_value = Order{ .id = "b", .customer = "c", .amount_cents = 50_000, .priority = .high, .inventory_ok = true, .payment_ok = true };
    const inventory = Order{ .id = "c", .customer = "c", .amount_cents = 1_000, .priority = .normal, .inventory_ok = false, .payment_ok = true };
    const payment = Order{ .id = "d", .customer = "c", .amount_cents = 1_000, .priority = .normal, .inventory_ok = true, .payment_ok = false };

    try std.testing.expectEqualStrings("standard", riskBand(standard));
    try std.testing.expectEqualStrings("high-value", riskBand(high_value));
    try std.testing.expectEqualStrings("inventory-risk", riskBand(inventory));
    try std.testing.expectEqualStrings("payment-risk", riskBand(payment));
}

test "eventTopic maps terminal status to domain events" {
    try std.testing.expectEqualStrings("orders.fulfilled", eventTopic(.fulfilled));
    try std.testing.expectEqualStrings("orders.failed", eventTopic(.rejected));
    try std.testing.expectEqualStrings("system.alert", eventTopic(.throttled));
    try std.testing.expectEqualStrings("orders.failed", eventTopic(.dependency_unavailable));
}

test "shouldEmitCircuitOpened only reports the transition into open" {
    try std.testing.expect(shouldEmitCircuitOpened(.closed, .open));
    try std.testing.expect(shouldEmitCircuitOpened(.half_open, .open));
    try std.testing.expect(!shouldEmitCircuitOpened(.closed, .closed));
    try std.testing.expect(!shouldEmitCircuitOpened(.open, .open));
}

test "payment fallback maps dependency failures to unavailable decisions" {
    var attempt = PaymentAttempt{ .gateway_available = false };
    const failure = vigil.PolicyFailure{
        .outcome = .permanent_failure,
        .attempts = 2,
        .retries = 1,
        .elapsed_ms = 0,
        .last_error = error.PaymentGatewayUnavailable,
    };

    try std.testing.expectEqual(PaymentDecision.unavailable, try PaymentAttempt.fallback(&attempt, failure));
}

test "Summary terminalCount includes every terminal outcome" {
    const summary = Summary{
        .fulfilled = 3,
        .rejected = 2,
        .throttled = 1,
        .dependency_unavailable = 4,
    };
    try std.testing.expectEqual(@as(usize, 10), summary.terminalCount());
}
