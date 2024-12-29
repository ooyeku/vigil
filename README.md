# Vigil

A process supervision and inter-process communication library for Zig, designed for building reliable distributed systems and concurrent applications.

## Features

### Process Supervision
- One-for-all restart strategy
- Configurable restart limits and timeframes
- Graceful shutdown handling
- Process state monitoring and health checks

### Message Passing System
- Priority-based message queues (5 priority levels)
- Message TTL (Time-To-Live) support
- Dead letter queue for undeliverable messages
- Thread-safe mailbox operations
- Message correlation and request-response patterns
- Distributed tracing support via trace IDs

### Message Types and Signals
- Structured message format with metadata
- Built-in signal types for common operations
- Support for custom signals and payloads
- Message size limits and capacity controls
- Message expiration handling

### Performance Monitoring
- Detailed mailbox statistics
- Memory usage tracking
- Message throughput metrics
- Peak usage monitoring
- Size-based metrics

## Use Cases

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

## Installation

Add as a dependency in your `build.zig.zon`:

```zig
.{
    .name = "your_project",
    .version = "0.1.0",
    .dependencies = .{
        .vigil = .{
            .url = "https://github.com/your-username/vigil/archive/refs/tags/v0.1.0.tar.gz",
            // TODO: Add hash after publishing
        },
    },
}
```

## Requirements
- Zig 0.13.0 or later
- POSIX-compliant operating system

## License

MIT - see the [LICENSE](LICENSE) file for details.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
