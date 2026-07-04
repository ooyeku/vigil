# Vigil

A process supervision and inter-process communication library for Zig, designed for building reliable distributed systems and concurrent applications. Inspired by Erlang/OTP.

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
    vigil.compat.sleep(100 * std.time.ns_per_ms);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try vigil.app(allocator);
    _ = try app.worker("task1", worker);
    _ = try app.workerPool("pool", worker, 4);
    try app.start();
    defer app.shutdown();
}
```

### Runtime-Owned Services

```zig
var rt = try vigil.runtime(allocator, .{});
defer rt.deinit();

var inbox = try rt.inbox(.{ .capacity = 128 });
defer inbox.close();

try inbox.send("hello from the runtime");

var snapshot = try rt.snapshot(allocator);
defer snapshot.deinit();

const health = try rt.health(allocator);
if (!health.ready) {
    // Surface degraded runtime state in your service health endpoint.
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

### Reliability Policy

```zig
const Result = enum { ok, fallback };

const Client = struct {
    attempts: u32 = 0,

    fn call(self: *@This()) anyerror!Result {
        self.attempts += 1;
        if (self.attempts < 3) return error.TemporaryFailure;
        return .ok;
    }

    fn fallback(_: *@This(), _: vigil.PolicyFailure) anyerror!Result {
        return .fallback;
    }
};

var client = Client{};
const result = vigil.executePolicy(Client, Result, &client, Client.call, .{
    .retry = .{
        .max_attempts = 3,
        .backoff = .{ .exponential = .{ .initial_ms = 10, .max_ms = 100 } },
    },
    .timeout_ms = 500,
    .fallback = Client.fallback,
});

switch (result) {
    .success => |success| std.debug.print("result={s}\n", .{@tagName(success.value)}),
    .fallback => |fallback| std.debug.print("fallback={s} from={s}\n", .{
        @tagName(fallback.value),
        @tagName(fallback.report.fallback_from.?),
    }),
    .timeout => |failure| std.debug.print("timeout after {d} attempt(s)\n", .{failure.attempts}),
    .circuit_open => |failure| std.debug.print("circuit open after {d} attempt(s)\n", .{failure.attempts}),
    .permanent_failure => |failure| std.debug.print("failed outcome={s}\n", .{@tagName(failure.outcome)}),
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
- **Owned Runtime** - Registry, telemetry, shutdown, inboxes, and supervisors under one owner
- **Fluent Builders** - Intuitive API with sensible defaults
- **Configuration Presets** - Production, development, HA, and testing modes

### Resilience 

- **Reliability Policies** - Compose retry, backoff, timeout, fallback, and circuit breakers around fallible operations
- **Circuit Breaker** - Protect services from cascading failures
- **Rate Limiting** - Token bucket algorithm for flow control
- **Backpressure** - Strategies for handling overload (drop_oldest, drop_newest, block, error)

### Messaging 

- **Pub/Sub** - Topic-based messaging with wildcard support
- **Process Groups** - Manage related processes with broadcast/round-robin routing
- **Request/Reply** - Synchronous messaging with correlation IDs

### Observability

- **Telemetry** - Event hooks for monitoring (process, message, supervisor, circuit events)
- **Runtime Introspection** - Snapshot registered mailboxes, queue depth, handlers, hooks, process groups, pub/sub brokers, timers, circuit breakers, and readiness
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

The root package is library-only: use `zig build test` at the repository root, and run examples from their own directories.

See [examples/vigil_showcase](examples/vigil_showcase) for a self-contained resilient order pipeline that demonstrates:
- Runtime-owned registry, telemetry, shutdown hooks, and inboxes
- Reliability policies for retry/backoff/fallback around a payment dependency
- Process groups for worker routing and operations broadcast
- Pub/Sub event fanout for audit and alert streams
- Inbox backpressure, rate limiting, and circuit breaker behavior

```bash
cd examples/vigil_showcase
zig build run
```

See [examples/vigilant_server](examples/vigilant_server) for a complete TCP server with:
- Circuit breaker protection
- Rate limiting
- Telemetry integration
- Graceful shutdown

```bash
cd examples/vigilant_server
zig build run
```

## Benchmarks

The root package stays library-only. Run the standalone benchmark harness from its own package:

```bash
cd benchmarks/vigil_bench
zig build run -Doptimize=ReleaseSafe -- --iterations 10000
```

The v2.1 benchmark harness reports throughput, average latency, and observed allocator calls per operation for inbox send/receive, registry lookup/register, telemetry emission, timer scheduling, process-group routing/broadcast, pub/sub fanout, request/reply correlation, and concurrent inbox contention. See [benchmarks/vigil_bench](benchmarks/vigil_bench) for the current baseline.

## Documentation

See [docs/api.md](docs/api.md) for comprehensive API documentation.

## Migrating to 2.0

Vigil 2.0 removes the old 0.2 compatibility helpers from the root `vigil` module. Code that needs historical low-level types should import `vigil/legacy` explicitly. New code should use `vigil.Runtime`, `vigil.app`, `vigil.supervisor`, `vigil.inbox`, and `vigil.GenServer`.

## Running Tests

```bash
zig build test
```

## Requirements

- Zig 0.16.x
- Core runtime support for Zig's native thread targets
- Distributed TCP registry and networking examples currently use the bundled POSIX socket compatibility layer

## License

MIT - see the [LICENSE](LICENSE) file for details.
