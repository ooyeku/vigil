# Vigil API Reference

A process supervision and inter-process communication library for Zig, inspired by Erlang/OTP.

## Table of Contents

- [Quick Start](#quick-start)
- [Message Builder](#message-builder)
- [Inbox API](#inbox-api)
- [Supervisor Builder](#supervisor-builder)
- [App Builder](#app-builder)
- [Configuration Presets](#configuration-presets)
- [Low-Level API](#low-level-api)
- [Error Handling](#error-handling)
- [Types Reference](#types-reference)

---

## Quick Start

```zig
const std = @import("std");
const vigil = @import("vigil");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a supervised application
    var application = try vigil.app(allocator);
    _ = try application.worker("service", serviceFunction);
    _ = try application.workerPool("handlers", handlerFunction, 4);
    try application.build();
    defer application.shutdown();

    try application.start();
}

fn serviceFunction() void {
    // Your service logic
}

fn handlerFunction() void {
    // Your handler logic
}
```

---

## Message Builder

Create messages with a fluent, chainable API.

### Basic Usage

```zig
var msg = try vigil.msg("Hello World")
    .from("sender_id")
    .build(allocator);
defer msg.deinit();

std.debug.print("Payload: {s}\n", .{msg.payload.?});
```

### Full Options

```zig
var msg = try vigil.msg("Request data")
    .from("client_service")
    .priority(.high)
    .ttl(5000)                          // 5 second TTL
    .signal(.healthCheck)
    .withCorrelation("request_123")
    .replyTo("response_queue")
    .build(allocator);
defer msg.deinit();
```

### Builder Methods

| Method | Description |
|--------|-------------|
| `from(sender)` | Set the sender identifier |
| `priority(p)` | Set priority: `.critical`, `.high`, `.normal`, `.low`, `.batch` |
| `ttl(ms)` | Set time-to-live in milliseconds |
| `signal(sig)` | Attach a signal type |
| `withCorrelation(id)` | Set correlation ID for request tracking |
| `replyTo(addr)` | Set reply destination for responses |
| `build(allocator)` | Build the message (returns `!Message`) |

---

## Inbox API

Channel-like message passing for send/receive patterns between threads.

### Basic Usage

```zig
var inbox = try vigil.inbox(allocator);
defer inbox.close();

// Send messages
try inbox.send("message 1");
try inbox.send("message 2");

// Receive messages (blocking)
const msg = try inbox.recv();
defer msg.deinit();
std.debug.print("Received: {s}\n", .{msg.payload.?});
```

### Receive with Timeout

```zig
// Returns null on timeout, error on inbox closed
if (try inbox.recvTimeout(1000)) |msg| {
    defer msg.deinit();
    // Process message
} else {
    std.debug.print("No message within 1 second\n", .{});
}
```

### Thread-Safe Close

The inbox can be safely closed while other threads are waiting in `recv()` or `recvTimeout()`. Waiting threads will receive `error.InboxClosed`.

```zig
// Thread 1: Waiting for messages
while (true) {
    const msg = inbox.recv() catch |err| {
        if (err == error.InboxClosed) break;
        return err;
    };
    defer msg.deinit();
    // Process message
}

// Thread 2: Signal shutdown
inbox.close();
```

### Inbox Methods

| Method | Description |
|--------|-------------|
| `send(payload)` | Send a message payload |
| `recv()` | Block until message received (returns `!Message`) |
| `recvTimeout(ms)` | Receive with timeout (returns `!?Message`) |
| `isClosed()` | Check if inbox has been closed |
| `stats()` | Get mailbox statistics |
| `close()` | Close and cleanup the inbox |

### Inbox Errors

| Error | Description |
|-------|-------------|
| `InboxClosed` | Inbox was closed while waiting |
| `EmptyMailbox` | Internal - handled automatically |
| `OutOfMemory` | Memory allocation failed |

---

## Supervisor Builder

Configure process supervision with restart strategies.

### Basic Usage

```zig
var sup_builder = vigil.supervisor(allocator);
_ = try sup_builder.child("worker_1", workerFunction);
_ = try sup_builder.child("worker_2", workerFunction);
sup_builder = sup_builder.strategy(.one_for_one);
sup_builder = sup_builder.maxRestarts(5);
sup_builder = sup_builder.maxSeconds(30);

var supervisor = sup_builder.build();
defer supervisor.deinit();

try supervisor.start();
defer supervisor.stop();
```

### Configuration Methods

| Method | Description |
|--------|-------------|
| `strategy(s)` | Set restart strategy |
| `maxRestarts(count)` | Maximum restarts within time window |
| `maxSeconds(seconds)` | Time window for restart counting |
| `child(id, fn)` | Add a child process |
| `build()` | Create the supervisor |

### Restart Strategies

| Strategy | Description |
|----------|-------------|
| `.one_for_one` | Restart only the failed process (default) |
| `.one_for_all` | Restart all processes when any fails |
| `.rest_for_one` | Restart failed process and all started after it |

### Supervisor Lifecycle

```zig
var supervisor = sup_builder.build();
defer supervisor.deinit();      // Cleanup resources

try supervisor.start();          // Start all children
try supervisor.startMonitoring(); // Start failure monitoring

// ... application runs ...

supervisor.stop();               // Graceful shutdown with 5s timeout
// Or for custom timeout:
try supervisor.shutdown(10000);  // 10 second timeout
```

### Supervisor Methods

| Method | Description |
|--------|-------------|
| `start()` | Start all child processes |
| `stop()` | Graceful shutdown (5 second timeout) |
| `shutdown(timeout_ms)` | Shutdown with custom timeout |
| `startMonitoring()` | Start the failure monitoring thread |
| `stopMonitoring()` | Stop the monitoring thread |
| `getStats()` | Get supervisor statistics |
| `findChild(id)` | Find child by ID |
| `terminateChild(id)` | Stop a specific child |
| `deleteChild(id)` | Remove child from supervision |
| `deinit()` | Cleanup all resources |

---

## App Builder

Build applications with pre-configured supervision and sensible defaults.

### Basic Usage

```zig
var application = try vigil.app(allocator);
_ = try application.worker("service", serviceFunction);
_ = try application.workerPool("handlers", handlerFunction, 4);
try application.build();
defer application.shutdown();

try application.start();
```

### With Preset Configuration

```zig
var application = try vigil.appWithPreset(allocator, .development);
_ = try application.worker("debug_service", debugFunction);
try application.build();
defer application.shutdown();

try application.start();
```

### App Builder Methods

| Method | Description |
|--------|-------------|
| `worker(id, fn)` | Add a single worker process |
| `workerPool(prefix, fn, count)` | Add multiple workers with numbered IDs |
| `build()` | Finalize the application |
| `start()` | Start all processes |
| `stop()` | Stop all processes |
| `shutdown()` | Graceful shutdown and cleanup |

---

## Configuration Presets

Built-in presets for common deployment scenarios.

### Available Presets

```zig
// Production: Conservative restarts, longer health checks
var prod = try vigil.appWithPreset(allocator, .production);

// Development: Quick restarts, verbose logging
var dev = try vigil.appWithPreset(allocator, .development);

// High Availability: Balanced for uptime
var ha = try vigil.appWithPreset(allocator, .high_availability);

// Testing: Minimal restarts, fast health checks
var test_app = try vigil.appWithPreset(allocator, .testing);
```

### Preset Configuration Values

| Preset | Max Restarts | Window | Health Check | Shutdown Timeout | Mailbox Capacity |
|--------|-------------|--------|--------------|------------------|------------------|
| `.production` | 3 | 60s | 5000ms | 30000ms | 1000 |
| `.development` | 10 | 5s | 1000ms | 5000ms | 100 |
| `.high_availability` | 5 | 30s | 2000ms | 20000ms | 5000 |
| `.testing` | 1 | 10s | 100ms | 1000ms | 50 |

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
    .health_check_fn = healthCheckFunction,
    .health_check_interval_ms = 1000,
});

try supervisor.start();
```

### Direct Message Creation

```zig
var msg = try vigil.Message.init(
    allocator,
    "msg_id",           // Unique message ID
    "sender",           // Sender identifier
    "payload",          // Message content
    .alert,             // Signal type (optional)
    .high,              // Priority
    5000,               // TTL in milliseconds (optional)
);
defer msg.deinit();

// Set correlation for request tracking
try msg.setCorrelationId("correlation_123");

// Set reply destination
try msg.setReplyTo("response_mailbox");

// Check if expired
if (msg.isExpired()) {
    // Handle expired message
}
```

### Direct Mailbox Creation

```zig
var mailbox = vigil.ProcessMailbox.init(allocator, .{
    .capacity = 1000,
    .priority_queues = true,
    .enable_deadletter = true,
    .default_ttl_ms = 30_000,
    .max_message_size = 1024 * 1024,  // 1MB
});
defer mailbox.deinit();

try mailbox.send(msg);

const received = try mailbox.receive();
defer received.deinit();
```

---

## Error Handling

### Message Errors

```zig
mailbox.send(msg) catch |err| switch (err) {
    error.MailboxFull => {
        // Queue is at capacity
    },
    error.MessageExpired => {
        // Message TTL elapsed before send
    },
    error.MessageTooLarge => {
        // Message exceeds max_message_size
    },
    error.OutOfMemory => {
        // Allocation failed
    },
    else => return err,
};
```

| Error | Description |
|-------|-------------|
| `EmptyMailbox` | No messages available |
| `MailboxFull` | Mailbox capacity reached |
| `MessageExpired` | Message TTL expired |
| `MessageTooLarge` | Message exceeds size limits |
| `DuplicateMessage` | Message ID already exists |
| `OutOfMemory` | Memory allocation failed |

### Supervisor Errors

```zig
supervisor.shutdown(5000) catch |err| switch (err) {
    error.TooManyRestarts => {
        // Exceeded restart limit
    },
    error.ShutdownTimeout => {
        // Children didn't stop in time
    },
    else => return err,
};
```

| Error | Description |
|-------|-------------|
| `TooManyRestarts` | Exceeded restart limit within time window |
| `ShutdownTimeout` | Graceful shutdown timed out |
| `AlreadyMonitoring` | Monitoring thread already active |
| `ChildNotFound` | Child with given ID doesn't exist |

### Inbox Errors

| Error | Description |
|-------|-------------|
| `InboxClosed` | Inbox was closed |

---

## Types Reference

### MessagePriority

```zig
pub const MessagePriority = enum {
    critical,  // Immediate handling required
    high,      // Urgent but not critical
    normal,    // Standard operations (default)
    low,       // Background tasks
    batch,     // Bulk operations
};
```

### RestartStrategy

```zig
pub const RestartStrategy = enum {
    one_for_one,   // Restart only failed process
    one_for_all,   // Restart all processes
    rest_for_one,  // Restart failed + subsequent processes
};
```

### Signal

```zig
pub const Signal = enum {
    // Lifecycle
    restart, shutdown, terminate, exit,
    
    // Execution control
    @"suspend", @"resume",
    
    // Health and monitoring
    healthCheck, memoryWarning, cpuWarning, deadlockDetected,
    
    // Operational
    messageErr, info, warning, debug, log, alert, metric, event, heartbeat,
    
    // Custom
    custom,
};
```

### ChildSpec

```zig
pub const ChildSpec = struct {
    id: []const u8,                              // Unique identifier
    start_fn: *const fn () void,                 // Function to execute
    restart_type: enum { permanent, transient, temporary },
    shutdown_timeout_ms: u32,                    // Shutdown wait time
    priority: ProcessPriority = .normal,
    max_memory_bytes: ?usize = null,             // Memory limit
    health_check_fn: ?*const fn () bool = null,  // Health check callback
    health_check_interval_ms: u32 = 1000,
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

### SupervisorStats

```zig
pub const SupervisorStats = struct {
    total_restarts: u32,      // Total restarts since start
    uptime_ms: i64,           // Supervisor uptime
    last_failure_time: i64,   // Last failure timestamp
    active_children: u32,     // Currently running children
};
```

### MailboxStats

```zig
pub const MailboxStats = struct {
    messages_received: usize,
    messages_sent: usize,
    messages_expired: usize,
    messages_dropped: usize,
    peak_usage: usize,
    total_size_bytes: usize,
};
```

---

## Building and Testing

```bash
# Build the library
zig build

# Run all tests
zig build test

# Run tests with summary
zig build test --summary all
```

---

## Examples

See `examples/vigilant_server` for a complete TCP server implementation demonstrating:

- Connection pooling
- Graceful shutdown handling
- Signal handling (Ctrl-C)
- Server metrics and health checks

```bash
# Build and run the example server
cd examples/vigilant_server
zig build
./zig-out/bin/vigilant_server
```
