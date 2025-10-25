//! Vigil 0.2.x Compatibility Shim for 0.3.x
//! This module provides backward compatibility for code written for Vigil 0.2.x.
//!
//! DEPRECATED: This API is deprecated and will be removed in Vigil 0.5.0.
//! Please migrate to the new high-level API from @import("vigil").
//! See the migration guide in docs/MIGRATION_0_2_TO_0_3.md

const std = @import("std");
const legacy = @import("legacy.zig");

// Re-export all legacy types and functions
pub const ProcessMod = legacy.ProcessMod;
pub const MessageMod = legacy.MessageMod;
pub const SupervisorMod = legacy.SupervisorMod;
pub const SupervisorTreeMod = legacy.SupervisorTreeMod;
pub const WorkerMod = legacy.WorkerMod;
pub const GenServerMod = legacy.GenServerMod;
pub const ConfigMod = legacy.ConfigMod;

pub const ProcessStats = legacy.ProcessStats;
pub const ProcessResult = legacy.ProcessResult;
pub const ChildSpec = legacy.ChildSpec;
pub const SupervisorStats = legacy.SupervisorStats;
pub const Supervisor = legacy.Supervisor;
pub const SupervisorTree = legacy.SupervisorTree;
pub const TreeStats = legacy.TreeStats;
pub const GenServer = legacy.GenServer;
pub const Message = legacy.Message;
pub const ProcessMailbox = legacy.ProcessMailbox;
pub const MessageMetadata = legacy.MessageMetadata;

pub const SupervisorOptions = legacy.SupervisorOptions;
pub const TreeConfig = legacy.TreeConfig;
pub const MailboxConfig = legacy.MailboxConfig;

pub const ProcessError = legacy.ProcessError;
pub const ProcessState = legacy.ProcessState;
pub const ProcessSignal = legacy.ProcessSignal;
pub const ProcessPriority = legacy.ProcessPriority;
pub const SupervisorError = legacy.SupervisorError;
pub const SupervisorState = legacy.SupervisorState;
pub const SupervisorTreeError = legacy.SupervisorTreeError;
pub const RestartStrategy = legacy.RestartStrategy;
pub const MessagePriority = legacy.MessagePriority;
pub const Signal = legacy.Signal;
pub const MessageError = legacy.MessageError;

/// Configuration for creating a worker group
pub const DefaultWorkerGroupConfig = struct {
    size: usize,
    mailbox_capacity: usize = 100,
    priority: MessagePriority = .normal,
    enable_monitoring: bool = true,
    max_memory_mb: usize = 100,
    health_check_interval_ms: u32 = 1000,
    worker_names: []const []const u8,
};

pub const DefaultMailboxConfig = struct {
    capacity: usize = 100,
    priority: MessagePriority = .normal,
    default_ttl_ms: u32 = 30_000,
};

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
    config: DefaultWorkerGroupConfig,
) !void {
    var i: usize = 0;
    while (i < config.size) : (i += 1) {
        try supervisor.addChild(.{
            .id = config.worker_names[i],
            .start_fn = genericWorker,
            .restart_type = .permanent,
            .shutdown_timeout_ms = 5000,
            .priority = convertPriority(config.priority),
            .max_memory_bytes = config.max_memory_mb * 1024 * 1024,
            .health_check_interval_ms = config.health_check_interval_ms,
        });
    }
}

/// This is a wrapper around the ProcessMailbox.init function
/// that sets up a mailbox with common defaults.
pub fn createMailbox(
    allocator: std.mem.Allocator,
    config: DefaultMailboxConfig,
) !*ProcessMailbox {
    const mailbox = try allocator.create(ProcessMailbox);
    errdefer allocator.destroy(mailbox);

    mailbox.* = ProcessMailbox.init(allocator, .{
        .capacity = config.capacity,
        .priority_queues = true,
        .enable_deadletter = true,
        .default_ttl_ms = config.default_ttl_ms,
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
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }
}
