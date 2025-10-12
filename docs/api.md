# Vigil API Reference Guide

Vigil is a process supervision and inter-process communication library for Zig, inspired by Erlang/OTP. It provides robust process management, message passing, and monitoring capabilities for building reliable distributed systems and concurrent applications.

## Table of Contents

- [Quick Start](#quick-start)
- [Core Concepts](#core-concepts)
- [Message Passing](#message-passing)
- [Process Management](#process-management)
- [Supervision](#supervision)
- [GenServer Pattern](#genserver-pattern)
- [Worker Groups](#worker-groups)
- [Supervisor Trees](#supervisor-trees)
- [Configuration](#configuration)
- [Error Handling](#error-handling)
- [Best Practices](#best-practices)
- [API Reference](#api-reference)

## Quick Start

```zig
const std = @import("std");
const vigil = @import("vigil");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a supervisor
    const supervisor = try vigil.createSupervisor(allocator, .{
        .strategy = .one_for_one,
        .max_restarts = 3,
        .max_seconds = 5,
    });
    defer {
        supervisor.deinit();
        allocator.destroy(supervisor);
    }

    // Create a mailbox for message passing
    var mailbox = try vigil.createMailbox(allocator, .{
        .capacity = 100,
        .priority = .normal,
        .default_ttl_ms = 5000,
    });
    defer {
        mailbox.deinit();
        allocator.destroy(mailbox);
    }

    // Send a message
    const msg = try vigil.Message.init(
        allocator,
        "hello",
        "sender",
        "Hello, World!",
        .info,
        .normal,
        5000,
    );
    try mailbox.send(msg);

    // Receive messages
    while (mailbox.receive()) |received_msg| {
        var msg = received_msg;
        defer msg.deinit();
        std.debug.print("Received: {s}\n", .{msg.payload.?});
        break; // Only receive one message for this example
    } else |err| switch (err) {
        error.EmptyMailbox => {},
        else => return err,
    }
}
```

## Core Concepts

### Processes

Vigil processes are lightweight, supervised execution units that can run concurrently. Each process has:

- **Lifecycle states**: `initial`, `running`, `stopping`, `stopped`, `failed`, `suspended`
- **Health monitoring**: Configurable health checks with automatic restart
- **Resource limits**: Memory and CPU usage monitoring
- **Signal handling**: Control signals for suspend/resume/terminate

### Supervisors

Supervisors manage process lifecycles with restart strategies:

- **`one_for_one`**: Restart only the failed process
- **`one_for_all`**: Restart all processes when any fails
- **`rest_for_one`**: Restart the failed process and all started after it

### Message Passing

Processes communicate via priority-based message queues:

- **Priority levels**: `critical`, `high`, `normal`, `low`, `batch`
- **TTL support**: Messages expire automatically
- **Correlation IDs**: Track request-response patterns
- **Signals**: Typed communication for specific actions

### GenServers

GenServers implement the actor pattern with state management:

- **State isolation**: Each GenServer manages its own state
- **Message handling**: Typed message processing
- **Supervision**: Automatic restart and monitoring
- **Call/Cast**: Synchronous and asynchronous communication

## Message Passing

### Creating Messages

```zig
// Basic message
const msg = try vigil.Message.init(
    allocator,
    "msg_id",
    "sender_id",
    "Hello, World!",
    .info,
    .normal,
    5000, // 5 second TTL
);

// Message with signal
const signal_msg = try vigil.Message.init(
    allocator,
    "restart_req",
    "monitor",
    null, // no payload
    .restart,
    .critical,
    null, // no TTL
);
```

### Message Metadata

```zig
var msg = try vigil.Message.init(allocator, "id", "sender", "payload", .info, .normal, null);

// Set correlation ID for tracking
try msg.setCorrelationId("correlation_123");

// Set reply destination
try msg.setReplyTo("response_mailbox");

// Check expiration
if (msg.isExpired()) {
    // Handle expired message
}
```

### Mailboxes

```zig
// Create a mailbox
var mailbox = try vigil.createMailbox(allocator, .{
    .capacity = 1000,
    .priority = .normal,
    .default_ttl_ms = 30000,
});
defer {
    mailbox.deinit();
    allocator.destroy(mailbox);
}

// Send messages
try mailbox.send(msg);

// Receive with priority handling
while (mailbox.receive()) |received_const| {
    var received = received_const;
    defer received.deinit();
    // Process message based on priority
    switch (received.priority) {
        .critical => {}, // handleCritical(received)
        .high => {}, // handleHigh(received)
        .normal => {}, // handleNormal(received)
        .low => {}, // handleLow(received)
        .batch => {}, // handleBatch(received)
    }
} else |err| switch (err) {
    error.EmptyMailbox => {},
    else => return err,
}
```

### Broadcasting

```zig
// Broadcast to multiple mailboxes
const mailboxes = [_]*vigil.ProcessMailbox{ mailbox1, mailbox2, mailbox3 };
try vigil.broadcast(&mailboxes, msg, allocator);
```

## Process Management

### Child Process Specification

```zig
const process_spec = vigil.ChildSpec{
    .id = "worker_1",
    .start_fn = workerFunction,
    .restart_type = .permanent,
    .shutdown_timeout_ms = 5000,
    .priority = .normal,
    .max_memory_bytes = 100 * 1024 * 1024, // 100MB
    .health_check_fn = healthCheck,
    .health_check_interval_ms = 1000,
};
```

### Process Lifecycle

```zig
var process = vigil.ChildProcess.init(allocator, process_spec);
defer _ = process.stop() catch {};

// Start the process
try process.start();

// Check status
if (process.isAlive()) {
    std.debug.print("Process is running\n", .{});
}

// Get statistics
const stats = process.getStats();
std.debug.print("Restarts: {d}, Runtime: {d}ms\n", .{
    stats.restart_count,
    stats.total_runtime_ms,
});

// Send signals
try process.sendSignal(.suspend);
try process.sendSignal(.resume);
try process.sendSignal(.terminate);

// Graceful shutdown
try process.stop();
```

### Health Monitoring

```zig
// Define health check function
fn healthCheck() bool {
    // Check database connectivity, memory usage, etc.
    return true; // return checkDatabaseConnection() and checkMemoryUsage();
}

fn workerFn() void {
    std.Thread.sleep(100 * std.time.ns_per_ms);
}

const spec = vigil.ChildSpec{
    .id = "monitored_worker",
    .start_fn = workerFn,
    .restart_type = .permanent,
    .shutdown_timeout_ms = 5000,
    .health_check_fn = healthCheck,
    .health_check_interval_ms = 5000,
};

var process = vigil.ProcessMod.ChildProcess.init(allocator, spec);

// Check health manually
if (process.checkHealth()) {
    std.debug.print("Process is healthy\n", .{});
}
```

## Supervision

### Creating Supervisors

```zig
// Basic supervisor
const supervisor = try vigil.createSupervisor(allocator, .{
    .strategy = .one_for_one,
    .max_restarts = 3,
    .max_seconds = 5,
});

// Supervisor with custom options
const custom_supervisor = try vigil.createSupervisor(allocator, .{
    .strategy = .one_for_all,
    .max_restarts = 10,
    .max_seconds = 60,
});
defer {
    supervisor.deinit();
    custom_supervisor.deinit();
    allocator.destroy(supervisor);
    allocator.destroy(custom_supervisor);
}
```

### Adding Child Processes

```zig
fn workerFunction() void {
    std.Thread.sleep(100 * std.time.ns_per_ms);
}

// Add individual process
try supervisor.addChild(.{
    .id = "worker_1",
    .start_fn = workerFunction,
    .restart_type = .permanent,
    .shutdown_timeout_ms = 5000,
});

// Add multiple processes
for (0..5) |i| {
    const id = try std.fmt.allocPrint(allocator, "worker_{d}", .{i});
    defer allocator.free(id);
    
    try supervisor.addChild(.{
        .id = id,
        .start_fn = workerFunction,
        .restart_type = .transient,
        .shutdown_timeout_ms = 3000,
    });
}
```

### Starting Supervision

```zig
// Start the supervisor (starts all child processes)
try supervisor.start();

// Start monitoring (automatic restart on failures)
try supervisor.startMonitoring();

// Get supervisor statistics
const stats = supervisor.getStats();
std.debug.print("Active children: {d}, Total restarts: {d}\n", .{
    stats.active_children,
    stats.total_restarts,
});
```

### Shutdown Handling

```zig
// Graceful shutdown with timeout
try supervisor.shutdown(10000); // 10 second timeout
```

## GenServer Pattern

### Defining a GenServer

```zig
const State = struct {
    counter: u32 = 0,
    name: []const u8,
};

const MyGenServer = vigil.GenServer(State);

const server = try MyGenServer.init(
    allocator,
    struct {
        fn handle(self: *MyGenServer, msg: vigil.Message) anyerror!void {
            if (msg.payload) |payload| {
                if (std.mem.eql(u8, payload, "increment")) {
                    self.state.counter += 1;
                } else if (std.mem.eql(u8, payload, "get")) {
                    // Send response back
                    const response = try std.fmt.allocPrint(
                        self.allocator,
                        "Counter: {d}",
                        .{self.state.counter}
                    );
                    defer self.allocator.free(response);

                    const resp_msg = try msg.createResponse(self.allocator, response, .info);
                    try self.cast(resp_msg);
                }
            }
        }
    }.handle,
    struct {
        fn init(self: *MyGenServer) !void {
            std.debug.print("GenServer {s} initialized\n", .{self.state.name});
        }
    }.init,
    struct {
        fn terminate(self: *MyGenServer) void {
            std.debug.print("GenServer {s} terminated\n", .{self.state.name});
        }
    }.terminate,
    State{ .counter = 0, .name = "my_server" },
);
defer server.stop();
```

### GenServer Communication

```zig
// Note: GenServer.start() runs in a loop, so you typically run it in a separate thread
const thread = try std.Thread.spawn(.{}, struct {
    fn run(s: *MyGenServer) void {
        s.start() catch {};
    }
}.run, .{server});

// Give the server time to start
std.Thread.sleep(10 * std.time.ns_per_ms);

// Asynchronous message (cast)
const cast_msg = try vigil.Message.init(
    allocator,
    "increment_cmd",
    "client",
    "increment",
    .info,
    .normal,
    null,
);
try server.cast(cast_msg);

// Synchronous call with response
var call_msg = try vigil.Message.init(
    allocator,
    "get_cmd",
    "client",
    "get",
    .info,
    .normal,
    null,
);

// Make the call (this will block until response)
const response = try server.call(&call_msg, 5000); // 5 second timeout
defer response.deinit();
defer call_msg.deinit();

std.debug.print("Response: {s}\n", .{response.payload.?});

// Stop the server and wait for thread
server.server_state = .stopped;
thread.join();
```

### Supervised GenServers

```zig
// Create supervisor
const supervisor = try vigil.createSupervisor(allocator, .{
    .strategy = .one_for_one,
    .max_restarts = 3,
    .max_seconds = 5,
});

// Register GenServer with supervisor
try server.supervise(supervisor, "my_genserver");

// Start supervision
try supervisor.start();
try supervisor.startMonitoring();

// The GenServer will now be automatically restarted if it fails
```

## Worker Groups

### Creating Worker Groups

```zig
const worker_config = vigil.DefaultWorkerGroupConfig{
    .size = 10,
    .mailbox_capacity = 100,
    .priority = .normal,
    .enable_monitoring = true,
    .max_memory_mb = 50,
    .health_check_interval_ms = 5000,
    .worker_names = &[_][]const u8{ "worker_0", "worker_1", "worker_2" },
};

// Add worker group to supervisor
try vigil.addWorkerGroup(supervisor, worker_config);
```

## Supervisor Trees

### Creating Supervisor Trees

```zig
// Create root supervisor options
const root_options = vigil.SupervisorOptions{
    .strategy = .one_for_all,
    .max_restarts = 5,
    .max_seconds = 30,
};

// Create supervisor tree
var tree = try vigil.createSupervisionTree(allocator, "root", root_options);
defer {
    tree.deinit();
    allocator.destroy(tree);
}

// Add child supervisors
const worker_sup = vigil.Supervisor.init(allocator, .{
    .strategy = .one_for_one,
    .max_restarts = 3,
    .max_seconds = 10,
});

const monitor_sup = vigil.Supervisor.init(allocator, .{
    .strategy = .rest_for_one,
    .max_restarts = 2,
    .max_seconds = 15,
});

try tree.addChild(worker_sup, "workers");
try tree.addChild(monitor_sup, "monitors");
```

### Tree Operations

```zig
// Start the entire tree
try tree.start();

// Get tree statistics
const stats = tree.getStats();
std.debug.print("Supervisors: {d}, Active processes: {d}\n", .{
    stats.total_supervisors,
    stats.active_processes,
});

// Find a specific supervisor
if (tree.findSupervisor("workers")) |worker_sup| {
    const worker_stats = worker_sup.getStats();
    // ... use stats
}

// Propagate signals through the tree
try tree.propagateSignal(.healthCheck);

// Graceful shutdown
try tree.shutdown(10000); // 10 second timeout
```

## Configuration

### Using Configuration

```zig
const config = vigil.Config.production();

// Access configuration sections
std.debug.print("Background workers: {d}\n", .{config.workers.background_count});
std.debug.print("Message TTL: {d}ms\n", .{config.messaging.message_ttl_ms});
std.debug.print("Memory warning: {d}MB\n", .{config.health.memory_warning_mb});

// Create supervisor with config values
const supervisor = try vigil.createSupervisor(allocator, .{
    .strategy = .one_for_one,
    .max_restarts = config.workers.max_count,
    .max_seconds = 60,
});
```

## Error Handling

### Common Error Types

```zig
// Process errors
try process.start() catch |err| switch (err) {
    error.AlreadyRunning => std.debug.print("Process already running\n", .{}),
    error.StartFailed => std.debug.print("Failed to start process\n", .{}),
    error.ResourceLimitExceeded => std.debug.print("Resource limit exceeded\n", .{}),
    else => return err,
};

// Message errors
try mailbox.send(msg) catch |err| switch (err) {
    error.MailboxFull => std.debug.print("Mailbox is full\n", .{}),
    error.MessageExpired => std.debug.print("Message expired\n", .{}),
    error.MessageTooLarge => std.debug.print("Message too large\n", .{}),
    else => return err,
};

// Supervisor errors
try supervisor.addChild(spec) catch |err| switch (err) {
    error.TooManyRestarts => std.debug.print("Too many restarts\n", .{}),
    error.ShutdownTimeout => std.debug.print("Shutdown timed out\n", .{}),
    else => return err,
};
```

## Best Practices

### 1. Supervisor Hierarchy

```zig
// Root supervisor (one_for_all) - critical system processes
const root_sup_opts = vigil.SupervisorOptions{
    .strategy = .one_for_all,
    .max_restarts = 3,
    .max_seconds = 60,
};

// Create supervisor tree
var tree = try vigil.createSupervisionTree(allocator, "system", root_sup_opts);
defer {
    tree.deinit();
    allocator.destroy(tree);
}

// Worker supervisor (one_for_one) - independent workers
const worker_sup = vigil.Supervisor.init(allocator, .{
    .strategy = .one_for_one,
    .max_restarts = 10,
    .max_seconds = 30,
});

// Add to tree
try tree.addChild(worker_sup, "workers");
```

### 2. Message Patterns

```zig
// Request-Response pattern
const request_data = "my request data";
var request = try vigil.Message.init(
    allocator,
    "request_id",
    "client",
    request_data,
    .info,
    .normal,
    30000,
);

// Using call() which handles correlation IDs automatically
const response = try server.call(&request, 5000);
defer response.deinit();
defer request.deinit();

// Process response
if (response.payload) |payload| {
    std.debug.print("Got response: {s}\n", .{payload});
}
```

### 3. Resource Management

```zig
fn workerFunction() void {
    std.Thread.sleep(100 * std.time.ns_per_ms);
}

fn healthCheckFn() bool {
    // Check database connections, external services, etc.
    return true; // return checkDatabase() and checkExternalAPI();
}

const process_spec = vigil.ChildSpec{
    .id = "resource_worker",
    .start_fn = workerFunction,
    .restart_type = .permanent,
    .shutdown_timeout_ms = 10000,
    .max_memory_bytes = 500 * 1024 * 1024, // 500MB limit
    .health_check_fn = healthCheckFn,
    .health_check_interval_ms = 30000, // 30 second checks
};
```

### 4. Graceful Shutdown

```zig
// Set up signal handling
var sig_received = std.atomic.Value(bool).init(false);

// Signal handler
const handler = struct {
    fn handle(sig: c_int) callconv(.c) void {
        _ = sig;
        sig_received.store(true, .release);
    }
}.handle;

// Create an empty sigset_t
var empty_set: std.posix.sigset_t = undefined;
@memset(@as([*]u8, @ptrCast(&empty_set))[0..@sizeOf(std.posix.sigset_t)], 0);

// Register signal handler for SIGINT
std.posix.sigaction(std.posix.SIG.INT, &std.posix.Sigaction{
    .handler = .{ .handler = handler },
    .mask = empty_set,
    .flags = 0,
}, null);

// Main loop
while (!sig_received.load(.acquire)) {
    // Application logic
    std.Thread.sleep(100 * std.time.ns_per_ms);
}

// Graceful shutdown
std.debug.print("Initiating graceful shutdown...\n", .{});
try supervisor.shutdown(30000); // 30 second timeout
std.debug.print("Shutdown complete\n", .{});
```

---

# API Reference

## vigil

### Functions

#### `createSupervisor(allocator: Allocator, options: SupervisorOptions) !*Supervisor`

Creates a new supervisor with the given options.

**Parameters:**
- `allocator`: Memory allocator
- `options`: Supervisor configuration options

**Returns:** Pointer to initialized Supervisor

**Errors:** `OutOfMemory` if allocation fails

#### `createSupervisionTree(allocator: Allocator, root_name: []const u8, options: SupervisorOptions) !*SupervisorTree`

Creates a new supervisor tree with the given root supervisor.

**Parameters:**
- `allocator`: Memory allocator
- `root_name`: Name for the root supervisor
- `options`: Supervisor configuration options

**Returns:** Pointer to initialized SupervisorTree

**Errors:** `OutOfMemory` if allocation fails

#### `addWorkerGroup(supervisor: *Supervisor, config: DefaultWorkerGroupConfig) !void`

Adds a group of worker processes to a supervisor.

**Parameters:**
- `supervisor`: Target supervisor
- `config`: Worker group configuration

**Errors:** `OutOfMemory`, `AlreadyMonitoring`

#### `createMailbox(allocator: Allocator, config: DefaultMailboxConfig) !*ProcessMailbox`

Creates a new mailbox with default configuration.

**Parameters:**
- `allocator`: Memory allocator
- `config`: Mailbox configuration

**Returns:** Pointer to initialized ProcessMailbox

**Errors:** `OutOfMemory`

#### `broadcast(recipients: []const *ProcessMailbox, msg: Message, allocator: Allocator) !void`

Broadcasts a message to multiple recipients.

**Parameters:**
- `recipients`: Array of mailbox pointers
- `msg`: Message to broadcast
- `allocator`: Memory allocator for message copies

**Errors:** `OutOfMemory`

#### `createResponse(original: *const Message, payload: ?[]const u8, signal: Signal, allocator: Allocator) !Message`

Creates a response message to an original message.

**Parameters:**
- `original`: Original message
- `payload`: Response payload
- `signal`: Response signal type
- `allocator`: Memory allocator

**Returns:** Response message

**Errors:** `NoReplyTo`, `OutOfMemory`

#### `getVersion() struct { major: u32, minor: u32, patch: u32 }`

Returns the current version of the vigil library.

**Returns:** Version struct with major, minor, and patch numbers

## Message

### Static Functions

#### `init(allocator: Allocator, id: []const u8, sender: []const u8, payload: ?[]const u8, signal: ?Signal, priority: MessagePriority, ttl_ms: ?u32) !Message`

Creates a new message.

**Parameters:**
- `allocator`: Memory allocator
- `id`: Unique message identifier
- `sender`: Sender identifier
- `payload`: Optional message payload
- `signal`: Optional signal type
- `priority`: Message priority level
- `ttl_ms`: Optional time-to-live in milliseconds

**Returns:** Initialized Message

**Errors:** `OutOfMemory`

### Methods

#### `deinit(self: *Message) void`

Frees all memory associated with the message.

#### `isExpired(self: Message) bool`

Checks if the message has expired based on its TTL.

**Returns:** true if expired, false otherwise

#### `setCorrelationId(self: *Message, correlation_id: []const u8) !void`

Sets the correlation ID for tracking related messages.

**Parameters:**
- `correlation_id`: Correlation identifier string

**Errors:** `OutOfMemory`

#### `setReplyTo(self: *Message, reply_to: []const u8) !void`

Sets the reply destination for responses.

**Parameters:**
- `reply_to`: Reply destination identifier

**Errors:** `OutOfMemory`

#### `createResponse(self: Message, allocator: Allocator, payload: ?[]const u8, signal: ?Signal) !Message`

Creates a response message to this message.

**Parameters:**
- `allocator`: Memory allocator
- `payload`: Response payload
- `signal`: Response signal type

**Returns:** Response message

**Errors:** `NoReplyTo`, `OutOfMemory`

#### `dupe(self: *const Message) !Message`

Creates a duplicate of the message.

**Returns:** Duplicated message

**Errors:** `OutOfMemory`

## ProcessMailbox

### Static Functions

#### `init(allocator: Allocator, config: MailboxConfig) ProcessMailbox`

Creates a new mailbox with the given configuration.

**Parameters:**
- `allocator`: Memory allocator
- `config`: Mailbox configuration

**Returns:** Initialized ProcessMailbox

### Methods

#### `deinit(self: *ProcessMailbox) void`

Frees all resources associated with the mailbox.

#### `send(self: *ProcessMailbox, msg: Message) MessageError!void`

Sends a message to the mailbox.

**Parameters:**
- `msg`: Message to send (ownership transferred)

**Errors:** `MailboxFull`, `MessageExpired`, `MessageTooLarge`, `OutOfMemory`

#### `receive(self: *ProcessMailbox) MessageError!Message`

Receives the next message from the mailbox with priority handling.

**Returns:** Next message (ownership transferred to caller)

**Errors:** `EmptyMailbox`, `OutOfMemory`

#### `peek(self: *ProcessMailbox) MessageError!Message`

Peeks at the next message without removing it.

**Returns:** Next message (read-only)

**Errors:** `EmptyMailbox`, `MessageExpired`

#### `clear(self: *ProcessMailbox) void`

Clears all messages from the mailbox.

#### `getStats(self: *ProcessMailbox) MailboxStats`

Returns current mailbox statistics.

**Returns:** Mailbox statistics

#### `hasCapacity(self: *ProcessMailbox, msg_size: usize) bool`

Checks if the mailbox has capacity for a message of the given size.

**Parameters:**
- `msg_size`: Size of the message in bytes

**Returns:** true if capacity available, false otherwise

## ChildProcess

### Static Functions

#### `init(allocator: Allocator, spec: ChildSpec) ChildProcess`

Creates a new child process with the given specification.

**Parameters:**
- `allocator`: Memory allocator
- `spec`: Process specification

**Returns:** Initialized ChildProcess

### Methods

#### `start(self: *ChildProcess) ProcessError!void`

Starts the process execution.

**Errors:** `AlreadyRunning`, `StartFailed`, `OutOfMemory`

#### `stop(self: *ChildProcess) ProcessError!void`

Gracefully stops the process.

**Errors:** `ShutdownTimeout`

#### `isAlive(self: *ChildProcess) bool`

Checks if the process is currently running.

**Returns:** true if running, false otherwise

#### `getState(self: *ChildProcess) ProcessState`

Returns the current process state.

**Returns:** Current ProcessState

#### `sendSignal(self: *ChildProcess, signal: ProcessSignal) ProcessError!void`

Sends a control signal to the process.

**Parameters:**
- `signal`: Signal to send

#### `checkHealth(self: *ChildProcess) bool`

Checks the health status of the process.

**Returns:** true if healthy, false otherwise

#### `getStats(self: *ChildProcess) ProcessStats`

Returns current process statistics.

**Returns:** Process statistics

#### `getResult(self: *ChildProcess) ?ProcessResult`

Returns the process termination result if available.

**Returns:** ProcessResult if terminated, null otherwise

## Supervisor

### Static Functions

#### `init(allocator: Allocator, options: SupervisorOptions) Supervisor`

Creates a new supervisor with the given options.

**Parameters:**
- `allocator`: Memory allocator
- `options`: Supervisor configuration

**Returns:** Initialized Supervisor

### Methods

#### `deinit(self: *Supervisor) void`

Cleans up supervisor resources and stops all child processes.

#### `addChild(self: *Supervisor, spec: ChildSpec) !void`

Adds a child process to be supervised.

**Parameters:**
- `spec`: Child process specification

**Errors:** `AlreadyMonitoring`, `OutOfMemory`

#### `start(self: *Supervisor) !void`

Starts all child processes.

**Errors:** Process start errors

#### `startMonitoring(self: *Supervisor) !void`

Starts monitoring child processes for failures.

**Errors:** `AlreadyMonitoring`

#### `stopMonitoring(self: *Supervisor) void`

Stops monitoring child processes.

#### `getStats(self: *Supervisor) SupervisorStats`

Returns current supervisor statistics.

**Returns:** Supervisor statistics

#### `shutdown(self: *Supervisor, timeout_ms: i64) SupervisorError!void`

Gracefully shuts down the supervisor and all child processes.

**Parameters:**
- `timeout_ms`: Timeout in milliseconds

**Errors:** `ShutdownTimeout`

#### `findChild(self: *Supervisor, id: []const u8) ?*ChildProcess`

Finds a child process by ID.

**Parameters:**
- `id`: Child process ID

**Returns:** Pointer to child process if found, null otherwise

## GenServer(StateType)

### Static Functions

#### `init(allocator: Allocator, handler: HandlerFn, init_fn: InitFn, terminate_fn: TerminateFn, state: StateType) !*GenServer`

Creates a new GenServer instance.

**Parameters:**
- `allocator`: Memory allocator
- `handler`: Message handler function
- `init_fn`: Initialization function
- `terminate_fn`: Termination function
- `state`: Initial state

**Returns:** Pointer to initialized GenServer

**Errors:** `OutOfMemory`

### Methods

#### `start(self: *GenServer) !void`

Starts the GenServer process.

**Errors:** `AlreadyRunning`

#### `cast(self: *GenServer, msg: Message) !void`

Sends an asynchronous message to the GenServer.

**Parameters:**
- `msg`: Message to send (ownership transferred)

**Errors:** Mailbox errors

#### `call(self: *GenServer, msg: *Message, timeout_ms: ?u32) !Message`

Sends a synchronous call to the GenServer and waits for response.

**Parameters:**
- `msg`: Call message (modified in place)
- `timeout_ms`: Optional timeout in milliseconds

**Returns:** Response message

**Errors:** `Timeout`, mailbox errors

#### `stop(self: *GenServer) void`

Stops the GenServer and frees all resources.

#### `supervise(self: *GenServer, supervisor: *Supervisor, id: []const u8) !void`

Registers the GenServer with a supervisor.

**Parameters:**
- `supervisor`: Target supervisor
- `id`: Process ID for supervision

**Errors:** Supervisor errors

## SupervisorTree

### Static Functions

#### `init(allocator: Allocator, main_supervisor: Supervisor, main_name: []const u8, config: TreeConfig) !SupervisorTree`

Creates a new supervisor tree.

**Parameters:**
- `allocator`: Memory allocator
- `main_supervisor`: Root supervisor
- `main_name`: Name for root supervisor
- `config`: Tree configuration

**Returns:** Initialized SupervisorTree

**Errors:** `OutOfMemory`

### Methods

#### `deinit(self: *SupervisorTree) void`

Cleans up all resources in the tree.

#### `addChild(self: *SupervisorTree, supervisor: Supervisor, name: []const u8) !void`

Adds a child supervisor to the tree.

**Parameters:**
- `supervisor`: Child supervisor
- `name`: Unique name for the supervisor

**Errors:** `MaxDepthExceeded`, `DuplicateSupervisor`, `OutOfMemory`

#### `start(self: *SupervisorTree) !void`

Starts all supervisors in the tree.

**Errors:** Supervisor start errors

#### `shutdown(self: *SupervisorTree, timeout_ms: u32) !void`

Shuts down the entire tree.

**Parameters:**
- `timeout_ms`: Timeout in milliseconds

**Errors:** `ShutdownTimeout`

#### `findSupervisor(self: *SupervisorTree, name: []const u8) ?*Supervisor`

Finds a supervisor by name.

**Parameters:**
- `name`: Supervisor name

**Returns:** Pointer to supervisor if found, null otherwise

#### `startMonitoring(self: *SupervisorTree) !void`

Starts monitoring for all supervisors in the tree.

#### `getStats(self: *SupervisorTree) TreeStats`

Returns tree-wide statistics.

**Returns:** Tree statistics

#### `propagateSignal(self: *SupervisorTree, signal: ProcessSignal) !void`

Propagates a signal to all processes in the tree.

**Parameters:**
- `signal`: Signal to propagate

---

## Types

### Enums

#### `ProcessState`
- `initial`: Process not yet started
- `running`: Process is actively running
- `stopping`: Process is in the process of stopping
- `stopped`: Process has stopped
- `failed`: Process has failed
- `suspended`: Process is temporarily suspended

#### `ProcessSignal`
- `suspend`: Pause process execution
- `resume`: Resume suspended process
- `terminate`: Terminate process
- `custom`: User-defined signal

#### `ProcessPriority`
- `critical`: Highest priority, immediate handling
- `high`: High priority, urgent tasks
- `normal`: Default priority
- `low`: Low priority, background tasks
- `batch`: Lowest priority, bulk operations

#### `RestartStrategy`
- `one_for_one`: Restart only the failed process
- `one_for_all`: Restart all processes when any fails
- `rest_for_one`: Restart failed process and all started after it

#### `MessagePriority`
- `critical`: Critical messages, immediate handling
- `high`: High priority messages
- `normal`: Normal priority messages
- `low`: Low priority messages
- `batch`: Batch processing messages

#### `Signal`
- `restart`: Request process restart
- `shutdown`: Request graceful shutdown
- `terminate`: Request immediate termination
- `exit`: Normal process exit
- `suspend`: Pause execution
- `resume`: Resume execution
- `healthCheck`: Health status request
- `memoryWarning`: Memory usage warning
- `cpuWarning`: CPU usage warning
- `deadlockDetected`: Deadlock condition
- `messageErr`: Message processing error
- `info`: Informational message
- `warning`: Warning message
- `debug`: Debug message
- `log`: Log entry
- `alert`: Alert message
- `metric`: Performance metric
- `event`: System event
- `heartbeat`: Process heartbeat
- `custom`: Custom signal

### Structs

#### `ChildSpec`
Process configuration specification.

**Fields:**
- `id: []const u8` - Unique process identifier
- `start_fn: *const fn () void` - Function to execute
- `restart_type: enum` - Restart behavior (`permanent`, `transient`, `temporary`)
- `shutdown_timeout_ms: u32` - Shutdown timeout in milliseconds
- `priority: ProcessPriority` - Process priority level
- `max_memory_bytes: ?usize` - Optional memory limit
- `health_check_fn: ?*const fn () bool` - Optional health check function
- `health_check_interval_ms: u32` - Health check interval
- `context: ?*anyopaque` - Optional context data

#### `SupervisorOptions`
Supervisor configuration options.

**Fields:**
- `strategy: RestartStrategy` - Restart strategy to use
- `max_restarts: u32` - Maximum restart count within time window
- `max_seconds: u32` - Time window for restart counting

#### `MailboxConfig`
Mailbox configuration options.

**Fields:**
- `capacity: usize` - Maximum number of messages
- `max_message_size: usize` - Maximum message size in bytes
- `default_ttl_ms: ?u32` - Default message TTL
- `priority_queues: bool` - Enable priority-based queuing
- `enable_deadletter: bool` - Enable dead letter queue

#### `TreeConfig`
Supervisor tree configuration.

**Fields:**
- `max_depth: u8` - Maximum tree depth
- `enable_monitoring: bool` - Enable automatic monitoring
- `shutdown_timeout_ms: u32` - Default shutdown timeout
- `propagate_signals: bool` - Enable signal propagation

#### `ProcessStats`
Process execution statistics.

**Fields:**
- `start_time: i64` - Process start timestamp
- `last_active_time: i64` - Last activity timestamp
- `restart_count: u32` - Number of restarts
- `total_runtime_ms: i64` - Total runtime in milliseconds
- `peak_memory_bytes: usize` - Peak memory usage
- `health_check_failures: u32` - Number of health check failures

#### `SupervisorStats`
Supervisor operation statistics.

**Fields:**
- `total_restarts: u32` - Total process restarts
- `uptime_ms: i64` - Supervisor uptime
- `last_failure_time: i64` - Last failure timestamp
- `active_children: u32` - Number of active children

#### `TreeStats`
Supervisor tree statistics.

**Fields:**
- `total_supervisors: usize` - Total supervisors in tree
- `total_processes: usize` - Total processes across tree
- `active_processes: usize` - Currently active processes
- `failed_processes: usize` - Number of failed processes
- `total_restarts: usize` - Total restarts across tree
- `max_depth_reached: u8` - Maximum tree depth reached
- `total_memory_bytes: usize` - Total memory usage

---

## Examples

### Complete Application

```zig
const std = @import("std");
const vigil = @import("vigil");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create root supervisor
    const root_sup = try vigil.createSupervisor(allocator, .{
        .strategy = .one_for_all,
        .max_restarts = 3,
        .max_seconds = 30,
    });
    defer {
        root_sup.deinit();
        allocator.destroy(root_sup);
    }

    // Create GenServer for request handling
    const RequestHandler = vigil.GenServer(struct {
        request_count: u32 = 0,
    });

    const handler = try RequestHandler.init(
        allocator,
        struct {
            fn handle(self: *RequestHandler, msg: vigil.Message) anyerror!void {
                if (msg.payload) |payload| {
                    if (std.mem.eql(u8, payload, "ping")) {
                        self.state.request_count += 1;
                        const response = try std.fmt.allocPrint(
                            self.allocator,
                            "pong {d}",
                            .{self.state.request_count}
                        );
                        defer self.allocator.free(response);

                        const resp_msg = try msg.createResponse(self.allocator, response, .info);
                        try self.cast(resp_msg);
                    }
                }
            }
        }.handle,
        struct {
            fn init(self: *RequestHandler) !void {
                std.debug.print("Request handler initialized\n", .{});
            }
        }.init,
        struct {
            fn terminate(self: *RequestHandler) void {
                std.debug.print("Request handler terminated\n", .{});
            }
        }.terminate,
        .{},
    );
    defer handler.stop();

    // Supervise the handler
    try handler.supervise(root_sup, "request_handler");

    // Start supervision
    try root_sup.start();
    try root_sup.startMonitoring();

    // Create mailbox for communication
    var mailbox = try vigil.createMailbox(allocator, .{
        .capacity = 100,
        .priority = .normal,
    });
    defer {
        mailbox.deinit();
        allocator.destroy(mailbox);
    }

    // Send some test messages
    for (0..5) |i| {
        const id = try std.fmt.allocPrint(allocator, "test_{d}", .{i});
        const msg = try vigil.Message.init(
            allocator,
            id,
            "main",
            "ping",
            .info,
            .normal,
            5000,
        );
        try mailbox.send(msg);
    }

    // Process messages
    var received_count: usize = 0;
    while (received_count < 5) {
        if (mailbox.receive()) |msg_const| {
            var msg = msg_const;
            defer msg.deinit();
            if (msg.payload) |payload| {
                std.debug.print("Received: {s}\n", .{payload});
            }
            received_count += 1;
        } else |err| switch (err) {
            error.EmptyMailbox => std.Thread.sleep(10 * std.time.ns_per_ms),
            else => return err,
        }
    }

    // Graceful shutdown
    try root_sup.shutdown(10000);
    std.debug.print("Application shutdown complete\n", .{});
}
```

This comprehensive API reference guide covers all major aspects of the vigil library, from basic concepts to advanced usage patterns. For the latest updates and additional examples, check the vigil repository documentation.
