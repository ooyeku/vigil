# Vigil

A process supervision and inter-process communication library for Zig, designed for building reliable distributed systems and concurrent applications.

**Version: 0.5.0**

## Installation

Fetch latest release:

```bash
zig fetch --save "git+https://github.com/ooyeku/vigil/#v0.5.0"
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

### Basic Message Passing

```zig
const vigil = @import("vigil");

// Create a simple message
var msg = try vigil.msg("Hello World")
    .from("sender")
    .priority(.high)
    .ttl(5000)
    .build(allocator);
defer msg.deinit();
```

### Simple Worker Pool

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

    var application = try vigil.app(allocator);
    _ = try application.worker("task1", worker);
    _ = try application.workerPool("pool", worker, 4);
    try application.build();
    defer application.shutdown();

    try application.start();
}
```

### Channel-Like Message Inbox

```zig
var inbox = try vigil.inbox(allocator);
defer inbox.close();

try inbox.send("message 1");
try inbox.send("message 2");

// Receive with timeout - returns null on timeout, error on inbox closed
if (try inbox.recvTimeout(1000)) |msg| {
    defer msg.deinit();
    std.debug.print("Received: {s}\n", .{msg.payload.?});
}
```

### Supervisor with Child Processes

```zig
var sup_builder = vigil.supervisor(allocator);
_ = try sup_builder.child("worker_1", workerFn);
_ = try sup_builder.child("worker_2", workerFn);
sup_builder = sup_builder.strategy(.one_for_one);

var supervisor = sup_builder.build();
defer supervisor.deinit();

try supervisor.start();
defer supervisor.stop();
```

### Configuration Presets

```zig
// Production preset: conservative restarts, monitoring enabled
var app = try vigil.appWithPreset(allocator, .production);

// Development preset: verbose logging, quick restarts
var dev_app = try vigil.appWithPreset(allocator, .development);

// High availability mode: intensive health checks
var ha_app = try vigil.appWithPreset(allocator, .high_availability);

// Testing preset: minimal restarts, fast health checks
var test_app = try vigil.appWithPreset(allocator, .testing);
```

## Features

- **Intuitive High-Level API**: Fluent builders with sensible defaults
- **Channel-Like Messaging**: `inbox()` for easy thread-safe message passing
- **Process Supervision**: Automatic restart strategies (one_for_one, one_for_all, rest_for_one)
- **Configuration Presets**: Built-in configurations for production, development, HA, and testing
- **Priority Message Queues**: Route critical messages before background tasks
- **Thread-Safe**: Safe concurrent close/receive operations on inboxes
- **Memory Safe**: Proper cleanup of all allocated resources

## Advanced Usage

For advanced use cases, access the low-level API directly:

```zig
const vigil = @import("vigil");

// Direct Supervisor creation with full control
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
});

try supervisor.start();
```

See [docs/api.md](docs/api.md) for comprehensive API documentation.

## Examples

See [examples/vigilant_server](examples/vigilant_server) for a complete TCP server implementation.

```bash
cd examples/vigilant_server
zig build
./zig-out/bin/vigilant_server
```

## Running Tests

```bash
zig build test
```

## Requirements

- Zig 0.15.1 or later
- POSIX-compliant operating system

## License

MIT - see the [LICENSE](LICENSE) file for details.

## Contributing

Contributions are welcome! Please ensure all tests pass before submitting a Pull Request:

```bash
zig build test --summary all
```
