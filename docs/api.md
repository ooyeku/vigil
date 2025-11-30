# Vigil API Reference v1.0.0

A process supervision and inter-process communication library for Zig, inspired by Erlang/OTP.

## Table of Contents

- [Quick Start](#quick-start)
- [Core API](#core-api)
  - [Message Builder](#message-builder)
  - [Inbox API](#inbox-api)
  - [Supervisor Builder](#supervisor-builder)
  - [App Builder](#app-builder)
- [Resilience](#resilience)
  - [Circuit Breaker](#circuit-breaker)
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
- [Configuration Presets](#configuration-presets)
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
    _ = try app.worker("service", serviceFunction);
    _ = try app.workerPool("handlers", handlerFunction, 4);
    try app.start();
    defer app.shutdown();
}

fn serviceFunction() void {
    // Your service logic
}

fn handlerFunction() void {
    // Your handler logic
}
```

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
| `recv()` | Block until message received |
| `recvTimeout(ms)` | Receive with timeout |
| `isClosed()` | Check if inbox is closed |
| `stats()` | Get mailbox statistics |
| `close()` | Close the inbox |

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

| Strategy | Description |
|----------|-------------|
| `.one_for_one` | Restart only the failed process (default) |
| `.one_for_all` | Restart all processes when any fails |
| `.rest_for_one` | Restart failed process and all started after it |

---

### App Builder

Build applications with pre-configured supervision.

```zig
var app = try vigil.app(allocator);
_ = try app.worker("service", serviceFunction);
_ = try app.workerPool("handlers", handlerFunction, 4);
try app.start();
defer app.shutdown();
```

---

## Resilience

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

// Manual control
breaker.forceOpen();
breaker.forceClose();
```

| State | Description |
|-------|-------------|
| `.closed` | Normal operation |
| `.open` | Failing fast, rejecting calls |
| `.half_open` | Testing if service recovered |

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
```

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
const count = group.count();
```

---

### Pub/Sub

Topic-based messaging with wildcard support.

```zig
// Initialize global broker
try vigil.pubsub.initGlobal(allocator);

// Create subscriber
var subscriber = vigil.Subscriber.init(allocator, inbox);
defer subscriber.deinit();
try subscriber.subscribe(&.{"events.user.*", "events.system.#"});

// Publish messages
try vigil.publish("events.user.created", "user_data");
try vigil.publish("events.system.alert", "alert_data");
```

**Wildcard Patterns:**
- `*` - Match single level (e.g., `events.*` matches `events.user`)
- `#` - Match multiple levels (e.g., `events.#` matches `events.user.created`)

---

### Request/Reply

Synchronous messaging with automatic correlation.

```zig
// Create request
var request_msg = try vigil.Message.init(allocator, "req1", "client", "request_data", null, .normal, null);
defer request_msg.deinit();
try request_msg.setCorrelationId("corr_123");

// Create reply
var response = try vigil.reply(request_msg, "response_data", allocator);
defer response.deinit();
// response.metadata.correlation_id == "corr_123"
```

---

## Observability

### Telemetry

Event hooks for monitoring and debugging.

```zig
// Initialize global telemetry
try vigil.telemetry.initGlobal(allocator);

// Register event handlers
if (vigil.telemetry.getGlobal()) |emitter| {
    try emitter.on(.process_started, struct {
        fn handler(event: vigil.telemetry.Event) void {
            std.debug.print("Event: {s}\n", .{@tagName(event.event_type)});
        }
    }.handler);
}

// Emit custom events
vigil.telemetry.emit(.{
    .event_type = .message_sent,
    .timestamp_ms = std.time.milliTimestamp(),
    .metadata = null,
});
```

**Event Types:**

| Category | Events |
|----------|--------|
| Process | `process_started`, `process_stopped`, `process_crashed`, `process_suspended`, `process_resumed` |
| Message | `message_sent`, `message_received`, `message_expired`, `message_dropped` |
| Supervisor | `supervisor_started`, `supervisor_stopped`, `supervisor_restart`, `supervisor_child_added` |
| Circuit | `circuit_opened`, `circuit_closed`, `circuit_half_open` |

---

### Testing Utilities

Mock components for testing.

```zig
var ctx = vigil.TestContext.init(allocator);
defer ctx.deinit();

// Time control
ctx.advanceTime(1000);
const now = ctx.now();

// Mock inbox
var mock_inbox = try ctx.mockInbox();
try mock_inbox.send(msg);
const received = mock_inbox.recv();
try std.testing.expect(mock_inbox.count() == 0);

// Mock supervisor
var mock_sup = try ctx.mockSupervisor();
try mock_sup.addChild("worker", workerFn);
try mock_sup.start();
try mock_sup.failChild("worker");
```

---

## Advanced

### Graceful Shutdown

Coordinated shutdown with hooks.

```zig
// Initialize shutdown manager
try vigil.shutdown.initGlobal(allocator);

// Register shutdown hooks
try vigil.onShutdown(struct {
    fn cleanup() void {
        std.debug.print("Cleaning up...\n", .{});
    }
}.cleanup);

// Trigger shutdown (hooks run in reverse order)
vigil.shutdownAll(.{
    .timeout_ms = 30_000,
    .order = .reverse,
});
```

---

### State Checkpointing

Persist and recover process state.

```zig
// File-based checkpointer
var file_ckpt = try vigil.FileCheckpointer.init(allocator, "/tmp/checkpoints");
defer file_ckpt.deinit();
const ckpt = file_ckpt.toCheckpointer();

// Save state
try ckpt.save("server_state", state_bytes);

// Load state
if (try ckpt.load("server_state", allocator)) |state| {
    defer allocator.free(state);
    // Restore state
}

// Memory checkpointer (for testing)
var mem_ckpt = vigil.MemoryCheckpointer.init(allocator);
defer mem_ckpt.deinit();
```

---

## Configuration Presets

| Preset | Max Restarts | Window | Health Check | Shutdown Timeout |
|--------|-------------|--------|--------------|------------------|
| `.production` | 3 | 60s | 5000ms | 30000ms |
| `.development` | 10 | 5s | 1000ms | 5000ms |
| `.high_availability` | 5 | 30s | 2000ms | 20000ms |
| `.testing` | 1 | 10s | 100ms | 1000ms |

```zig
var app = try vigil.appWithPreset(allocator, .production);
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

### Signal

```zig
pub const Signal = enum {
    restart, shutdown, terminate, exit,
    @"suspend", @"resume",
    healthCheck, memoryWarning, cpuWarning, deadlockDetected,
    messageErr, info, warning, debug, log, alert, metric, event, heartbeat,
    custom,
};
```

---

## Error Handling

### Inbox Errors

| Error | Description |
|-------|-------------|
| `InboxClosed` | Inbox was closed while waiting |
| `OutOfMemory` | Memory allocation failed |

### Message Errors

| Error | Description |
|-------|-------------|
| `MailboxFull` | Queue at capacity |
| `MessageExpired` | TTL elapsed |
| `MessageTooLarge` | Exceeds size limit |
| `DeliveryTimeout` | Send/receive timed out |

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

---

## Building and Testing

```bash
# Build the library
zig build

# Run all tests
zig build test

# Run example
zig build run
```

---

## Examples

See `examples/vigilant_server` for a complete TCP server with:
- Circuit breaker protection
- Rate limiting
- Telemetry integration
- Graceful shutdown

```bash
cd examples/vigilant_server
zig build
./zig-out/bin/vigilant_server
```
