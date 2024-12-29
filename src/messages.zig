const std = @import("std");
const Mutex = std.Thread.Mutex;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Time = std.time.Time;

/// Extended error set for message handling operations.
/// These errors cover the full range of potential failures in message processing,
/// from basic mailbox operations to delivery and validation issues.
pub const MessageError = error{
    EmptyMailbox, // No messages available for receiving
    MailboxFull, // Mailbox has reached its capacity
    InvalidMessage, // Message format or content is invalid
    InvalidSender, // Sender identification is missing or invalid
    MessageExpired, // Message TTL has elapsed
    DeliveryTimeout, // Message could not be delivered within timeout
    ReceiverUnavailable, // Target receiver is not accepting messages
    InvalidPriority, // Message priority level is invalid
    InvalidSignal, // Signal type is not recognized
    MessageTooLarge, // Message exceeds size limits
    DuplicateMessage, // Message with same ID already exists
    OutOfMemory, // Memory allocation failed
};

/// Message priority levels for handling urgent communications.
/// Priority determines message processing order and resource allocation.
/// Use this to ensure critical messages are handled before less important ones.
///
/// Example:
/// ```zig
/// const msg = try Message.init(
///     allocator,
///     "status_update",
///     "worker_1",
///     "CPU usage high",
///     .warning,
///     .high, // High priority for immediate attention
///     5000,  // 5 second TTL
/// );
/// ```
pub const MessagePriority = enum {
    critical, // Immediate handling required (e.g., shutdown signals, system failures)
    high, // Urgent but not critical (e.g., health alerts, resource warnings)
    normal, // Standard operations (e.g., status updates, routine tasks)
    low, // Background tasks (e.g., cleanup, optimization)
    batch, // Bulk operations (e.g., data processing, logging)

    /// Convert priority to integer for comparison and sorting
    /// Returns: u8 value from 0 (critical) to 4 (batch)
    pub fn toInt(self: MessagePriority) u8 {
        return switch (self) {
            .critical => 0,
            .high => 1,
            .normal => 2,
            .low => 3,
            .batch => 4,
        };
    }
};

/// Extended signal types for process communication.
/// Signals represent specific actions or states that processes can communicate.
/// Use these to trigger specific behaviors or responses in receiving processes.
///
/// Example:
/// ```zig
/// // Send a health check signal
/// const msg = try Message.init(
///     allocator,
///     "health_check",
///     "monitor",
///     null,
///     .healthCheck,
///     .high,
///     1000,
/// );
/// ```
pub const Signal = enum {
    // Process lifecycle signals
    restart, // Request process restart
    shutdown, // Request graceful shutdown
    terminate, // Request immediate termination
    exit, // Normal process exit
    @"suspend", // Pause process execution
    @"resume", // Resume process execution

    // Health and monitoring signals
    healthCheck, // Request health status
    memoryWarning, // Memory usage alert
    cpuWarning, // CPU usage alert
    deadlockDetected, // Deadlock condition detected

    // Operational signals
    messageErr, // Message processing error
    info, // Informational message
    warning, // Warning condition
    debug, // Debug information
    log, // Log entry
    alert, // Important alert
    metric, // Performance metric
    event, // System event
    heartbeat, // Process heartbeat

    // Custom signals
    custom, // User-defined signals (use payload for details)
};

/// Message metadata for tracking and debugging.
/// Contains information about message lifecycle, routing, and monitoring.
pub const MessageMetadata = struct {
    timestamp: i64, // Creation timestamp (Unix epoch)
    ttl_ms: ?u32, // Time-to-live in milliseconds (null = no expiry)
    correlation_id: ?[]const u8, // For tracking related messages
    reply_to: ?[]const u8, // Destination for responses
    attempt_count: u32, // Number of delivery attempts made
    trace_id: ?[]const u8, // For distributed tracing
    size_bytes: usize, // Total message size in bytes
};

/// Enhanced message structure with metadata and delivery controls.
/// Messages are the primary means of communication between processes.
/// They support priorities, signals, TTL, and response tracking.
///
/// Example:
/// ```zig
/// // Create a new message
/// var msg = try Message.init(
///     allocator,
///     "msg_001",
///     "sender_proc",
///     "Hello!",
///     .info,
///     .normal,
///     10000, // 10 second TTL
/// );
/// defer msg.deinit();
///
/// // Create a response
/// if (msg.metadata.reply_to) |_| {
///     var response = try msg.createResponse(
///         allocator,
///         "Got it!",
///         .info,
///     );
///     defer response.deinit();
/// }
/// ```
pub const Message = struct {
    id: []const u8, // Unique message identifier
    payload: ?[]const u8, // Optional message content
    signal: ?Signal, // Optional signal type
    sender: []const u8, // Sender identifier
    priority: MessagePriority, // Message priority level
    metadata: MessageMetadata, // Message metadata
    allocator: Allocator, // Memory allocator

    /// Initialize a new message with the given parameters.
    /// Caller owns the returned message and must call deinit().
    /// Returns: Message or error
    pub fn init(
        allocator: Allocator,
        id: []const u8,
        sender: []const u8,
        payload: ?[]const u8,
        signal: ?Signal,
        priority: MessagePriority,
        ttl_ms: ?u32,
    ) !Message {
        const id_copy = try allocator.dupe(u8, id);
        errdefer allocator.free(id_copy);

        const sender_copy = try allocator.dupe(u8, sender);
        errdefer allocator.free(sender_copy);

        const payload_copy = if (payload) |p| try allocator.dupe(u8, p) else null;
        errdefer if (payload_copy) |p| allocator.free(p);

        // Calculate message size
        var total_size: usize = id_copy.len + sender_copy.len;
        if (payload_copy) |p| total_size += p.len;

        return Message{
            .id = id_copy,
            .sender = sender_copy,
            .payload = payload_copy,
            .signal = signal,
            .priority = priority,
            .metadata = .{
                .timestamp = std.time.timestamp(),
                .ttl_ms = ttl_ms,
                .correlation_id = null,
                .reply_to = null,
                .attempt_count = 0,
                .trace_id = null,
                .size_bytes = total_size,
            },
            .allocator = allocator,
        };
    }

    /// Free all allocated memory associated with the message.
    /// Must be called when message is no longer needed.
    pub fn deinit(self: *Message) void {
        self.allocator.free(self.id);
        self.allocator.free(self.sender);
        if (self.payload) |payload| {
            self.allocator.free(payload);
        }
        if (self.metadata.correlation_id) |cid| {
            self.allocator.free(cid);
        }
        if (self.metadata.reply_to) |rt| {
            self.allocator.free(rt);
        }
        if (self.metadata.trace_id) |tid| {
            self.allocator.free(tid);
        }
    }

    /// Check if the message has expired based on its TTL.
    /// Returns: true if message has expired, false otherwise
    pub fn isExpired(self: Message) bool {
        if (self.metadata.ttl_ms) |ttl| {
            const current_time = std.time.timestamp();
            const elapsed_ms = @as(u64, @intCast(current_time - self.metadata.timestamp)) * 1000;
            return elapsed_ms >= ttl;
        }
        return false;
    }

    /// Set correlation ID for tracking related messages.
    /// Useful for request-response patterns and message chains.
    pub fn setCorrelationId(self: *Message, correlation_id: []const u8) !void {
        if (self.metadata.correlation_id) |old_id| {
            self.allocator.free(old_id);
        }
        self.metadata.correlation_id = try self.allocator.dupe(u8, correlation_id);
    }

    /// Set reply-to address for responses.
    /// Required for createResponse() to work.
    pub fn setReplyTo(self: *Message, reply_to: []const u8) !void {
        if (self.metadata.reply_to) |old_rt| {
            self.allocator.free(old_rt);
        }
        self.metadata.reply_to = try self.allocator.dupe(u8, reply_to);
    }

    /// Create a response message to this message.
    /// Requires reply_to to be set on the original message.
    /// Returns: new Message or error
    pub fn createResponse(self: Message, allocator: Allocator, payload: ?[]const u8, signal: ?Signal) !Message {
        if (self.metadata.reply_to == null) return MessageError.InvalidMessage;

        // Create a new message first
        var response = try Message.init(
            allocator,
            self.id, // Temporary ID, will be replaced
            self.metadata.reply_to.?,
            payload,
            signal,
            self.priority,
            self.metadata.ttl_ms,
        );
        errdefer response.deinit();

        // Now create and set the response ID
        const resp_id = try std.fmt.allocPrint(allocator, "resp_{s}", .{self.id});
        allocator.free(response.id); // Free the temporary ID
        response.id = resp_id; // Transfer ownership of resp_id

        // Set correlation ID if present
        if (self.metadata.correlation_id) |cid| {
            try response.setCorrelationId(cid);
        }

        return response;
    }
};

/// Configuration options for mailbox behavior.
/// Use this to customize mailbox capacity, message size limits,
/// TTL defaults, and optional features.
pub const MailboxConfig = struct {
    capacity: usize, // Maximum number of messages
    max_message_size: usize = 1024 * 1024, // Maximum message size (1MB default)
    default_ttl_ms: ?u32 = 60_000, // Default message TTL (1 minute)
    priority_queues: bool = true, // Enable priority-based queuing
    enable_deadletter: bool = true, // Enable dead letter queue
};

/// Enhanced process mailbox with priority queues and monitoring.
/// Provides thread-safe message handling with optional priority queues
/// and dead letter support for undeliverable messages.
///
/// Example:
/// ```zig
/// // Initialize mailbox
/// var mailbox = ProcessMailbox.init(allocator, .{
///     .capacity = 100,
///     .priority_queues = true,
///     .enable_deadletter = true,
/// });
/// defer mailbox.deinit();
///
/// // Send a message
/// try mailbox.send(msg);
///
/// // Receive messages
/// while (mailbox.receive()) |msg| {
///     defer msg.deinit();
///     // Process message
/// } else |err| switch (err) {
///     error.EmptyMailbox => break,
///     else => return err,
/// }
/// ```
pub const ProcessMailbox = struct {
    messages: std.ArrayList(Message), // Main message queue
    priority_queues: ?[5]std.ArrayList(Message), // Priority-based queues
    deadletter_queue: ?std.ArrayList(Message), // Queue for undeliverable messages
    mutex: Mutex, // Thread synchronization
    config: MailboxConfig, // Mailbox configuration
    stats: MailboxStats, // Usage statistics

    /// Statistics for monitoring mailbox performance and usage
    pub const MailboxStats = struct {
        messages_received: usize = 0, // Total messages received
        messages_sent: usize = 0, // Total messages sent
        messages_expired: usize = 0, // Messages expired before delivery
        messages_dropped: usize = 0, // Messages dropped due to constraints
        peak_usage: usize = 0, // Maximum queue size reached
        total_size_bytes: usize = 0, // Total size of all messages
    };

    pub fn init(allocator: Allocator, config: MailboxConfig) ProcessMailbox {
        const priority_queues: ?[5]std.ArrayList(Message) = if (config.priority_queues)
            .{
                std.ArrayList(Message).init(allocator), // critical
                std.ArrayList(Message).init(allocator), // high
                std.ArrayList(Message).init(allocator), // normal
                std.ArrayList(Message).init(allocator), // low
                std.ArrayList(Message).init(allocator), // batch
            }
        else
            null;

        return .{
            .messages = std.ArrayList(Message).init(allocator),
            .priority_queues = priority_queues,
            .deadletter_queue = if (config.enable_deadletter)
                std.ArrayList(Message).init(allocator)
            else
                null,
            .mutex = .{},
            .config = config,
            .stats = .{},
        };
    }

    pub fn deinit(self: *ProcessMailbox) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Clean up main message queue
        for (self.messages.items) |*msg| {
            msg.deinit();
        }
        self.messages.deinit();

        // Clean up priority queues if enabled
        if (self.priority_queues) |*queues| {
            for (queues) |*queue| {
                for (queue.items) |*msg| {
                    msg.deinit();
                }
                queue.deinit();
            }
        }

        // Clean up deadletter queue if enabled
        if (self.deadletter_queue) |*queue| {
            for (queue.items) |*msg| {
                msg.deinit();
            }
            queue.deinit();
        }
    }

    /// Send a message with priority handling and size checks
    pub fn send(self: *ProcessMailbox, msg: Message) MessageError!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Take ownership of the message
        var msg_mut = msg;
        errdefer msg_mut.deinit();

        // Validate message size
        if (msg_mut.metadata.size_bytes > self.config.max_message_size) {
            return MessageError.MessageTooLarge;
        }

        // Check for expired TTL
        if (msg_mut.isExpired()) {
            self.stats.messages_expired += 1;
            return MessageError.MessageExpired;
        }

        // Handle priority queues if enabled
        if (self.priority_queues) |*queues| {
            const queue_idx = msg_mut.priority.toInt();
            const queue = &queues[queue_idx];

            if (queue.items.len >= self.config.capacity) {
                // Try to move to deadletter queue if enabled
                if (self.deadletter_queue) |*dlq| {
                    dlq.append(msg_mut) catch |err| switch (err) {
                        error.OutOfMemory => {
                            return MessageError.OutOfMemory;
                        },
                    };
                    self.stats.messages_dropped += 1;
                    return;
                }
                self.stats.messages_dropped += 1;
                return MessageError.MailboxFull;
            }

            queue.append(msg_mut) catch |err| switch (err) {
                error.OutOfMemory => {
                    return MessageError.OutOfMemory;
                },
            };
        } else {
            // Use standard queue
            if (self.messages.items.len >= self.config.capacity) {
                self.stats.messages_dropped += 1;
                return MessageError.MailboxFull;
            }

            self.messages.append(msg_mut) catch |err| switch (err) {
                error.OutOfMemory => {
                    return MessageError.OutOfMemory;
                },
            };
        }

        // Update stats
        self.stats.messages_received += 1;
        self.stats.total_size_bytes += msg_mut.metadata.size_bytes;
        self.stats.peak_usage = @max(
            self.stats.peak_usage,
            self.messages.items.len,
        );
    }

    /// Receive message with priority handling
    pub fn receive(self: *ProcessMailbox) MessageError!Message {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Remove all expired messages first
        if (self.priority_queues) |*queues| {
            for (queues) |*queue| {
                var i: usize = 0;
                while (i < queue.items.len) {
                    if (queue.items[i].isExpired()) {
                        var msg = queue.orderedRemove(i);
                        msg.deinit();
                        self.stats.messages_expired += 1;
                        self.stats.total_size_bytes -= msg.metadata.size_bytes;
                    } else {
                        i += 1;
                    }
                }
            }

            // Now try to get a valid message from priority queues
            for (queues) |*queue| {
                if (queue.items.len > 0) {
                    if (queue.items[0].isExpired()) {
                        var msg = queue.orderedRemove(0);
                        msg.deinit();
                        self.stats.messages_expired += 1;
                        self.stats.total_size_bytes -= msg.metadata.size_bytes;
                        continue;
                    }
                    const msg = queue.orderedRemove(0);
                    self.stats.messages_sent += 1;
                    self.stats.total_size_bytes -= msg.metadata.size_bytes;
                    return msg;
                }
            }
            return MessageError.EmptyMailbox;
        }

        // Standard queue handling
        var i: usize = 0;
        while (i < self.messages.items.len) {
            if (self.messages.items[i].isExpired()) {
                var msg = self.messages.orderedRemove(i);
                msg.deinit();
                self.stats.messages_expired += 1;
                self.stats.total_size_bytes -= msg.metadata.size_bytes;
            } else {
                i += 1;
            }
        }

        if (self.messages.items.len == 0) {
            return MessageError.EmptyMailbox;
        }

        // Double check expiration of the first message
        if (self.messages.items[0].isExpired()) {
            var msg = self.messages.orderedRemove(0);
            msg.deinit();
            self.stats.messages_expired += 1;
            self.stats.total_size_bytes -= msg.metadata.size_bytes;
            return MessageError.EmptyMailbox;
        }

        const msg = self.messages.orderedRemove(0);
        self.stats.messages_sent += 1;
        self.stats.total_size_bytes -= msg.metadata.size_bytes;
        return msg;
    }

    /// Peek at next message without removing it
    pub fn peek(self: *ProcessMailbox) MessageError!Message {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.priority_queues) |queues| {
            // Check queues in priority order
            for (queues) |queue| {
                if (queue.items.len > 0) {
                    const msg = queue.items[0];
                    if (msg.isExpired()) {
                        return MessageError.MessageExpired;
                    }
                    return msg;
                }
            }
            return MessageError.EmptyMailbox;
        }

        if (self.messages.items.len == 0) {
            return MessageError.EmptyMailbox;
        }

        const msg = self.messages.items[0];
        if (msg.isExpired()) {
            return MessageError.MessageExpired;
        }

        return msg;
    }

    /// Clear all messages from the mailbox
    pub fn clear(self: *ProcessMailbox) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Clear main message queue
        for (self.messages.items) |*msg| {
            msg.deinit();
        }
        self.messages.clearRetainingCapacity();

        // Clear priority queues if enabled
        if (self.priority_queues) |*queues| {
            for (queues) |*queue| {
                for (queue.items) |*msg| {
                    msg.deinit();
                }
                queue.clearRetainingCapacity();
            }
        }

        // Reset stats
        self.stats.total_size_bytes = 0;
    }

    /// Get mailbox statistics
    pub fn getStats(self: *ProcessMailbox) MailboxStats {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.stats;
    }

    /// Check if mailbox has capacity for a message of given size
    pub fn hasCapacity(self: *ProcessMailbox, msg_size: usize) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (msg_size > self.config.max_message_size) {
            return false;
        }

        const current_count = if (self.priority_queues) |queues| blk: {
            var total: usize = 0;
            for (queues) |queue| {
                total += queue.items.len;
            }
            break :blk total;
        } else self.messages.items.len;

        return current_count < self.config.capacity;
    }
};

test "ProcessMailbox priority queue operations" {
    const allocator = testing.allocator;
    var mailbox = ProcessMailbox.init(allocator, .{
        .capacity = 10,
        .priority_queues = true,
    });
    defer mailbox.deinit();

    // Send messages with different priorities
    try mailbox.send(try Message.init(
        allocator,
        "high_pri",
        "sender1",
        "urgent",
        Signal.alert,
        .high,
        null,
    ));

    try mailbox.send(try Message.init(
        allocator,
        "low_pri",
        "sender2",
        "background",
        Signal.info,
        .low,
        null,
    ));

    try mailbox.send(try Message.init(
        allocator,
        "critical",
        "sender3",
        "emergency",
        Signal.alert,
        .critical,
        null,
    ));

    // Verify messages are received in priority order
    {
        var received = try mailbox.receive();
        defer received.deinit();
        try testing.expectEqualStrings("critical", received.id);
    }

    {
        var received = try mailbox.receive();
        defer received.deinit();
        try testing.expectEqualStrings("high_pri", received.id);
    }

    {
        var received = try mailbox.receive();
        defer received.deinit();
        try testing.expectEqualStrings("low_pri", received.id);
    }
}

test "Message TTL and expiration" {
    const allocator = testing.allocator;
    var mailbox = ProcessMailbox.init(allocator, .{
        .capacity = 10,
        .default_ttl_ms = 1,
        .priority_queues = false, // Disable priority queues for this test
    });
    defer mailbox.deinit();

    // Send a message with very short TTL
    const msg = try Message.init(
        allocator,
        "expiring",
        "sender",
        "test",
        null,
        .normal,
        1000, // 1 second TTL
    );

    // Send takes ownership
    try mailbox.send(msg);

    // Set timestamp in the past to force expiration on next receive
    mailbox.messages.items[0].metadata.timestamp -= 2;

    // Try to receive - should get EmptyMailbox since expired messages are removed
    try testing.expectError(MessageError.EmptyMailbox, mailbox.receive());

    // Verify stats
    const stats = mailbox.getStats();
    try testing.expectEqual(@as(usize, 1), stats.messages_received);
    try testing.expectEqual(@as(usize, 0), stats.messages_sent);
    try testing.expectEqual(@as(usize, 1), stats.messages_expired);
}

test "Message correlation and response" {
    const allocator = testing.allocator;

    var msg = try Message.init(
        allocator,
        "request",
        "sender",
        "query",
        Signal.info,
        .normal,
        null,
    );
    defer msg.deinit();

    try msg.setCorrelationId("correlation123");
    try msg.setReplyTo("reply_mailbox");

    {
        var response = try msg.createResponse(
            allocator,
            "response_data",
            Signal.info,
        );
        defer response.deinit();

        try testing.expectEqualStrings("resp_request", response.id);
        try testing.expectEqualStrings("reply_mailbox", response.sender);
        if (response.metadata.correlation_id) |cid| {
            try testing.expectEqualStrings("correlation123", cid);
        } else {
            return error.MissingCorrelationId;
        }
    }
}

test "Mailbox capacity and message size limits" {
    const allocator = testing.allocator;
    var mailbox = ProcessMailbox.init(allocator, .{
        .capacity = 2,
        .max_message_size = 100,
    });
    defer mailbox.deinit();

    // Test message size limit
    const large_payload = try allocator.alloc(u8, 101);
    defer allocator.free(large_payload);
    @memset(large_payload, 'x');

    const msg = try Message.init(
        allocator,
        "large",
        "sender",
        large_payload,
        null,
        .normal,
        null,
    );
    try testing.expectError(MessageError.MessageTooLarge, mailbox.send(msg));
}
