# Vigil

Note: API is subject to change (hopefully for the better)

A process supervision and inter-process communication library for Zig, designed for building reliable distributed systems and concurrent applications.

## Installation

Fetch latest release:

```bash
zig fetch --save "git+https://github.com/ooyeku/vigil/#v0.2.0"
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

### Running the example server

See [examples/vigilant_server](examples/vigilant_server) for an example of a basic server implementation using the `vigil` librarys `GenServer` and `WorkerGroup` features.

```bash
zig build example-server
```

### Running the Python test client

See [examples/vigilant_server/test_server.py](examples/vigilant_server/test_server.py) for an example of a basic python client implementation.

```bash
zig build test-server
./zig-out/bin/test-server
```

### Basic Usage

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

// Create a supervisor
var supervisor = vigil.Supervisor.init(allocator, .{
    .name = "my_supervisor",
    .strategy = .one_for_one,
    .shutdown_timeout_ms = 5000,
});
defer supervisor.deinit();

// Create a worker group
var worker_group = vigil.WorkerGroup.init(allocator, .{
    .name = "my_worker_group",
    .size = 5,
    .mailbox_capacity = 100,
    .priority = .high,
});
defer worker_group.deinit();

// Create a GenServer
var gen_server = vigil.GenServer.init(allocator, .{
    .name = "my_gen_server",
    .mailbox_capacity = 100,
    .priority = .high,
});
defer gen_server.deinit();

// Start the supervisor
try supervisor.start();

// Supervise the GenServer
try gen_server.supervise(supervisor, "my_gen_server");

// Start the worker group
try worker_group.start();

// Send a message to the GenServer
var msg = try vigil.Message.init(
    allocator,
    "my_message",
    "my_sender",
    "my_payload",
    .info,
    .normal,
    5000, // 5 second TTL
);
try gen_server.cast(msg);

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

// Stop the GenServer
try gen_server.stop();

// Stop the worker group
try worker_group.stop();

// Stop the supervisor
try supervisor.stop();

```

## Requirements

- Zig 0.13.0 or later
- POSIX-compliant operating system

## License

MIT - see the [LICENSE](LICENSE) file for details.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
