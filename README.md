# Vigil

A process supervision and inter-process communication library for Zig, designed for building reliable distributed systems and concurrent applications. Inspired by Erlang/OTP.

**Version: 1.0.1**

## Installation

```bash
zig fetch --save "git+https://github.com/ooyeku/vigil"
```

Add as a dependency in your `build.zig`:

```zig
const vigil = b.dependency("vigil", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("vigil", vigil.module("vigil"));
```

## Quick Start

### Simple Worker Application

```zig
const std = @import("std");
const vigil = @import("vigil");

fn worker() void {
    std.debug.print("Worker running\n", .{});
    std.Thread.sleep(100 * std.time.ns_per_ms);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try vigil.app(allocator);
    _ = try app.worker("task1", worker);
    _ = try app.workerPool("pool", worker, 4);
    try app.start();
    defer app.shutdown();
}
```

### Channel-Like Message Passing

```zig
var inbox = try vigil.inbox(allocator);
defer inbox.close();

try inbox.send("hello");

if (try inbox.recvTimeout(1000)) |msg| {
    defer msg.deinit();
    std.debug.print("Received: {s}\n", .{msg.payload.?});
}
```

### Circuit Breaker for Resilience

```zig
var breaker = try vigil.CircuitBreaker.init(allocator, "api", .{
    .failure_threshold = 5,
    .reset_timeout_ms = 30000,
});
defer breaker.deinit();

if (breaker.getState() == .open) {
    // Service unavailable, fail fast
}
```

### Rate Limiting

```zig
var limiter = vigil.RateLimiter.init(100); // 100 ops/sec

if (limiter.allow()) {
    // Process request
} else {
    // Rate limited
}
```

### Process Groups

```zig
var group = try vigil.ProcessGroup.init(allocator, "workers");
defer group.deinit();

try group.add("worker1", inbox1);
try group.add("worker2", inbox2);

try group.broadcast("message");  // Send to all
try group.roundRobin("message"); // Load balance
```

## Features

### Core

- **Process Supervision** - Automatic restart strategies (one_for_one, one_for_all, rest_for_one)
- **Message Passing** - Thread-safe inboxes with priority queues
- **Fluent Builders** - Intuitive API with sensible defaults
- **Configuration Presets** - Production, development, HA, and testing modes

### Resilience 

- **Circuit Breaker** - Protect services from cascading failures
- **Rate Limiting** - Token bucket algorithm for flow control
- **Backpressure** - Strategies for handling overload (drop_oldest, drop_newest, block, error)

### Messaging 

- **Pub/Sub** - Topic-based messaging with wildcard support
- **Process Groups** - Manage related processes with broadcast/round-robin routing
- **Request/Reply** - Synchronous messaging with correlation IDs

### Observability

- **Telemetry** - Event hooks for monitoring (process, message, supervisor, circuit events)
- **Testing Utilities** - Mock inboxes, mock supervisors, time control

### Advanced

- **Graceful Shutdown** - Coordinated cleanup with shutdown hooks
- **State Checkpointing** - Persist and recover process state
- **Distributed Registry** - Cross-process name resolution

## Configuration Presets

```zig
// Production: conservative restarts, monitoring enabled
var app = try vigil.appWithPreset(allocator, .production);

// Development: verbose logging, quick restarts
var app = try vigil.appWithPreset(allocator, .development);

// High availability: intensive health checks
var app = try vigil.appWithPreset(allocator, .high_availability);

// Testing: minimal restarts, fast health checks
var app = try vigil.appWithPreset(allocator, .testing);
```

## Examples

See [examples/vigilant_server](examples/vigilant_server) for a complete TCP server with:
- Circuit breaker protection
- Rate limiting
- Telemetry integration
- Graceful shutdown

```bash
cd examples/vigilant_server
zig build
./zig-out/bin/vigilant_server
```

## Documentation

See [docs/api.md](docs/api.md) for comprehensive API documentation.

## Running Tests

```bash
zig build test
```

## Requirements

- Zig 0.15.x
- POSIX-compliant operating system

## License

MIT - see the [LICENSE](LICENSE) file for details.
