# Vigil

A process supervision and inter-process communication library for Zig, designed for building reliable distributed systems and concurrent applications.

**Version: 0.3.0** - Now with a simplified, intuitive high-level API!

## Installation

Fetch latest release:

```bash
zig fetch --save "git+https://github.com/ooyeku/vigil/#v0.3.0"
```

Add as a dependency in your `build.zig.zon`:

```zig
const vigil = b.dependency("vigil", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("vigil", vigil.module("vigil"));
b.installArtifact(exe);
```

## Quick Start (0.3.0 High-Level API)

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
fn worker() void {
    std.debug.print("Worker running\n", .{});
    std.Thread.sleep(100 * std.time.ns_per_ms);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try vigil.app(allocator)
        .worker("task1", worker)
        .workerPool("pool", worker, 4)
        .build();
    defer app.shutdown();
    
    try app.start();
}
```

### Channel-Like Message Inbox

```zig
var inbox = try vigil.inbox(allocator);
defer inbox.close();

try inbox.send("message 1");
try inbox.send("message 2");

if (try inbox.recvTimeout(1000)) |msg_opt| {
    if (msg_opt) |msg| {
        std.debug.print("Received: {s?}\n", .{msg.payload});
        msg.deinit();
    }
}
```

### Supervisor with Child Processes

```zig
var supervisor = vigil.supervisor(allocator);
try supervisor.child("worker_1", workerFn);
try supervisor.child("worker_2", workerFn);
supervisor.build();
```

### Configuration Presets

```zig
// Production preset: conservative restarts, monitoring enabled
var app = try vigil.appWithPreset(allocator, .production);

// Development preset: verbose logging, quick restarts
var dev_app = try vigil.appWithPreset(allocator, .development);

// High availability mode: intensive health checks
var ha_app = try vigil.appWithPreset(allocator, .high_availability);
```

## Features

- **Simplified High-Level API**: Intuitive builders with sensible defaults
- **Channel-Like Messaging**: `inbox()` for easy message passing
- **Fluent Configuration**: Builder pattern for supervisor and app setup
- **Configuration Presets**: Built-in configurations for common scenarios (production, development, HA, testing)
- **Process Supervision**: Automatic restart strategies (one_for_one, one_for_all, rest_for_one)
- **Priority Message Queues**: Route critical messages before background tasks
- **Backward Compatible**: 0.2.x code still works via compatibility layer

## Advanced Usage (Low-Level API)

For advanced use cases, the full low-level API remains available:

```zig
const vigil_legacy = @import("vigil/legacy");

// Access all 0.2.x functionality
const supervisor = try vigil_legacy.Supervisor.init(allocator, .{
    .strategy = .one_for_all,
    .max_restarts = 5,
    .max_seconds = 30,
});
```

See [docs/api.md](docs/api.md) for comprehensive documentation.

## Examples

See [examples/vigilant_server](examples/vigilant_server) for a complete server implementation using the high-level API.

```bash
zig build example-server
```

## Running Tests

```bash
zig build test
```

## Requirements

- Zig 0.15.1 or later
- POSIX-compliant operating system

## Migration from 0.2.x

All 0.2.x code continues to work without changes. To use the new simplified API, see the examples above and the [migration guide in docs/api.md](docs/api.md#migration-from-02x-to-03x).

## License

MIT - see the [LICENSE](LICENSE) file for details.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request. 
