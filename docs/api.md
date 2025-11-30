# Vigil API Reference v1.0.0

A process supervision and inter-process communication library for Zig, inspired by Erlang/OTP.

## Table of Contents

- [Quick Start](#quick-start)
- [Core API](#core-api)
  - [Message Builder](#message-builder)
  - [Inbox API](#inbox-api)
  - [Inbox Builder](#inbox-builder)
  - [Supervisor Builder](#supervisor-builder)
  - [Supervisor Introspection](#supervisor-introspection)
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
  - [Distributed Registry](#distributed-registry)
  - [Registry](#registry)
  - [Timer](#timer)
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
| `recvTimeout(ms)` | Receive with timeout (returns `?Message`) |
| `isClosed()` | Check if inbox is closed |
| `stats()` | Get mailbox statistics |
| `close()` | Close the inbox |

---

### Inbox Builder

Create inboxes with custom configuration using a fluent builder.

```zig
var inbox = try vigil.inboxBuilder(allocator)
    .capacity(1000)
    .priorityQueues(true)
    .deadLetter(true)
    .defaultTTL(30_000)
    .build();
defer inbox.close();
```

| Method | Description |
|--------|-------------|
| `capacity(n)` | Set maximum message capacity |
| `priorityQueues(bool)` | Enable/disable priority queues |
| `deadLetter(bool)` | Enable/disable dead letter queue |
| `defaultTTL(ms)` | Set default message TTL |
| `withRateLimit(config)` | Add rate limiting |
| `withBackpressure(config)` | Add backpressure handling |
| `build()` | Create the inbox |

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
| `build()` | Create the supervisor |

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

// Get specific child info
if (supervisor.getChildInfo("worker_1")) |child| {
    std.debug.print("Child state: {s}\n", .{@tagName(child.state)});
}

// Runtime control
try supervisor.restartChild("worker_1");
try supervisor.suspendChild("worker_1");
try supervisor.resumeChild("worker_1");

// Dynamic scaling (reduces workers with prefix)
try supervisor.scaleWorkers("worker", 2);
```

| Method | Description |
|--------|-------------|
| `inspect()` | Get supervisor state snapshot |
| `getChildInfo(id)` | Get specific child info |
| `restartChild(id)` | Force restart a child |
| `suspendChild(id)` | Pause a child |
| `resumeChild(id)` | Resume a paused child |
| `scaleWorkers(prefix, count)` | Scale workers to target count |
| `getRestartHistory()` | Get recent restart events |

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
| `getState()` | Get current circuit state |
| `getFailureCount()` | Get failure count |
| `forceOpen()` | Manually open circuit |
| `forceClose()` | Manually close circuit |

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
const member_count = group.memberCount();
```

| Method | Description |
|--------|-------------|
| `add(id, inbox)` | Add a member |
| `remove(id)` | Remove a member |
| `count()` | Get member count |
| `broadcast(payload)` | Send to all members |
| `roundRobin(payload)` | Distribute evenly |
| `route(payload, key)` | Consistent hash routing |

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

// Check if matches topic
if (subscriber.matches("events.user.created")) {
    // Will receive this topic
}

// Publish messages
try vigil.publish("events.user.created", "user_data");
try vigil.publish("events.system.alert", "alert_data");

// Use broker directly
var broker = vigil.pubsub.PubSubBroker.init(allocator);
defer broker.deinit();
try broker.subscribe(&subscriber);
try broker.publish("topic", "payload");
broker.unsubscribe(&subscriber);
```

**Wildcard Patterns:**
- `*` - Match single level (e.g., `events.*` matches `events.user`)
- `#` - Match multiple levels (e.g., `events.#` matches `events.user.created`)

---

### Request/Reply

Synchronous messaging with automatic correlation.

```zig
// Create request with correlation ID
var request_msg = try vigil.Message.init(
    allocator, "req1", "client", "request_data", null, .normal, null
);
defer request_msg.deinit();
try request_msg.setCorrelationId("corr_123");

// Create reply (preserves correlation ID)
var response = try vigil.reply(request_msg, "response_data", allocator);
defer response.deinit();
// response.metadata.correlation_id == "corr_123"

// Using ReplyMailbox for waiting
var reply_mailbox = vigil.request_reply.ReplyMailbox.init(allocator, inbox);
defer reply_mailbox.deinit();

const reply_msg = try reply_mailbox.waitForReply("corr_123", 5000);
defer reply_msg.deinit();
```

---

## Observability

### Telemetry

Event hooks for monitoring and debugging. Thread-safe event emission.

```zig
// Initialize global telemetry
try vigil.telemetry.initGlobal(allocator);

// Register event handlers
if (vigil.telemetry.getGlobal()) |emitter| {
    try emitter.on(.process_started, struct {
        fn handler(event: vigil.telemetry.Event) void {
            std.debug.print("Event: {s} at {d}ms\n", .{
                @tagName(event.event_type),
                event.timestamp_ms,
            });
        }
    }.handler);
}

// Emit events (thread-safe)
vigil.telemetry.emit(.{
    .event_type = .message_sent,
    .timestamp_ms = std.time.milliTimestamp(),
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
| Message | `message_sent`, `message_received`, `message_expired`, `message_dropped` |
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

---

## Advanced

### Graceful Shutdown

Coordinated shutdown with hooks. Hooks run in configurable order.

```zig
// Initialize shutdown manager
try vigil.shutdown.initGlobal(allocator);

// Register shutdown hooks
try vigil.onShutdown(struct {
    fn cleanup() void {
        std.debug.print("Cleaning up...\n", .{});
    }
}.cleanup);

// Trigger shutdown (hooks run in reverse order by default)
vigil.shutdownAll(.{
    .timeout_ms = 30_000,
    .order = .reverse,  // or .forward
});

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

---

### Distributed Registry

Cross-process name resolution for distributed systems.

```zig
var registry = try vigil.DistributedRegistry.init(allocator, .{
    .cluster_nodes = &.{"node1:9001", "node2:9002"},
    .sync_interval_ms = 1000,
    .heartbeat_timeout_ms = 5000,
});
defer registry.deinit();

// Register process (local or global scope)
try registry.register("my_service", mailbox, .global);

// Lookup process
if (registry.whereis("my_service")) |mailbox| {
    // Use mailbox
}

// Start/stop cluster synchronization
try registry.startSync();
registry.stopSync();
```

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

### Message Errors

| Error | Description |
|-------|-------------|
| `MailboxFull` | Queue at capacity |
| `MessageExpired` | TTL elapsed |
| `MessageTooLarge` | Exceeds size limit |
| `DeliveryTimeout` | Send/receive timed out |
| `InvalidMessage` | Message validation failed |
| `ReceiverUnavailable` | Receiver not available |

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

### Process Group Errors

| Error | Description |
|-------|-------------|
| `NoMembers` | Group has no members |
| `OutOfMemory` | Memory allocation failed |

---

## Building and Testing

```bash
# Build the library
zig build

# Run all tests
zig build test

# Run example
zig build run

# Build vigilant server example
cd examples/vigilant_server
zig build
./zig-out/bin/vigilant_server
```

---

## Examples

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
