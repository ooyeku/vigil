/// Vigil - Process Supervision and Communication Library
///
/// A robust framework for building reliable distributed systems with
/// process supervision, message passing, and monitoring capabilities.
///
/// Main components:
/// - Process supervision with restart strategies
/// - Priority-based message passing
/// - Hierarchical supervision trees
/// - Built-in monitoring and statistics
///
/// Example:
/// ```zig
/// const vigil = @import("vigil");
///
/// // Create a supervised process group
/// var sup = try vigil.createSupervisor(allocator, .{
///     .strategy = .one_for_all,
///     .max_restarts = 3,
/// });
/// defer sup.deinit();
///
/// // Add workers with message passing
/// try vigil.addWorkerGroup(&sup, .{
///     .size = 4,
///     .mailbox_capacity = 100,
///     .priority = .high,
/// });
///
/// // Start supervision
/// try sup.start();
/// ```
const std = @import("std");
const builtin = @import("builtin");

// Core components
pub const Process = @import("process.zig").ChildProcess;
pub const Supervisor = @import("supervisor.zig").Supervisor;
pub const SupervisorTree = @import("sup_tree.zig").SupervisorTree;
pub const Message = @import("messages.zig").Message;
pub const ProcessMailbox = @import("messages.zig").ProcessMailbox;

// Configuration types
pub const SupervisorOptions = @import("supervisor.zig").SupervisorOptions;
pub const TreeConfig = @import("sup_tree.zig").TreeConfig;
pub const MailboxConfig = @import("messages.zig").MailboxConfig;

// Enums and error sets
pub const ProcessState = @import("process.zig").ProcessState;
pub const ProcessSignal = @import("process.zig").ProcessSignal;
pub const ProcessPriority = @import("process.zig").ProcessPriority;
pub const MessagePriority = @import("messages.zig").MessagePriority;
pub const Signal = @import("messages.zig").Signal;

/// Helper to convert between priority types
fn convertPriority(msg_priority: MessagePriority) ProcessPriority {
    return switch (msg_priority) {
        .critical => .critical,
        .high => .high,
        .normal => .normal,
        .low => .low,
        .batch => .batch,
    };
}

/// Configuration for creating a worker group
pub const WorkerGroupConfig = struct {
    /// Number of worker processes to create
    size: usize,
    /// Mailbox capacity for each worker
    mailbox_capacity: usize = 100,
    /// Message priority level for the group
    priority: MessagePriority = .normal,
    /// Whether to enable monitoring
    enable_monitoring: bool = true,
    /// Maximum memory usage per worker
    max_memory_mb: usize = 100,
    /// Health check interval in milliseconds
    health_check_interval_ms: u32 = 1000,
};

/// Create a new supervisor with common defaults and error handling
pub fn createSupervisor(allocator: std.mem.Allocator, options: SupervisorOptions) !*Supervisor {
    const sup = try allocator.create(Supervisor);
    errdefer allocator.destroy(sup);

    sup.* = Supervisor.init(allocator, options);
    return sup;
}

/// Create a supervision tree with error handling and default configuration
pub fn createSupervisionTree(
    allocator: std.mem.Allocator,
    root_name: []const u8,
    options: SupervisorOptions,
) !*SupervisorTree {
    const root_sup = Supervisor.init(allocator, options);
    const tree = try allocator.create(SupervisorTree);
    errdefer allocator.destroy(tree);

    tree.* = try SupervisorTree.init(allocator, root_sup, root_name, .{});
    return tree;
}

/// Add a group of worker processes to a supervisor with message passing capabilities
pub fn addWorkerGroup(
    supervisor: *Supervisor,
    config: WorkerGroupConfig,
) !void {
    const allocator = supervisor.allocator;

    // Create and add workers
    var i: usize = 0;
    while (i < config.size) : (i += 1) {
        const worker_name = try std.fmt.allocPrint(
            allocator,
            "worker_{d}",
            .{i},
        );
        defer allocator.free(worker_name);

        try supervisor.addChild(.{
            .id = worker_name,
            .start_fn = genericWorker,
            .restart_type = .permanent,
            .shutdown_timeout_ms = 5000,
            .priority = convertPriority(config.priority),
            .max_memory_bytes = config.max_memory_mb * 1024 * 1024,
            .health_check_interval_ms = config.health_check_interval_ms,
        });
    }
}

/// Create a new process mailbox with common defaults
pub fn createMailbox(
    allocator: std.mem.Allocator,
    capacity: usize,
    priority: MessagePriority,
) !*ProcessMailbox {
    const mailbox = try allocator.create(ProcessMailbox);
    errdefer allocator.destroy(mailbox);

    mailbox.* = ProcessMailbox.init(allocator, .{
        .capacity = capacity,
        .priority_queues = true,
        .enable_deadletter = true,
        .default_ttl_ms = switch (priority) {
            .critical => 1000,
            .high => 5000,
            .normal => 30_000,
            .low => 60_000,
            .batch => 300_000,
        },
    });

    return mailbox;
}

/// Send a message to multiple recipients (broadcast)
pub fn broadcast(
    recipients: []const *ProcessMailbox,
    msg: Message,
    allocator: std.mem.Allocator,
) !void {
    for (recipients) |mailbox| {
        // Create a new message for each recipient except the last one
        if (mailbox != recipients[recipients.len - 1]) {
            const msg_copy = try Message.init(
                allocator,
                try std.fmt.allocPrint(allocator, "{s}_copy", .{msg.id}),
                msg.metadata.reply_to orelse "",
                msg.payload,
                msg.signal,
                msg.priority,
                msg.metadata.ttl_ms,
            );
            try mailbox.send(msg_copy);
        } else {
            // Send original message to last recipient
            try mailbox.send(msg);
        }
    }
}

/// Helper to create a response message with common defaults
pub fn createResponse(
    original: *const Message,
    payload: ?[]const u8,
    signal: Signal,
    allocator: std.mem.Allocator,
) !Message {
    return try Message.init(
        allocator,
        try std.fmt.allocPrint(allocator, "resp_{s}", .{original.id}),
        original.metadata.reply_to orelse return error.NoReplyTo,
        payload,
        signal,
        original.priority,
        original.metadata.ttl_ms,
    );
}

/// Default worker function that can be used as a starting point
fn genericWorker() void {
    while (true) {
        std.time.sleep(100 * std.time.ns_per_ms);
    }
}

/// Get library version information
pub fn getVersion() struct { major: u32, minor: u32, patch: u32 } {
    return .{
        .major = 0,
        .minor = 1,
        .patch = 0,
    };
}

test {
    // Run all tests
    std.testing.refAllDecls(@This());
}
