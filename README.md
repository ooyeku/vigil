# Vigil

A process supervision and inter-process communication library for Zig, designed for building reliable distributed systems and concurrent applications.

## Features
- Process supervision
- Inter-process communication
- Priority-based message passing
- Message correlation and request-response patterns
- Distributed tracing support
- System monitoring and metrics collection
- Fault-tolerant system design

## Potential Use Cases

### Microservices Architecture
- Process-to-process communication
- Service health monitoring
- Load balancing via priority queues
- Request routing and correlation
- Distributed tracing

### Background Job Processing
- Priority-based job scheduling
- Batch processing coordination
- Worker pool management
- Job status monitoring
- Failed job handling via dead letter queue

### System Monitoring
- Health check implementation
- Resource usage monitoring
- Alert propagation
- Metric collection
- Log aggregation

### Fault-Tolerant Systems
- Process recovery
- Message delivery guarantees
- Error propagation
- Graceful degradation
- System state management

## Installation
Fetch latest release:

```bash
zig fetch --save "git+https://github.com/ooyeku/vigil/#v0.1.1"
```

Add as a dependency in your `build.zig.zon`:

```zig
    const vigil = b.dependency("vigil", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("vigil", vigil.module("vigil_lib"));
    b.installArtifact(exe);
```
## Getting Started

```zig
const std = @import("std");
const vigil = @import("vigil");

// Initialize a mailbox
var mailbox = vigil.ProcessMailbox.init(allocator, .{
    .capacity = 100,
    .max_message_size = 1024 * 1024, // 1MB
    .default_ttl_ms = 5000, // 5 seconds
    .priority_queues = true,
    .enable_deadletter = true,
});
defer mailbox.deinit();

// Send a high-priority message
const msg = try vigil.Message.init(
    allocator,
    "status_update",
    "worker_1",
    "CPU usage high",
    .cpuWarning,
    .high,
    5000, // 5 second TTL
);
try mailbox.send(msg);

// Process messages with priority handling
while (mailbox.receive()) |received| {
    defer received.deinit();
    if (received.signal) |signal| {
        switch (signal) {
            .cpuWarning => handleCpuWarning(received),
            .healthCheck => sendHealthStatus(),
            else => handleOtherSignal(received),
        }
    }
} else |err| switch (err) {
    error.EmptyMailbox => break,
    else => return err,
}
```

## Requirements
- Zig 0.13.0 or later
- POSIX-compliant operating system

## License

MIT - see the [LICENSE](LICENSE) file for details.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
