# Vigil 0.3.0 API Reference

A process supervision and inter-process communication library for Zig, inspired by Erlang/OTP.

**Version: 0.3.0** - Featuring a simplified, intuitive high-level API with full backward compatibility.

## Table of Contents

- [Quick Start](#quick-start)
- [High-Level API (0.3.0+)](#high-level-api-03-and-later)
  - [Message Builder](#message-builder)
  - [Inbox API](#inbox-api)
  - [Supervisor Builder](#supervisor-builder)
  - [App Builder](#app-builder)
  - [Configuration Presets](#configuration-presets)
- [Low-Level API (Advanced)](#low-level-api-advanced)
- [Migration from 0.2.x to 0.3.x](#migration-from-02x-to-03x)
- [Error Handling](#error-handling)

---

## Quick Start

### Basic Example

```zig
const std = @import("std");
const vigil = @import("vigil");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a simple message
    var msg = try vigil.msg("Hello from Vigil")
        .from("main")
        .priority(.high)
        .build(allocator);
    defer msg.deinit();

    std.debug.print("Message: {s}\n", .{msg.payload.?});
}
```

---

## High-Level API (0.3+ and Later)

The new high-level API makes Vigil easy to use with sensible defaults and fluent builders.

### Message Builder

Create messages with a simple, chainable API:

```zig
var msg = try vigil.msg("Hello World")
    .from("sender_id")
    .priority(.high)
    .ttl(5000)
    .signal(.alert)
    .build(allocator);
defer msg.deinit();
```

**Options:**
- `from(sender: []const u8)` - Set the sender
- `priority(p: MessagePriority)` - Set priority (critical, high, normal, low, batch)
- `ttl(ms: u32)` - Set time-to-live in milliseconds
- `signal(sig: Signal)` - Set a signal type
- `withCorrelation(id: []const u8)` - Set correlation ID for tracking
- `replyTo(addr: []const u8)` - Set reply destination

### Inbox API

Channel-like message passing for simple send/receive patterns:

```zig
var inbox = try vigil.inbox(allocator);
defer inbox.close();

// Send messages
try inbox.send("message 1");
try inbox.send("message 2");

// Receive messages
const msg = try inbox.recv();
defer msg.deinit();
std.debug.print("Received: {s?}\n", .{msg.payload});

// Receive with timeout
if (try inbox.recvTimeout(1000)) |msg_opt| {
    if (msg_opt) |msg| {
        defer msg.deinit();
        // process message
    }
}
```

**Methods:**
- `send(payload: []const u8)` - Send a message
- `recv()` - Block until message received
- `recvTimeout(ms: u32)` - Receive with timeout (returns null on timeout)
- `stats()` - Get mailbox statistics

### Supervisor Builder

Configure process supervision with a fluent API:

```zig
var supervisor = vigil.supervisor(allocator);
try supervisor.child("worker_1", workerFunction);
try supervisor.child("worker_2", workerFunction);
supervisor = supervisor.strategy(.one_for_one);
supervisor = supervisor.maxRestarts(5);
supervisor = supervisor.maxSeconds(30);
supervisor.build();

try supervisor.start();
defer supervisor.stop();
```

**Configuration:**
- `strategy(s: RestartStrategy)` - Set restart strategy
- `maxRestarts(count: u32)` - Max restart count
- `maxSeconds(seconds: u32)` - Time window for restart counting
- `child(id: []const u8, fn: fn() void)` - Add a child process
- `build()` - Create the supervisor

**Restart Strategies:**
- `.one_for_one` - Restart only the failed process (default)
- `.one_for_all` - Restart all processes when any fails
- `.rest_for_one` - Restart failed process and all started after

### App Builder

Build applications with pre-configured supervision:

```zig
var app = try vigil.app(allocator)
    .worker("task_1", taskFunction)
    .worker("task_2", taskFunction)
    .workerPool("background", backgroundWorker, 4)
    .build();
defer app.shutdown();

try app.start();
```

**Methods:**
- `worker(id: []const u8, fn: fn() void)` - Add a single worker
- `workerPool(prefix: []const u8, fn: fn() void, count: usize)` - Add multiple workers
- `build()` - Build the application
- `start()` - Start all processes
- `stop()` - Stop all processes
- `shutdown()` - Graceful shutdown

### Configuration Presets

Built-in presets for common scenarios:

```zig
// Production: Conservative restarts, monitoring, clean logs
var app = try vigil.appWithPreset(allocator, .production);

// Development: Verbose logging, quick restarts, monitoring
var dev_app = try vigil.appWithPreset(allocator, .development);

// High Availability: Intensive health checks, balanced restarts
var ha_app = try vigil.appWithPreset(allocator, .high_availability);

// Testing: Minimal restarts, verbose logging, no monitoring
var test_app = try vigil.appWithPreset(allocator, .testing);
```

**Preset Settings:**

| Preset | Max Restarts | Window | Health Check | Monitoring | Logging |
|--------|-------------|--------|-------------|-----------|---------|
| Production | 3 | 60s | 5000ms | Yes | Normal |
| Development | 10 | 5s | 1000ms | Yes | Verbose |
| HA | 5 | 30s | 2000ms | Yes | Normal |
| Testing | 1 | 10s | 100ms | No | Verbose |

---

## Low-Level API (Advanced)

For advanced use cases, the full 0.2.x API is available via `vigil/legacy`:

```zig
const vigil_legacy = @import("vigil/legacy");

// Use 0.2.x API directly
const supervisor = vigil_legacy.Supervisor.init(allocator, .{
    .strategy = .one_for_all,
    .max_restarts = 5,
    .max_seconds = 30,
});

const mailbox = vigil_legacy.ProcessMailbox.init(allocator, .{
    .capacity = 1000,
    .priority_queues = true,
    .enable_deadletter = true,
    .default_ttl_ms = 30_000,
});
```

### Available Low-Level Types

- `vigil_legacy.Message` - Full message with all fields
- `vigil_legacy.ProcessMailbox` - Priority queue mailbox
- `vigil_legacy.Supervisor` - Process supervisor
- `vigil_legacy.SupervisorTree` - Hierarchical supervision
- `vigil_legacy.GenServer(State)` - Actor-like state machine
- And many more advanced types and functions

See the 0.2.2 documentation below for complete low-level API reference.

---

## Migration from 0.2.x to 0.3.x

### Backward Compatibility

**All existing 0.2.x code continues to work without changes!** The compatibility layer automatically forwards old APIs to the low-level implementation.

### Recommended Migration Path

#### Before (0.2.x):

```zig
// Complex setup with many parameters
const sup = try vigil.createSupervisor(allocator, .{
    .strategy = .one_for_one,
    .max_restarts = 3,
    .max_seconds = 5,
});

try sup.addChild(.{
    .id = "worker",
    .start_fn = workerFn,
    .restart_type = .permanent,
    .shutdown_timeout_ms = 5000,
    .priority = .normal,
});

try sup.start();
```

#### After (0.3.0):

```zig
// Simple, readable, with sensible defaults
var sup = vigil.supervisor(allocator);
try sup.child("worker", workerFn);
sup.build();
try sup.start();
```

### Migration Mapping

| 0.2.x | 0.3.0 |
|-------|-------|
| `vigil.ProcessMailbox.init()` | `vigil.inbox()` |
| `vigil.Message.init()` | `vigil.msg()...build()` |
| `vigil.createSupervisor()` | `vigil.supervisor()` |
| `supervisor.addChild()` | `supervisor.child()` |
| Manual GenServer setup | `vigil.server(State, Handlers)` |

### Deprecation Timeline

- **0.3.x** (Current): Old APIs work via compatibility layer
- **0.4.0**: Compatibility layer disabled by default (opt-in with `-Dlegacy_0_2`)
- **0.5.0**: Compatibility layer removed entirely

---

## Error Handling

### Common Errors

```zig
try mailbox.send(msg) catch |err| switch (err) {
    error.MailboxFull => std.debug.print("Mailbox is full\n", .{}),
    error.MessageExpired => std.debug.print("Message expired\n", .{}),
    error.OutOfMemory => std.debug.print("Out of memory\n", .{}),
    else => return err,
};
```

### Message Errors

- `EmptyMailbox` - No messages available
- `MailboxFull` - Mailbox capacity reached
- `MessageExpired` - Message TTL expired
- `MessageTooLarge` - Message exceeds size limits
- `OutOfMemory` - Memory allocation failed

### Supervisor Errors

- `TooManyRestarts` - Exceeded restart limit
- `ShutdownTimeout` - Graceful shutdown timed out
- `AlreadyMonitoring` - Monitoring already active

---

## Full 0.2.2 Low-Level API Reference

### Types

#### MessagePriority
```zig
pub const MessagePriority = enum {
    critical, // Immediate handling
    high,     // Urgent tasks
    normal,   // Standard operations
    low,      // Background tasks
    batch,    // Bulk operations
};
```

#### RestartStrategy
```zig
pub const RestartStrategy = enum {
    one_for_one,    // Restart only failed process
    one_for_all,    // Restart all processes
    rest_for_one,   // Restart failed + later processes
};
```

#### Signal
```zig
pub const Signal = enum {
    // Lifecycle
    restart, shutdown, terminate, exit,
    // Execution control
    @"suspend", @"resume",
    // Health
    healthCheck, memoryWarning, cpuWarning, deadlockDetected,
    // Operational
    messageErr, info, warning, debug, log, alert, metric, event, heartbeat,
    // Custom
    custom,
};
```

### Message (Low-Level)

```zig
// Create a message with all options
const msg = try vigil.Message.init(
    allocator,
    "msg_id",           // Unique ID
    "sender",           // Sender process
    "payload",          // Message content
    .alert,             // Signal type
    .high,              // Priority
    5000,               // TTL in milliseconds
);
defer msg.deinit();

// Set correlation ID
try msg.setCorrelationId("correlation_123");

// Set reply destination
try msg.setReplyTo("response_mailbox");

// Check expiration
if (msg.isExpired()) {
    // Handle expired message
}
```

### Supervisor (Low-Level)

```zig
const supervisor = vigil.Supervisor.init(allocator, .{
    .strategy = .one_for_one,
    .max_restarts = 3,
    .max_seconds = 5,
});

try supervisor.addChild(.{
    .id = "worker_1",
    .start_fn = workerFunction,
    .restart_type = .permanent,
    .shutdown_timeout_ms = 5000,
    .priority = .normal,
});

try supervisor.start();
try supervisor.startMonitoring();

const stats = supervisor.getStats();
try supervisor.shutdown(10000); // 10 second timeout
```

---

## Examples

See `examples/vigilant_server` for a complete server implementation.

```bash
zig build example-server
zig build test
```

---

## Version History

- **0.3.0** (Current)
  - New high-level API: `msg()`, `inbox()`, `supervisor()`, `app()`, presets
  - Full backward compatibility with 0.2.x
  - Comprehensive unit tests
  - Simplified examples

- **0.2.2** (Legacy)
  - Full-featured low-level API
  - Available at `@import("vigil/legacy")`

---

## Contributing

Contributions are welcome! Please ensure all tests pass:

```bash
zig build test
```
