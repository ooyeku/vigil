# Vigil API Reference v3.0.0

Task-oriented guides:

- [Migration from 2.x](migration-3.0.md)
- [Performance tuning](performance-tuning.md)
- [Reliability patterns](reliability-patterns.md)
- [Introspection and debugging](debugging.md)
- [Distributed systems](distributed.md)
- [Checkpointing and recovery](checkpointing.md)
- [Roadmap](roadmap.md)

A process supervision and inter-process communication library for Zig, inspired by Erlang/OTP.

## Table of Contents

- [Quick Start](#quick-start)
- [Runtime](#runtime)
- [Core API](#core-api)
  - [Message Builder](#message-builder)
  - [Inbox API](#inbox-api)
  - [Inbox Builder](#inbox-builder)
  - [Supervisor Builder](#supervisor-builder)
  - [Supervisor Introspection](#supervisor-introspection)
  - [App Builder](#app-builder)
- [Resilience](#resilience)
  - [Reliability Policy](#reliability-policy)
  - [Circuit Breaker](#circuit-breaker)
  - [Bulkhead](#bulkhead)
  - [Rate Limiter](#rate-limiter)
  - [Backpressure](#backpressure)
- [Messaging](#messaging)
  - [Process Groups](#process-groups)
  - [Pub/Sub](#pubsub)
  - [Request/Reply](#requestreply)
- [Observability](#observability)
  - [Telemetry](#telemetry)
  - [Testing Utilities](#testing-utilities)
- [Advanced](#advanced)
  - [Graceful Shutdown](#graceful-shutdown)
  - [State Checkpointing](#state-checkpointing)
  - [Distributed Registry](#distributed-registry)
  - [Registry](#registry)
  - [Timer](#timer)
  - [Timer Service](#timer-service)
- [Configuration Presets](#configuration-presets)
- [Low-Level API](#low-level-api)
- [Types Reference](#types-reference)
- [Error Handling](#error-handling)

---

## Quick Start

```zig
const std = @import("std");
const vigil = @import("vigil");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create application with workers
    var app = try vigil.app(allocator);
    defer app.shutdown();
    _ = try app.worker("service", serviceFunction);
    _ = try app.workerPool("handlers", handlerFunction, 4);
    try app.start();
}

fn serviceFunction() void {
    // Your service logic
}

fn handlerFunction() void {
    // Your handler logic
}
```

---

## Runtime

`Runtime` owns the common process-system services that were previously reached through scattered global helpers: registry, telemetry, shutdown hooks, inbox construction, and supervisor construction.

```zig
var rt = try vigil.runtime(allocator, .{});
defer rt.deinit();

var inbox = try rt.inbox(.{ .capacity = 128 });
defer inbox.close();

try inbox.send("hello");

var snapshot = try rt.snapshot(allocator);
defer snapshot.deinit();

const health = try rt.health(allocator);
if (!health.ready) {
    // Surface degraded runtime state in your status endpoint.
}

if (rt.whereis("worker")) |mailbox| {
    _ = mailbox;
}
```

| Method | Description |
|--------|-------------|
| `runtime(allocator, options)` | Create an owned runtime |
| `deinit()` | Release owned registry, telemetry, and shutdown resources |
| `inbox(options)` | Create an inbox using runtime allocator |
| `supervisor()` | Create a supervisor builder using runtime options |
| `register(name, mailbox)` | Register a mailbox in the runtime registry |
| `whereis(name)` | Look up a registered mailbox |
| `snapshot(allocator)` | Capture registered mailbox stats, active/dead-letter/poison counts, handler count, and hook count |
| `health(allocator)` | Return compact health/readiness status |
| `healthWithCircuitBreakers(allocator, breakers)` | Return readiness with caller-owned circuit breakers folded in |
| `inboxWithProfile(profile, capacity)` | Create an inbox from a `safe`/`balanced`/`throughput` profile |
| `timers()` | Lazily create the runtime-owned timer service |
| `enableTimeline(capacity)` / `timelineSnapshot(allocator)` | Record and inspect recent telemetry events |
| `debugDump(allocator)` | Render a human-readable runtime state dump |
| `onShutdown(hook)` | Register a shutdown hook |
| `shutdown()` | Mark runtime stopped, stop owned services, and run shutdown hooks |

### Runtime Profiles

Profiles choose how much mailbox machinery an inbox carries, trading features
for hot-path cost:

| Profile | Priority queues | Dead-letter | Default TTL | Use for |
|---------|-----------------|-------------|-------------|---------|
| `.safe` | yes | yes | 30s | Defaults; every delivery guarantee |
| `.balanced` | yes | yes | none | Most services; skips expiry bookkeeping |
| `.throughput` | no | no | none | Hot pipeline stages that handle retry themselves |

```zig
var fast = try rt.inboxWithProfile(.throughput, 1024);
defer fast.close();
```

**Which API should I use?** Prefer the ergonomic APIs (`Inbox.send`/`recv`,
`.safe`/`.balanced` profiles) until a profiler says otherwise — they are
already allocation-light and wake receivers without polling. Reach for the
fast paths (`.throughput` profile, `tryRecv`, `recvBatch`, `sendBatch`,
`publishBatch`, `broadcastBatch`, `RateLimiter.allowN`) on measured hot
loops: they trade dead-letter recovery, priorities, and TTLs for fewer
branches and amortized locking.

### Runtime Introspection

`Runtime.snapshot()` returns an owned snapshot for debugging and health endpoints.
It includes whether the runtime is running, registered process names, mailbox
queue depth, mailbox capacity, mailbox stats, retained dead-letter and poison
counts, telemetry handler count, and shutdown hook count. Call `deinit()` on
the snapshot when finished.

`Runtime.health()` returns a compact readiness summary. A running runtime is
`healthy` when registered inboxes are below capacity and have no poison
messages, `degraded` when one or more registered inboxes are full or retain
poison messages, and `stopped` after shutdown.
Use `Runtime.healthWithCircuitBreakers()` when an app wants readiness to also
account for caller-owned dependency circuit breakers; open breakers degrade the
report and set `ready` to false.

Standalone runtime primitives expose focused snapshots too:

- `ProcessGroup.snapshot(allocator)` reports group name, members, queue depth, and closed inbox state.
- `PubSubBroker.snapshot(allocator)` reports subscriber count, total pattern count, copied topic patterns per subscriber, queue depth, and closed inbox state.
- `CircuitBreaker.snapshot()` reports breaker state, counters, timestamps, thresholds, and diagnostics: last transition time, lifetime open transitions, and lifetime failure/success totals.
- `Supervisor.snapshot(allocator)` reports supervisor state, strategy, uptime, and per-child state and restart counts.
- `Timer.snapshot()` reports active, cancelled, repeat, and interval state.
- `ReplyMailbox.snapshot()` reports pending correlation ids and stashed messages.

### Debug-Layer Introspection

The debug layer answers "what is my runtime doing right now?" without
consuming messages or attaching a log pipeline.

```zig
var rt = try vigil.runtime(allocator, .{});
defer rt.deinit();

// Record every event emitted through the runtime telemetry emitter into a
// bounded timeline (runtime-owned; freed by deinit()).
try rt.enableTimeline(64);

// ... application activity ...

// Recent notable events, oldest first.
if (try rt.timelineSnapshot(allocator)) |snapshot_const| {
    var snapshot = snapshot_const;
    defer snapshot.deinit();
    for (snapshot.entries) |entry| {
        std.debug.print("#{d} {s}\n", .{ entry.sequence, @tagName(entry.event_type) });
    }
}

// One human-readable dump with health, per-inbox stats, and the timeline —
// ready to serve from a STATUS command or debug endpoint.
const dump = try rt.debugDump(allocator);
defer allocator.free(dump);
```

Non-consuming inspection is available on inboxes and routing primitives:

- `Inbox.peekMessages(allocator)` / `ProcessMailbox.snapshotQueue(allocator)` return queued-message summaries (id, sender, priority, payload size, attempts, TTL) in delivery order without consuming anything.
- `ProcessGroup.routeIndexForKey(key)` and `ProcessGroup.routeMemberForKey(allocator, key)` preview which member a keyed `route()` would pick.
- `Subscriber.snapshotPatterns(allocator)` returns owned copies of a subscriber's topic patterns.
- `EventTimeline` can also be used standalone: `attachTimeline()` on any `TelemetryEmitter` records emitted events into a bounded, thread-safe buffer.

### Migrating from the legacy API

Use `vigil.inboxBuilder`, `vigil.supervisor`, `vigil.Runtime`, and the other
owned root APIs for current code. `vigil/legacy` is a deprecated, reduced set of
type aliases for migrations; obsolete worker, configuration, and
supervision-tree APIs are no longer shipped.

---

## Core API

### Message Builder

Create messages with a fluent, chainable API.

```zig
var msg = try vigil.msg("Hello World")
    .from("sender_id")
    .priority(.high)
    .ttl(5000)
    .signal(.healthCheck)
    .withCorrelation("request_123")
    .replyTo("response_queue")
    .build(allocator);
defer msg.deinit();
```

| Method | Description |
|--------|-------------|
| `from(sender)` | Set the sender identifier |
| `priority(p)` | Set priority: `.critical`, `.high`, `.normal`, `.low`, `.batch` |
| `ttl(ms)` | Set time-to-live in milliseconds |
| `signal(sig)` | Attach a signal type |
| `withCorrelation(id)` | Set correlation ID for request tracking |
| `replyTo(addr)` | Set reply destination |
| `build(allocator)` | Build the message |

---

### Inbox API

Channel-like message passing between threads.

```zig
var inbox = try vigil.inbox(allocator);
defer inbox.close();

// Send messages
try inbox.send("message 1");
try inbox.send("message 2");

// Receive (blocking)
const msg = try inbox.recv();
defer msg.deinit();

// Receive with timeout (returns null on timeout)
if (try inbox.recvTimeout(1000)) |msg| {
    defer msg.deinit();
    // Process message
}
```

**Thread-Safe Close:**

```zig
// Thread 1: Waiting for messages
while (true) {
    const msg = inbox.recv() catch |err| {
        if (err == error.InboxClosed) break;
        return err;
    };
    defer msg.deinit();
}

// Thread 2: Signal shutdown
inbox.close();
```

| Method | Description |
|--------|-------------|
| `send(payload)` | Send a message payload |
| `sendMessage(message)` | Send an owned message without rebuilding its id or metadata |
| `recv()` | Block until message received (parks on a condition, no polling) |
| `recvTimeout(ms)` | Receive with timeout (returns `?Message`; `0` is a nonblocking poll) |
| `tryRecv()` | Explicit nonblocking receive (returns `?Message`) |
| `recvBatch(buffer)` | Drain up to `buffer.len` messages under one lock and expiry sweep |
| `sendBatch(payloads)` | Send payloads in order, stopping at the first failure |
| `queueDepth()` | Read active queue depth with shutdown-safe operation pinning |
| `dropOldest()` | Drop the oldest active message with shutdown-safe operation pinning |
| `acquireOperation()` | Pin lifetime across a multi-step wrapper operation |
| `isClosed()` | Check if inbox is closed |
| `stats()` | Get mailbox statistics |
| `deadLetters(allocator)` | Capture an owned, non-consuming dead-letter snapshot |
| `deadLetter(message, reason)` | Transfer a failed owned message to dead-letter storage |
| `deadLetterCount()` | Return retained dead-letter count |
| `replayDeadLetter(id)` | Replay by stable mailbox-local entry id |
| `discardDeadLetter(id)` | Discard and free one entry |
| `discardAllDeadLetters()` | Discard and free all entries |
| `onPoisonMessage(context, handler)` | Register a poison classification callback |
| `close()` | Close the inbox |

---

### Inbox Builder

Create inboxes with custom configuration using a fluent builder.

```zig
var inbox = try vigil.inboxBuilder(allocator)
    .capacity(1000)
    .priorityQueues(true)
    .deadLetter(true)
    .deadLetterCapacity(256)
    .maxDeliveryAttempts(3)
    .defaultTTL(30_000)
    .build();
defer inbox.close();
```

| Method | Description |
|--------|-------------|
| `capacity(n)` | Set maximum message capacity |
| `priorityQueues(bool)` | Enable/disable priority queues |
| `deadLetter(bool)` | Enable/disable dead letter queue |
| `deadLetterCapacity(n)` | Bound retained dead-letter entries |
| `maxDeliveryAttempts(n)` | Set poison-message attempt threshold |
| `defaultTTL(ms)` | Set default message TTL |
| `withRateLimit(config)` | Add rate limiting |
| `withBackpressure(config)` | Add backpressure handling |
| `build()` | Create the inbox |

#### Dead-Letter Ownership and Replay

Dead-letter entries use monotonic mailbox-local ids; message ids are not
required to be unique. Inspection snapshots own deep copies and must be
deinitialized. `deadLetter(message, reason)` consumes the message after the
mailbox operation starts, including error paths.

```zig
var jobs = try vigil.inboxBuilder(allocator)
    .capacity(1)
    .deadLetterCapacity(32)
    .maxDeliveryAttempts(3)
    .build();
defer jobs.close();

try jobs.send("active");
try jobs.send("retained while full"); // accepted into dead-letter storage

var snapshot = try jobs.deadLetters(allocator);
defer snapshot.deinit();
const id = snapshot.entries[0].id;

var active = try jobs.recv();
active.deinit();

const replay = try jobs.replayDeadLetter(id);
if (replay.status == .replayed) {
    // The retained message is active again with a renewed TTL window.
}
```

Every successful `recv()` increments `message.metadata.attempt_count`. A
consumer reports processing failure by returning the owned message through
`deadLetter(message, .delivery_failed)`. At `maxDeliveryAttempts`, the entry is
classified as `.max_attempts`, will not replay automatically, emits
`poison_message_detected`, and invokes the optional poison handler.

---

### Supervisor Builder

Configure process supervision with restart strategies.

```zig
var builder = vigil.supervisor(allocator);
_ = try builder.child("worker_1", workerFunction);
_ = try builder.child("worker_2", workerFunction);
builder = builder.strategy(.one_for_one)
    .maxRestarts(5)
    .maxSeconds(30);

var supervisor = builder.build();
defer supervisor.deinit();

try supervisor.start();
defer supervisor.stop();
```

**With Child Options:**

```zig
_ = try builder.childWithOptions("worker", workerFn, .{
    .restart_type = .permanent,
    .shutdown_timeout_ms = 5000,
    .priority = .normal,
    .health_check_fn = healthCheckFn,
    .health_check_interval_ms = 1000,
});
```

**Worker Pools:**

```zig
// Creates worker_0, worker_1, worker_2, worker_3
_ = try builder.childPool("worker", workerFn, 4);
```

| Method | Description |
|--------|-------------|
| `strategy(s)` | Set restart strategy |
| `maxRestarts(count)` | Maximum restarts within time window |
| `maxSeconds(seconds)` | Time window for restart counting |
| `child(id, fn)` | Add a child process |
| `childWithOptions(id, fn, opts)` | Add child with custom options |
| `childPool(prefix, fn, count)` | Add multiple workers |
| `onCrash(handler)` | Set crash callback |
| `withTelemetry(bool)` | Enable telemetry events |
| `build()` | Transfer the configured children into a supervisor |

| Strategy | Description |
|----------|-------------|
| `.one_for_one` | Restart only the failed process (default) |
| `.one_for_all` | Restart all processes when any fails |
| `.rest_for_one` | Restart failed process and all started after it |

| Restart Type | Description |
|--------------|-------------|
| `.permanent` | Always restart (default) |
| `.transient` | Restart only on abnormal termination |
| `.temporary` | Never restart |

---

### Supervisor Introspection

Runtime inspection and control of supervisors.

```zig
var supervisor = builder.build();

// Get supervisor state snapshot
const info = supervisor.inspect();
std.debug.print("Children: {d}, Active: {d}\n", .{
    info.child_count,
    info.active_children,
});

const stats = supervisor.getStats();
// stats.uptime_ms is elapsed monotonic time since Supervisor.init().

// Get specific child info
if (supervisor.getChildInfo("worker_1")) |child| {
    std.debug.print("Child state: {s}\n", .{@tagName(child.state)});
}

// Runtime control
try supervisor.restartChild("worker_1");
try supervisor.suspendChild("worker_1");
try supervisor.resumeChild("worker_1");

```

For an owned supervision-tree snapshot with copied child ids, use
`snapshot(allocator)`:

```zig
var tree = try supervisor.snapshot(allocator);
defer tree.deinit();
for (tree.children) |child| {
    std.debug.print("{s}: {s} ({d} restarts)\n", .{
        child.id,
        @tagName(child.state),
        child.restart_count,
    });
}
```

| Method | Description |
|--------|-------------|
| `inspect()` | Get supervisor state snapshot |
| `snapshot(allocator)` | Owned supervision-tree snapshot with per-child state |
| `getStats()` | Get counters, active children, and elapsed uptime |
| `getChildInfo(id)` | Get specific child info |
| `restartChild(id)` | Force restart a child |
| `suspendChild(id)` | Pause a child |
| `resumeChild(id)` | Resume a paused child |

---

### App Builder

Build applications with pre-configured supervision.

```zig
var app = try vigil.app(allocator);
defer app.shutdown();
_ = try app.worker("service", serviceFunction);
_ = try app.workerPool("handlers", handlerFunction, 4);
try app.start();
```

`AppBuilder` instances are heap-owned. `shutdown()` releases the builder after
stopping its supervisor, so do not call builder methods afterward.

---

## Resilience

### Reliability Policy

`vigil.executePolicy` composes retry, backoff, timeout classification,
fallback handlers, and optional circuit-breaker protection around a fallible
operation. It is synchronous: timeout checks happen before attempts, after
attempts, and after retry sleeps. A blocking operation is not interrupted while
it is running.

```zig
const Result = enum { primary, fallback };

const Client = struct {
    attempts: u32 = 0,

    fn request(self: *@This()) anyerror!Result {
        self.attempts += 1;
        if (self.attempts < 3) return error.TemporaryFailure;
        return .primary;
    }

    fn fallback(_: *@This(), failure: vigil.PolicyFailure) anyerror!Result {
        std.debug.print("using fallback after {d} attempt(s)\n", .{failure.attempts});
        return .fallback;
    }
};

var breaker = try vigil.CircuitBreaker.init(allocator, "dependency", .{});
defer breaker.deinit();

var client = Client{};
const result = vigil.executePolicy(Client, Result, &client, Client.request, .{
    .retry = .{
        .max_attempts = 3,
        .backoff = .{ .exponential = .{
            .initial_ms = 10,
            .multiplier = 2,
            .max_ms = 100,
        } },
    },
    .timeout_ms = 500,
    .circuit_breaker = &breaker,
    .fallback = Client.fallback,
});

switch (result) {
    .success => |success| {
        std.debug.print("value={s} attempts={d}\n", .{
            @tagName(success.value),
            success.report.attempts,
        });
    },
    .fallback => |fallback| {
        std.debug.print("fallback={s} from={s}\n", .{
            @tagName(fallback.value),
            @tagName(fallback.report.fallback_from.?),
        });
    },
    .timeout => |failure| {
        std.debug.print("timeout after {d} attempt(s)\n", .{failure.attempts});
    },
    .circuit_open => |failure| {
        std.debug.print("circuit open before attempt {d}\n", .{failure.attempts + 1});
    },
    .permanent_failure => |failure| {
        std.debug.print("failed after {d} attempt(s)\n", .{failure.attempts});
    },
}
```

| Type | Description |
|------|-------------|
| `PolicyOutcome` | Outcome category: success, retry, timeout, fallback, circuit open, or permanent failure |
| `PolicyReport` | Attempts, retries, elapsed time, outcome, last error, and fallback source |
| `PolicyFailure` | Failure details returned by failures and passed to fallback handlers |
| `PolicyResult(T)` | Typed union returned by `executePolicy` |
| `PolicyOptions(Context, T)` | Generic options type for retries, timeouts, fallback, circuit breaker, clock, and sleeper |
| `RetryPolicy` | Total attempts and backoff strategy |
| `BackoffPolicy` | `.none`, `.fixed_ms`, `.exponential`, or `.jittered` delay strategy |
| `ExponentialBackoff` | Initial delay, multiplier, and max delay |
| `JitteredBackoff` | Exponential backoff plus deterministic positive jitter |

| Option | Description |
|--------|-------------|
| `retry` | Controls max attempts and delay between retries |
| `timeout_ms` | Optional synchronous deadline checked around attempts |
| `circuit_breaker` | Optional `*CircuitBreaker` protecting every attempt |
| `fallback` | Optional handler used for timeout, circuit-open, and permanent-failure outcomes |
| `clock` | Optional `fn (*Context) i64` hook for deterministic tests |
| `sleeper` | Optional `fn (*Context, u64) void` hook for deterministic tests or custom schedulers |

`PolicyReport.fallback_from` is set when the final result is `.fallback`, so
logs and health endpoints can distinguish fallback caused by timeout,
circuit-open, or permanent failure.

---

### Circuit Breaker

Protect services from cascading failures.

```zig
var breaker = try vigil.CircuitBreaker.init(allocator, "api_service", .{
    .failure_threshold = 5,        // Open after 5 failures
    .reset_timeout_ms = 30_000,    // Try again after 30s
    .half_open_requests = 3,       // Allow 3 test requests
    .half_open_success_threshold = 2, // Close after 2 successes
});
defer breaker.deinit();

// Check state before calling
if (breaker.getState() == .open) {
    return error.ServiceUnavailable;
}

// Execute with protection
const result = try breaker.call(u32, riskyFunction);

// Execute fallible function
try breaker.callError(fallibleFunction);

// Manual control
breaker.forceOpen();
breaker.forceClose();

// Get failure count
const failures = breaker.getFailureCount();
```

| State | Description |
|-------|-------------|
| `.closed` | Normal operation |
| `.open` | Failing fast, rejecting calls |
| `.half_open` | Testing if service recovered |

| Method | Description |
|--------|-------------|
| `call(T, fn)` | Execute function with protection |
| `callError(fn)` | Execute fallible function |
| `beforeCall()` | Reserve one protected operation for custom policy composition |
| `recordSuccess()` | Record success after a custom protected operation |
| `recordFailure()` | Record failure after a custom protected operation |
| `getState()` | Get current circuit state |
| `getFailureCount()` | Get failure count |
| `forceOpen()` | Manually open circuit |
| `forceClose()` | Manually close circuit |

`snapshot()` additionally reports diagnostics: `last_transition_time_ms`,
`open_transitions`, `total_failures`, and `total_successes`.

---

### Bulkhead

Fail-fast isolation pool that bounds concurrent access to a dependency, so one
slow service cannot absorb every worker in the system.

```zig
var bulkhead = try vigil.Bulkhead.init(.{ .max_concurrent = 8 });

// Manual permits
try bulkhead.acquire(); // error.BulkheadFull when the pool is exhausted
defer bulkhead.release();

// Or wrap the operation; the permit is released on success and failure.
const value = try bulkhead.run(Client, u32, &client, Client.fetchQuote);

// Usage and rejection counters for health reporting.
const usage = bulkhead.snapshot();
std.debug.print("{d}/{d} in flight, {d} rejected\n", .{
    usage.in_flight,
    usage.max_concurrent,
    usage.total_rejected,
});
```

| Method | Description |
|--------|-------------|
| `acquire()` | Reserve a permit, failing fast with `error.BulkheadFull` |
| `release()` | Return a permit |
| `run(Context, T, ctx, fn)` | Run an operation inside the pool |
| `snapshot()` | Usage snapshot with lifetime admitted/rejected counters |

---

### Rate Limiter

Token bucket algorithm for flow control.

```zig
var limiter = vigil.RateLimiter.init(100); // 100 ops/second

if (limiter.allow()) {
    // Process request
} else {
    // Rate limited - reject or queue
}

// Check available tokens
const available = limiter.available();

// Reset limiter
limiter.reset();
```

| Method | Description |
|--------|-------------|
| `allow()` | Check and consume a token |
| `available()` | Get available tokens |
| `reset()` | Reset to max tokens |

---

### Backpressure

Handle overload with configurable strategies.

```zig
var flow_inbox = vigil.FlowControlledInbox.init(
    allocator,
    inbox,
    .{ .max_per_second = 100 },  // Rate limit config
    .{
        .strategy = .drop_oldest,  // Backpressure strategy
        .high_watermark = 1000,
        .low_watermark = 500,
    },
);

try flow_inbox.send("message");
const msg = try flow_inbox.recv();
```

Backpressure uses the wrapped inbox's current queue depth. The low watermark
must not exceed the high watermark, and `.block` requires a nonzero low
watermark; `send()` returns `error.InvalidConfiguration` for invalid
combinations.

| Strategy | Description |
|----------|-------------|
| `.drop_oldest` | Drop oldest messages when full |
| `.drop_newest` | Drop new messages when full |
| `.block` | Block until space available |
| `.return_error` | Return error immediately |

---

## Messaging

### Process Groups

Manage related processes with routing strategies.

```zig
var group = try vigil.ProcessGroup.init(allocator, "workers");
defer group.deinit();

// Add members
try group.add("worker1", inbox1);
try group.add("worker2", inbox2);

// Routing strategies
try group.broadcast("message");           // Send to all
try group.roundRobin("message");          // Distribute evenly
try group.route("message", "user_123");   // Consistent hash by key

// Manage members
_ = group.remove("worker1");
const member_count = group.memberCount();
```

| Method | Description |
|--------|-------------|
| `add(id, inbox)` | Add a member |
| `remove(id)` | Remove a member |
| `memberCount()` | Get member count |
| `broadcast(payload)` | Send to all members |
| `roundRobin(payload)` | Distribute evenly |
| `route(payload, key)` | Consistent hash routing |

---

### Pub/Sub

Topic-based messaging with wildcard support.

```zig
var broker = vigil.PubSubBroker.init(allocator);
defer broker.deinit();

// Create subscriber
var subscriber = vigil.Subscriber.init(allocator, inbox);
defer subscriber.deinit();
try subscriber.subscribe(&.{"events.user.*", "events.system.#"});
try broker.subscribe(&subscriber);

// Check if matches topic
if (subscriber.matches("events.user.created")) {
    // Will receive this topic
}

// Publish messages through the explicitly owned broker
_ = try broker.publish("events.user.created", "user_data");
_ = try broker.publish("events.system.alert", "alert_data");
broker.unsubscribe(&subscriber);
```

**Wildcard Patterns:**
- `*` - Match exactly one non-empty level (for example, `events.*` matches `events.user`)
- `#` - Match zero or more levels only as the final level (`events.#` matches `events` and `events.user.created`)

Calling `broker.subscribe()` more than once with the same subscriber is
idempotent and does not duplicate deliveries.

---

### Request/Reply

Synchronous waiting with explicit correlation ids.

```zig
// Create request with correlation ID
var request_msg = try vigil.Message.init(
    allocator, "req1", "client", "request_data", null, .normal, null
);
defer request_msg.deinit();
try request_msg.setCorrelationId("corr_123");

// Create reply (preserves correlation ID)
const response = try vigil.reply(request_msg, "response_data", allocator);
// response.metadata.correlation_id == "corr_123"
try inbox.sendMessage(response); // consumes response and preserves metadata

// Using ReplyMailbox for waiting
var reply_mailbox = vigil.request_reply.ReplyMailbox.init(allocator, inbox);
defer reply_mailbox.deinit();

const reply_msg = try reply_mailbox.waitForReply("corr_123", 5000);
defer reply_msg.deinit();
```

A timeout of zero performs one nonblocking poll, so a reply already queued is
returned immediately rather than skipped.

---

## Observability

### Telemetry

Event hooks for monitoring and debugging. Thread-safe event emission.

```zig
var rt = try vigil.runtime(allocator, .{});
defer rt.deinit();

try rt.telemetry_emitter.on(.process_started, struct {
    fn handler(event: vigil.telemetry.Event) void {
        std.debug.print("Event: {s} at {d}ms\n", .{
            @tagName(event.event_type),
            event.timestamp_ms,
        });
    }
}.handler);

rt.telemetry_emitter.emit(.{
    .event_type = .message_sent,
    .timestamp_ms = vigil.compat.milliTimestamp(),
    .metadata = null,
});

// Create custom emitter
var emitter = vigil.telemetry.TelemetryEmitter.init(allocator);
defer emitter.deinit();
emitter.setEnabled(true);
emitter.removeHandlers(.process_started);
```

**Event Types:**

| Category | Events |
|----------|--------|
| Process | `process_started`, `process_stopped`, `process_crashed`, `process_suspended`, `process_resumed` |
| Message | `message_sent`, `message_received`, `message_expired`, `message_dropped`, `message_dead_lettered`, `message_replayed`, `message_discarded`, `poison_message_detected` |
| Supervisor | `supervisor_started`, `supervisor_stopped`, `supervisor_restart`, `supervisor_child_added`, `supervisor_child_removed` |
| Circuit | `circuit_opened`, `circuit_closed`, `circuit_half_open` |
| GenServer | `genserver_started`, `genserver_stopped`, `genserver_state_changed` |

---

### Testing Utilities

Mock components for testing.

```zig
var ctx = vigil.TestContext.init(allocator);
defer ctx.deinit();

// Time control
ctx.advanceTime(1000);
const now = ctx.now();

// Mock inbox - captures messages for assertions
var mock_inbox = try ctx.mockInbox();
try mock_inbox.send(msg);
const received = mock_inbox.recv();
try std.testing.expect(mock_inbox.count() == 0);
const peeked = mock_inbox.peek(0);
mock_inbox.clear();

// Mock supervisor - simulates supervision without threads
var mock_sup = try ctx.mockSupervisor();
try mock_sup.addChild("worker", workerFn);
try mock_sup.start();
try mock_sup.failChild("worker");
mock_sup.stop();
const restart_count = mock_sup.getRestartCount();
const child_count = mock_sup.childCount();

// Message assertions
try vigil.expectMessage(std.testing, mock_inbox, .{
    .payload = "expected",
    .sender = "sender_id",
    .priority = .high,
});

try vigil.expectSignal(std.testing, mock_inbox, .healthCheck);
```

### Deterministic Simulation

Simulate time, timers, faults, and cluster behavior without threads, sleeps,
or sockets.

```zig
// Deterministic clock: time moves only when the test advances it. `now`/
// `sleep` slot straight into PolicyOptions clock/sleeper hooks.
var clock = vigil.SimulatedClock.init(0);
clock.advance(250);
clock.sleep(5 * std.time.ns_per_ms); // advances 5ms instead of blocking

// Deterministic timers: callbacks fire synchronously inside advance(), in
// deadline order. Intervals re-arm; cancel() removes pending timers.
var timers = vigil.SimulatedTimerService.init(allocator, &clock);
defer timers.deinit();
_ = try timers.setTimeout(10, onDeadline);
const interval_id = try timers.setInterval(4, onTick);
const fired = timers.advance(12); // fires ticks at 4, 8, 12 and the timeout at 10
_ = timers.cancel(interval_id);

// Fault injection: scripted failures for retry/fallback/breaker tests.
var injector = vigil.FaultInjector.init(.{
    .fail_first = 2,               // fail the first two calls
    .fail_every = 5,               // then every 5th call
    .error_value = error.Timeout,  // with this error
});
try std.testing.expectError(error.Timeout, injector.call());

// Fake distributed registry: in-memory peers, no sockets. disconnectPeer()
// simulates a partition; reconnectPeer() heals it.
var registry = vigil.FakeDistributedRegistry.init(allocator, 9100);
defer registry.deinit();
try registry.addPeer("node_b", "10.0.0.2", 9200);
try registry.registerRemote("node_b", "billing_service");
_ = registry.whereisGlobal("billing_service"); // resolves via node_b
_ = registry.disconnectPeer("node_b");
_ = registry.whereisGlobal("billing_service"); // null while partitioned

// Failure-mode helpers for queues and consumers.
const sent = try vigil.testing.fillInbox(inbox, "load");     // full queue
const drained = try vigil.testing.drainInbox(inbox, 100);    // consumer catches up
```

`fired`, `sent`, and `drained` report exactly how much work happened, so tests
assert on counts instead of sleeping and hoping.

---

## Advanced

### Graceful Shutdown

Coordinated shutdown with hooks. Hooks run in configurable order.

```zig
var rt = try vigil.runtime(allocator, .{});
defer rt.deinit();

try rt.onShutdown(struct {
    fn cleanup() void {
        std.debug.print("Cleaning up...\n", .{});
    }
}.cleanup);

rt.shutdown();

// Use manager directly
var manager = vigil.shutdown.ShutdownManager.init(allocator);
defer manager.deinit();
try manager.onShutdown(cleanupFn);
manager.shutdown(.{});
```

---

### State Checkpointing

Persist and recover process state.

```zig
// File-based checkpointer
var file_ckpt = try vigil.FileCheckpointer.init(allocator, "/tmp/checkpoints");
defer file_ckpt.deinit();
const ckpt = file_ckpt.toCheckpointer();

// Applications that already own a std.Io value can instead call:
// vigil.FileCheckpointer.initWithIo(allocator, io, "/tmp/checkpoints")

// Save state
try ckpt.save("server_state", state_bytes);

// Load state
if (try ckpt.load("server_state", allocator)) |state| {
    defer allocator.free(state);
    // Restore state
}

// Delete checkpoint
ckpt.delete("server_state");

// Memory checkpointer (for testing)
var mem_ckpt = vigil.MemoryCheckpointer.init(allocator);
defer mem_ckpt.deinit();
const test_ckpt = mem_ckpt.toCheckpointer();
```

File checkpoint ids must be a single non-empty path component. Empty ids,
`.`/`..`, path separators, and NUL bytes are rejected with
`error.InvalidCheckpointId`. File writes are atomic: state is written to a
temporary file and renamed into place, so a crash mid-write cannot corrupt
the previous good checkpoint.

For production pipelines, wrap any backend in `CheckpointService`: it stamps
a version header on every save, applies optional encode/decode transforms
(compression hooks), skips byte-identical saves, persists asynchronously on
one background thread, and reports latency/size metrics.

```zig
var service = vigil.CheckpointService.init(allocator, ckpt, .{
    .version = 2,
    .encode = compress,          // optional TransformFn hooks
    .decode = decompress,
    .migrate = migrateFromV1,    // called for older stored versions
});
try service.start();             // enables saveAsync()
defer service.deinit();          // drains queued saves before stopping

try service.saveAsync("machine", serialized); // never blocks on storage
service.flush();                               // wait for queued saves
const state = try service.load("machine", allocator); // verify + migrate + decode
const stats = service.metrics(); // saves, skipped, failures, bytes, latency, pending
```

Loading a checkpoint whose version differs from `options.version` calls the
`migrate` hook, or fails with `error.CheckpointVersionMismatch` when none is
configured. Headerless data from plain `Checkpointer` backends is treated as
version 0.

---

### GenServer

Generic stateful server with synchronous call/reply and optional state checkpointing.

```zig
const vigil = @import("vigil");

const State = struct { count: u32 };
const MyServer = vigil.GenServer(State);

const server = try MyServer.init(
    allocator,
    struct {
        fn handle(self: *MyServer, msg: vigil.Message) !void {
            if (msg.payload) |payload| {
                if (std.mem.eql(u8, payload, "increment")) {
                    self.state.count += 1;
                }
                // Reply to synchronous call() requests
                if (msg.metadata.correlation_id != null) {
                    const result = try std.fmt.allocPrint(self.allocator, "{d}", .{self.state.count});
                    defer self.allocator.free(result);
                    try self.reply(msg, result);
                }
            }
        }
    }.handle,
    struct { fn init_cb(self: *MyServer) !void { _ = self; } }.init_cb,
    struct { fn terminate(self: *MyServer) void { _ = self; } }.terminate,
    State{ .count = 0 },
);

// Start in a background thread
const thread = try std.Thread.spawn(.{}, struct {
    fn run(s: *MyServer) void { s.start() catch {}; }
}.run, .{server});

// Asynchronous message (fire-and-forget)
try server.cast(try vigil.Message.init(allocator, "m1", "client", "increment", null, .normal, null));

// Synchronous call (blocks until handler calls self.reply())
var request = try vigil.Message.init(allocator, "m2", "client", "increment", null, .normal, null);
defer request.deinit();
var response = try server.call(&request, 2000); // 2s timeout
defer response.deinit();

// Shutdown: signal stop, join thread, then free resources
server.stop();
thread.join();
server.deinit();
```

**State Checkpointing:**

```zig
var mem_ckpt = vigil.MemoryCheckpointer.init(allocator);
defer mem_ckpt.deinit();

try server.setCheckpointer(mem_ckpt.toCheckpointer(), "my_server", 5000, .{
    .serialize = struct {
        fn f(state: *const State, alloc: std.mem.Allocator) ![]u8 {
            return try std.fmt.allocPrint(alloc, "{d}", .{state.count});
        }
    }.f,
    .deserialize = struct {
        fn f(data: []const u8, _: std.mem.Allocator) !State {
            return State{ .count = try std.fmt.parseInt(u32, data, 10) };
        }
    }.f,
});
// State is auto-saved every 5s and on shutdown.
// On init, existing checkpoints are auto-restored.
```

| Method | Description |
|--------|-------------|
| `init(allocator, handler, init_fn, terminate_fn, state)` | Create a new GenServer |
| `deinit()` | Free resources (call after stop + thread join) |
| `start()` | Run the message loop (blocks) |
| `stop()` | Signal the server to stop |
| `cast(msg)` | Send async message |
| `call(msg, timeout_ms)` | Send sync message, wait for reply |
| `reply(msg, payload)` | Reply to a call() from within the handler |
| `setCheckpointer(ckpt, id, interval_ms, fns)` | Enable state checkpointing |
| `register(registry, name)` | Register with an explicit registry |
| `schedule(msg, delay_ms)` | Send a delayed message to self |
| `supervise(supervisor, id)` | Register with a supervisor |

`cast()` and `call()` return `error.NotRunning` after the server has stopped.

---

### Distributed Registry

Cross-process name resolution with TCP-based cluster communication.

```zig
var registry = try vigil.DistributedRegistry.init(allocator, .{
    .cluster_nodes = &.{"node1:9001", "node2:9002"},
    .sync_interval_ms = 1000,
    .heartbeat_timeout_ms = 5000,
    .listen_port = 9100, // TCP port for incoming queries
});
defer registry.deinit();

// Register process (local or global scope)
try registry.register("my_service", mailbox, .global);

// Local lookup (returns *ProcessMailbox)
if (registry.whereis("my_service")) |mb| {
    // Use mailbox directly
    _ = mb;
}

// Global lookup (checks local + remote cache, returns RemoteProcessInfo)
if (registry.whereisGlobal("remote_service")) |info| {
    std.debug.print("Found on {s}:{d}\n", .{ info.node_address, info.node_port });
}

// Active query to all peer nodes (updates cache)
if (registry.queryPeers("remote_service")) |info| {
    std.debug.print("Found on {s}:{d}\n", .{ info.node_address, info.node_port });
}

// Start listener + sync threads (heartbeats, registration propagation)
try registry.startSync();

// Stop synchronization
registry.stopSync();
```

**Cluster Protocol (TCP, newline-delimited):**
- `VIGIL/2 HEART` -> `ALIVE` (liveness check)
- `VIGIL/2 WHERE <name>` -> `FOUND` / `NOTFOUND` (name lookup)
- `VIGIL/2 REG <name>` -> `OK` (registration propagation)
- `VIGIL/2 UNREG <name>` -> `OK` (remote cache removal)

Global names must be one non-empty protocol token: whitespace, control bytes,
and extra command arguments are rejected. Frames may arrive in multiple TCP
reads but must end in a newline and fit within the registry frame buffer.

| Method | Description |
|--------|-------------|
| `register(name, mailbox, scope)` | Register locally; if `.global`, sync to peers |
| `whereis(name)` | Local-only lookup, returns `?*ProcessMailbox` |
| `whereisGlobal(name)` | Check local + remote cache, returns `?RemoteProcessInfo` |
| `queryPeers(name)` | Actively query all peer nodes via TCP |
| `startSync()` | Start listener and sync threads |
| `stopSync()` | Stop listener and sync threads |

---

### Registry

Local process name registry.

```zig
var registry = vigil.Registry.init(allocator);
defer registry.deinit();

// Register process
try registry.register("my_process", mailbox);

// Lookup process
if (registry.whereis("my_process")) |mailbox| {
    // Use mailbox
}

// Unregister
registry.unregister("my_process");
```

---

### Timer

Scheduled and periodic callbacks.

```zig
var timer = vigil.Timer.init(allocator);
defer timer.deinit();

// One-shot timer
try timer.setTimeout(1000, callbackFn);

// Periodic timer
try timer.setInterval(500, periodicFn);

// Cancel timer
timer.cancel();
```

Intervals must be greater than zero; `setInterval(0, ...)` returns
`error.InvalidInterval`. After a one-shot callback finishes,
`snapshot().active` is false.

`vigil.Timer` spawns one thread per timer and is kept for compatibility;
prefer the timer service below for new code.

---

### Timer Service

One scheduler thread drives every timeout, interval, and delayed send from a
min-heap of deadlines — no thread per timer. `Runtime.timers()` owns the
service lifecycle; a standalone `vigil.TimerService` needs `start()` and a
stable address.

```zig
var rt = try vigil.runtime(allocator, .{});
defer rt.deinit();
const timers = try rt.timers();

const id = try timers.setTimeout(1000, onDeadline);
_ = try timers.setInterval(500, onTick);
_ = try timers.sendAfter(250, inbox.mailbox, msg); // owns msg; no detached thread
_ = timers.cancel(id);

const state = timers.snapshot(); // running, pending, fired, cancelled
```

| Method | Description |
|--------|-------------|
| `setTimeout(delay_ms, fn)` | Run once after a delay; returns a cancellation id |
| `setInterval(interval_ms, fn)` | Run repeatedly until cancelled |
| `sendAfter(delay_ms, mailbox, msg)` | Deliver an owned message after a delay |
| `cancel(id)` | Cancel a pending timer (releases undelivered sends) |
| `pendingCount()` / `snapshot()` | Inspect scheduled work and lifetime counters |

---

## Configuration Presets

| Preset | Max Restarts | Window | Health Check | Shutdown Timeout | Mailbox Capacity |
|--------|-------------|--------|--------------|------------------|------------------|
| `.production` | 3 | 60s | 5000ms | 30000ms | 1000 |
| `.development` | 10 | 5s | 1000ms | 5000ms | 100 |
| `.high_availability` | 5 | 30s | 2000ms | 20000ms | 5000 |
| `.testing` | 1 | 10s | 100ms | 1000ms | 50 |

```zig
var app = try vigil.appWithPreset(allocator, .production);
```

---

## Low-Level API

For advanced use cases, access the full low-level API:

```zig
const vigil = @import("vigil");

// Direct Supervisor creation
var supervisor = vigil.Supervisor.init(allocator, .{
    .strategy = .one_for_all,
    .max_restarts = 5,
    .max_seconds = 30,
});
defer supervisor.deinit();

try supervisor.addChild(.{
    .id = "worker",
    .start_fn = workerFunction,
    .restart_type = .permanent,
    .shutdown_timeout_ms = 5000,
    .priority = .normal,
    .max_memory_bytes = null,
    .health_check_fn = healthCheckFn,
    .health_check_interval_ms = 1000,
});

try supervisor.start();

// Direct Mailbox creation
var mailbox = vigil.ProcessMailbox.init(allocator, .{
    .capacity = 1000,
    .priority_queues = true,
    .enable_deadletter = true,
    .dead_letter_capacity = 256,
    .max_delivery_attempts = 3,
    .default_ttl_ms = 30_000,
    .max_message_size = 1024 * 1024,
});
defer mailbox.deinit();

try mailbox.send(msg);
const received = try mailbox.receive();

// Direct Message creation
var msg = try vigil.Message.init(
    allocator,
    "msg_id",
    "sender",
    "payload",
    .alert,
    .high,
    5000,
);
defer msg.deinit();

try msg.setCorrelationId("correlation_123");
try msg.setReplyTo("response_mailbox");

if (msg.isExpired()) {
    // Handle expired message
}
```

---

## Types Reference

### MessagePriority

```zig
pub const MessagePriority = enum {
    critical,  // Immediate handling
    high,      // Urgent
    normal,    // Standard (default)
    low,       // Background
    batch,     // Bulk operations
};
```

### RestartStrategy

```zig
pub const RestartStrategy = enum {
    one_for_one,   // Restart only failed
    one_for_all,   // Restart all
    rest_for_one,  // Restart failed + subsequent
};
```

### CircuitState

```zig
pub const CircuitState = enum {
    closed,     // Normal operation
    open,       // Failing fast
    half_open,  // Testing recovery
};
```

### Dead-Letter Types

| Type | Purpose |
|------|---------|
| `DeadLetterReason` | Why a message was retained: mailbox full, expired, failed delivery, manual handling, or max attempts |
| `DeadLetterNotice` | Stable entry id, reason, attempt count, and poison transition flags |
| `DeadLetterEntry` | Owned message plus dead-letter timestamp and poison state |
| `DeadLetterSnapshot` | Owned array of copied entries; call `deinit()` |
| `DeadLetterReplayResult` | `replayed`, `retained`, `poison`, or `not_found` outcome plus an optional notice |

### Signal

```zig
pub const Signal = enum {
    // Lifecycle
    restart, shutdown, terminate, exit,
    
    // Control
    @"suspend", @"resume",
    
    // Monitoring
    healthCheck, memoryWarning, cpuWarning, deadlockDetected,
    
    // Logging
    messageErr, info, warning, debug, log, alert, metric, event, heartbeat,
    
    // Custom
    custom,
};
```

### ProcessPriority

```zig
pub const ProcessPriority = enum {
    critical,  // Essential system processes
    high,      // Important business logic
    normal,    // Default priority
    low,       // Non-essential tasks
    batch,     // Lowest priority
};
```

### VigilError

```zig
pub const VigilError = error{
    // Process
    ProcessNotFound, ProcessAlreadyRunning, ProcessStartFailed, ProcessStopFailed,

    // Supervisor
    SupervisorNotFound, ChildNotFound, TooManyRestarts, ShutdownTimeout, AlreadyMonitoring,

    // Message
    EmptyMailbox, MailboxFull, MessageExpired, MessageTooLarge, InvalidMessage, DeliveryTimeout,
    RateLimitExceeded, DeliveryFailed, DeadLetterFull,

    // Registry
    AlreadyRegistered, NotRegistered,

    // Circuit Breaker
    CircuitOpen,

    // General
    OutOfMemory, InvalidConfiguration, OperationTimeout, InvalidState,
};
```

---

## Error Handling

### Inbox Errors

| Error | Description |
|-------|-------------|
| `InboxClosed` | Inbox was closed while waiting |
| `OutOfMemory` | Memory allocation failed |
| `DeadLetterFull` | Bounded dead-letter storage is full |

### Message Errors

| Error | Description |
|-------|-------------|
| `MailboxFull` | Queue at capacity |
| `MessageExpired` | TTL elapsed |
| `MessageTooLarge` | Exceeds size limit |
| `DeliveryTimeout` | Send/receive timed out |
| `InvalidMessage` | Message validation failed |
| `ReceiverUnavailable` | Receiver not available |
| `RateLimitExceeded` | Rejected by rate limiter |
| `DeliveryFailed` | Subscriber delivery failure |
| `DeadLetterFull` | Bounded dead-letter storage is full |

### Circuit Breaker Errors

| Error | Description |
|-------|-------------|
| `CircuitOpen` | Circuit is open, rejecting calls |

### Supervisor Errors

| Error | Description |
|-------|-------------|
| `TooManyRestarts` | Exceeded restart limit |
| `ShutdownTimeout` | Graceful shutdown timed out |
| `ChildNotFound` | Child ID not found |
| `AlreadyMonitoring` | Monitoring already active |
| `InvalidState` | Operation is invalid for the supervisor lifecycle state |

### Process Group Errors

| Error | Description |
|-------|-------------|
| `NoMembers` | Group has no members |
| `AlreadyMember` | A member with the same id is already registered |
| `OutOfMemory` | Memory allocation failed |

---

## Building and Testing

```bash
# Build the library
zig build

# Run all tests
zig build test

# Run one API surface independently
zig build test-root
zig build test-legacy

# Run the showcase example
cd examples/vigil_showcase
zig build run

# Run the vigilant server example
cd examples/vigilant_server
zig build run

# Run the operations toolkit demos
cd examples/ops_toolkit
zig build run                        # all demos
zig build run -- dead-letter-replay  # one demo

# Run the webhook relay example
cd examples/webhook_relay
zig build run

# Run the benchmark harness
cd benchmarks/vigil_bench
zig build run -Doptimize=ReleaseSafe -- --iterations 10000
```

---

## Examples

See `examples/vigil_showcase` for a resilient order pipeline demonstrating:
- Runtime-owned registry, telemetry, shutdown hooks, and inboxes
- Process groups and pub/sub event fanout
- Inbox backpressure, rate limiting, and circuit breaker behavior

See `examples/webhook_relay` for one cohesive service that puts the v2.2
"Operate and Recover" toolkit together end to end:
- Policy-guarded webhook delivery: retries with exponential backoff, deadlines, per-endpoint circuit breakers, and bulkhead-limited concurrency
- Dead-letter quarantine, operator inspection, replay after recovery, and poison discard
- Endpoint diagnostics, `Runtime.debugDump()` status reporting, and a timeline audit trail
- Fully deterministic: backoff runs on a `SimulatedClock`, and the same dispatch logic is unit-tested with `FaultInjector` — no real sleeps anywhere

See `examples/ops_toolkit` for five focused operations demos:
- `job-queue` — resilient job queue with dead-letter replay and poison quarantine
- `retry-client` — retry/backoff dependency client with circuit breaker, fallback, and a simulated clock
- `dead-letter-replay` — operator workflow: inspect, replay, and discard dead letters with a timeline audit trail
- `introspection` — runtime introspection endpoint: health, queue peeks, route tables, subscriptions, and `debugDump()`
- `checkpoint` — checkpointed state machine with crash recovery

See `examples/vigilant_server` for a complete TCP server demonstrating:
- Circuit breaker protection
- Rate limiting  
- Telemetry integration
- Graceful shutdown
- Server metrics

```bash
cd examples/vigilant_server
zig build
./zig-out/bin/vigilant_server
```

**Available Commands:**
- `STATUS` - Get connection status
- `HEALTH` - Get health metrics
- `METRICS` - Get detailed metrics
