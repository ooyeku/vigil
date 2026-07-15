//! Message handling module for the Vigil supervision system.
//! This module provides robust message handling capabilities inspired by Erlang/OTP,
//! allowing for fine-grained control over message routing, priority, and error handling.
//!
//! Key features:
//! - Priority-based message queuing
//! - Message delivery and response tracking
//! - Message validation and error handling
//! - Built-in monitoring and statistics
//!
//! Example usage:
//! ```zig
//! const Message = @import("messages.zig").Message;
//! const MessagePriority = @import("messages.zig").MessagePriority;
//! const Signal = @import("messages.zig").Signal;
//! const MessageMetadata = @import("messages.zig").MessageMetadata;
//! const MessageError = @import("messages.zig").MessageError;
//!
//! // Create a new message
//! var msg = try Message.init(allocator, "msg_001", "sender_proc", "Hello!", .info, .normal, 10000);
//! defer msg.deinit();
//!
//! // Create a response
//! if (msg.metadata.reply_to) |_| {
//!     var response = try msg.createResponse(allocator, "Got it!", .info);
//!     defer response.deinit();
//! }
//!
//! // Set correlation ID for tracking
//! try msg.setCorrelationId("correlation_id_001");
//!
//! // Set reply-to address for responses
//! try msg.setReplyTo("receiver_proc");
//!
//! // Check if message is expired
//! if (msg.isExpired()) {
//!     // Handle expired message
//! }
//! ```
const std = @import("std");
const compat = @import("compat.zig");
const Mutex = compat.Mutex;
const RingQueue = @import("ring_queue.zig").RingQueue;
const testing = std.testing;
const Allocator = std.mem.Allocator;

/// Error set for message handling operations.
/// These errors cover the full range of potential failures in message processing,
/// from basic mailbox operations to delivery and validation issues.
pub const MessageError = error{
    /// No messages are available for receiving.
    EmptyMailbox,
    /// Mailbox has reached its configured capacity.
    MailboxFull,
    /// Message format or content is invalid for the operation.
    InvalidMessage,
    /// Sender identification is missing or invalid.
    InvalidSender,
    /// Message TTL has elapsed.
    MessageExpired,
    /// Message could not be delivered within the requested timeout.
    DeliveryTimeout,
    /// Target receiver is not accepting messages.
    ReceiverUnavailable,
    /// Message priority level is invalid.
    InvalidPriority,
    /// Signal type is not recognized.
    InvalidSignal,
    /// Message exceeds the configured size limit.
    MessageTooLarge,
    /// Message with the same id already exists.
    DuplicateMessage,
    /// Memory allocation failed.
    OutOfMemory,
    /// Operation was rejected by a rate limiter.
    RateLimitExceeded,
    /// Message could not be delivered to a subscriber.
    DeliveryFailed,
    /// Dead-letter storage is enabled but has reached its configured capacity.
    DeadLetterFull,
};

/// Message priority levels for handling urgent communications.
/// Priority determines message processing order and resource allocation.
/// Use this to ensure critical messages are handled before less important ones.
///
/// Priority levels:
/// - critical: Immediate handling required (e.g., shutdown signals, system failures)
/// - high: Urgent but not critical (e.g., health alerts, resource warnings)
/// - normal: Standard operations (e.g., status updates, routine tasks)
/// - low: Background tasks (e.g., cleanup, optimization)
/// - batch: Bulk operations (e.g., data processing, logging)
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
    /// Immediate handling required, such as shutdown or system failure.
    critical,
    /// Urgent but not critical, such as health alerts.
    high,
    /// Standard application work.
    normal,
    /// Background or deferrable work.
    low,
    /// Bulk work such as batching, logging, or offline processing.
    batch,

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

/// Signal types for process communication.
/// Signals represent specific actions or states that processes can communicate.
/// Use these to trigger specific behaviors or responses in receiving processes.
///
/// Signals:
/// - restart
/// - shutdown
/// - terminate
/// - exit
/// - suspend
/// - resume
/// - healthCheck
/// - memoryWarning
/// - cpuWarning
/// - deadlockDetected
/// - messageErr
/// - info
/// - warning
/// - debug
/// - log
/// - alert
/// - metric
/// - event
/// - heartbeat
/// - custom
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
    /// Request process restart.
    restart,
    /// Request graceful shutdown.
    shutdown,
    /// Request immediate termination.
    terminate,
    /// Normal process exit.
    exit,
    /// Pause process execution.
    @"suspend",
    /// Resume process execution.
    @"resume",
    /// Request health status.
    healthCheck,
    /// Memory usage alert.
    memoryWarning,
    /// CPU usage alert.
    cpuWarning,
    /// Deadlock condition detected.
    deadlockDetected,
    /// Message processing error.
    messageErr,
    /// Informational message.
    info,
    /// Warning condition.
    warning,
    /// Debug information.
    debug,
    /// Log entry.
    log,
    /// Important alert.
    alert,
    /// Performance metric.
    metric,
    /// System event.
    event,
    /// Process heartbeat.
    heartbeat,
    /// User-defined signal. Put domain details in the payload.
    custom,
};

/// Message metadata for tracking and debugging.
/// Contains information about message lifecycle, routing, and monitoring.
///
/// Fields:
/// - timestamp: i64, // Creation timestamp (Unix epoch)
/// - ttl_ms: ?u32, // Time-to-live in milliseconds (null = no expiry)
/// - correlation_id: ?[]const u8, // For tracking related messages
/// - reply_to: ?[]const u8, // Destination for responses
/// - attempt_count: u32, // Number of delivery attempts made
/// - trace_id: ?[]const u8, // For distributed tracing
/// - size_bytes: usize, // Total message size in bytes
pub const MessageMetadata = struct {
    /// Creation timestamp in Unix milliseconds.
    timestamp: i64,
    /// Time-to-live in milliseconds. Null means no expiry.
    ttl_ms: ?u32,
    /// Correlation id for request/reply or tracing related messages.
    correlation_id: ?[]const u8,
    /// Logical destination for responses.
    reply_to: ?[]const u8,
    /// Number of delivery attempts made.
    attempt_count: u32,
    /// Optional distributed tracing id.
    trace_id: ?[]const u8,
    /// Total message size in bytes.
    size_bytes: usize,
};

/// Message structure with metadata and delivery controls.
/// Messages are the primary means of communication between processes.
/// They support priorities, signals, TTL, and response tracking.
///
/// Fields:
/// - id: []const u8, // Unique message identifier
/// - payload: ?[]const u8, // Optional message content (optional)
/// - signal: ?Signal, // Optional signal type (optional)
/// - sender: []const u8, // Sender identifier
/// - priority: MessagePriority, // Message priority level
/// - metadata: MessageMetadata, // Message metadata
/// - allocator: Allocator, // Memory allocator
///
/// Methods:
/// - init: fn (allocator: Allocator, id: []const u8, sender: []const u8, payload: ?[]const u8, signal: ?Signal, priority: MessagePriority, ttl_ms: ?u32) !Message
/// - deinit: fn (self: *Message) void
/// - isExpired: fn (self: Message) bool
/// - setCorrelationId: fn (self: *Message, correlation_id: []const u8) !void
/// - setReplyTo: fn (self: *Message, reply_to: []const u8) !void
/// - createResponse: fn (self: Message, allocator: Allocator, payload: ?[]const u8, signal: ?Signal) !Message
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
    /// Unique message identifier owned by this message.
    id: []const u8,
    /// Optional payload owned by this message.
    payload: ?[]const u8,
    /// Optional process signal.
    signal: ?Signal,
    /// Sender identifier owned by this message.
    sender: []const u8,
    /// Priority used by priority-aware mailboxes.
    priority: MessagePriority,
    /// Lifecycle and routing metadata.
    metadata: MessageMetadata,
    /// Single owned buffer backing `id`, `sender`, and `payload`.
    ///
    /// Packing the copied strings into one allocation keeps message
    /// construction at one allocator call on the send hot path. Do not free
    /// `id`/`sender`/`payload` individually; they are slices into this buffer.
    storage: []const u8,
    /// Allocator used for owned fields.
    allocator: Allocator,

    /// Initialize a new owned message.
    ///
    /// `id`, `sender`, and `payload` are copied into one owned buffer. The
    /// caller owns the returned message and must call `deinit()`.
    pub fn init(
        allocator: Allocator,
        id: []const u8,
        sender: []const u8,
        payload: ?[]const u8,
        signal: ?Signal,
        priority: MessagePriority,
        ttl_ms: ?u32,
    ) !Message {
        const payload_len = if (payload) |p| p.len else 0;
        const storage = try allocator.alloc(u8, id.len + sender.len + payload_len);

        @memcpy(storage[0..id.len], id);
        @memcpy(storage[id.len..][0..sender.len], sender);
        const payload_copy: ?[]const u8 = if (payload) |p| blk: {
            const dest = storage[id.len + sender.len ..][0..p.len];
            @memcpy(dest, p);
            break :blk dest;
        } else null;

        return Message{
            .id = storage[0..id.len],
            .sender = storage[id.len..][0..sender.len],
            .payload = payload_copy,
            .signal = signal,
            .priority = priority,
            .metadata = .{
                .timestamp = compat.milliTimestamp(),
                .ttl_ms = ttl_ms,
                .correlation_id = null,
                .reply_to = null,
                .attempt_count = 0,
                .trace_id = null,
                .size_bytes = storage.len,
            },
            .storage = storage,
            .allocator = allocator,
        };
    }

    /// Free all allocated memory associated with the message.
    /// Must be called when message is no longer needed.
    /// Takes a const pointer to allow calling on const captures from recv/recvTimeout.
    pub fn deinit(self: *const Message) void {
        self.allocator.free(self.storage);

        if (self.metadata.reply_to) |rt| {
            self.allocator.free(rt);
        }
        if (self.metadata.correlation_id) |cid| {
            self.allocator.free(cid);
        }
    }

    /// Return true if the message has a TTL and that TTL has elapsed.
    pub fn isExpired(self: Message) bool {
        return self.isExpiredAt(compat.milliTimestamp());
    }

    /// Return whether the message would be expired at `now_ms` (Unix
    /// milliseconds). Batch operations read the clock once and reuse it so
    /// sweeping a deep queue does not pay one clock read per message.
    pub fn isExpiredAt(self: Message, now_ms: i64) bool {
        if (self.metadata.ttl_ms) |ttl| {
            if (now_ms <= self.metadata.timestamp) return false;
            return now_ms - self.metadata.timestamp >= @as(i64, ttl);
        }
        return false;
    }

    /// Set or replace the correlation id for tracking related messages.
    ///
    /// The id is copied.
    /// Useful for request-response patterns and message chains.
    pub fn setCorrelationId(self: *Message, correlation_id: []const u8) !void {
        const id_copy = try self.allocator.dupe(u8, correlation_id);
        const old_len = if (self.metadata.correlation_id) |old_id| old_id.len else 0;
        if (self.metadata.correlation_id) |old_id| {
            self.allocator.free(old_id);
        }
        self.metadata.correlation_id = id_copy;
        self.metadata.size_bytes = (self.metadata.size_bytes -| old_len) +| id_copy.len;
    }

    /// Set or replace the reply-to address for responses.
    ///
    /// The address is copied.
    /// Required for createResponse() to work.
    pub fn setReplyTo(self: *Message, reply_to: []const u8) !void {
        const reply_to_copy = try self.allocator.dupe(u8, reply_to);
        const old_len = if (self.metadata.reply_to) |old_rt| old_rt.len else 0;
        if (self.metadata.reply_to) |old_rt| {
            self.allocator.free(old_rt);
        }
        self.metadata.reply_to = reply_to_copy;
        self.metadata.size_bytes = (self.metadata.size_bytes -| old_len) +| reply_to_copy.len;
    }

    /// Create a response message to this message.
    ///
    /// Requires reply_to to be set on the original message.
    /// The returned response is owned by the caller.
    pub fn createResponse(self: Message, allocator: Allocator, payload: ?[]const u8, signal: ?Signal) !Message {
        if (self.metadata.reply_to == null) return MessageError.InvalidMessage;

        // Build the response id up front; id/sender/payload share one owned
        // buffer, so the id cannot be replaced after construction.
        const resp_id = try std.fmt.allocPrint(allocator, "resp_{s}", .{self.id});
        defer allocator.free(resp_id);

        var response = try Message.init(
            allocator,
            resp_id,
            self.metadata.reply_to.?,
            payload,
            signal,
            self.priority,
            self.metadata.ttl_ms,
        );
        errdefer response.deinit();

        // Set correlation ID if present
        if (self.metadata.correlation_id) |cid| {
            try response.setCorrelationId(cid);
        }

        return response;
    }

    /// Deep-copy this message using the message allocator.
    ///
    /// The returned message is independent and must be deinitialized.
    pub fn dupe(self: *const Message) !Message {
        return self.cloneWithAllocator(self.allocator);
    }

    /// Deep-copy this message using `allocator` for the returned ownership.
    pub fn cloneWithAllocator(self: *const Message, allocator: Allocator) !Message {
        const payload_len = if (self.payload) |p| p.len else 0;
        const storage = try allocator.alloc(u8, self.id.len + self.sender.len + payload_len);
        errdefer allocator.free(storage);

        @memcpy(storage[0..self.id.len], self.id);
        @memcpy(storage[self.id.len..][0..self.sender.len], self.sender);
        const new_payload: ?[]const u8 = if (self.payload) |p| blk: {
            const dest = storage[self.id.len + self.sender.len ..][0..p.len];
            @memcpy(dest, p);
            break :blk dest;
        } else null;

        // Duplicate metadata strings
        var new_reply_to: ?[]const u8 = null;
        if (self.metadata.reply_to) |rt| {
            new_reply_to = try allocator.dupe(u8, rt);
            errdefer allocator.free(new_reply_to.?);
        }

        var new_correlation_id: ?[]const u8 = null;
        if (self.metadata.correlation_id) |cid| {
            new_correlation_id = try allocator.dupe(u8, cid);
            errdefer allocator.free(new_correlation_id.?);
        }

        return Message{
            .id = storage[0..self.id.len],
            .sender = storage[self.id.len..][0..self.sender.len],
            .payload = new_payload,
            .signal = self.signal,
            .priority = self.priority,
            .metadata = .{
                .timestamp = self.metadata.timestamp,
                .ttl_ms = self.metadata.ttl_ms,
                .correlation_id = new_correlation_id,
                .reply_to = new_reply_to,
                .attempt_count = self.metadata.attempt_count,
                .trace_id = self.metadata.trace_id,
                .size_bytes = self.metadata.size_bytes,
            },
            .storage = storage,
            .allocator = allocator,
        };
    }
};

/// Why a message was moved out of the active mailbox.
pub const DeadLetterReason = enum {
    mailbox_full,
    expired,
    delivery_failed,
    manual,
    max_attempts,
};

/// Immutable scalar information about a dead-letter lifecycle event.
pub const DeadLetterNotice = struct {
    id: u64,
    reason: DeadLetterReason,
    attempt_count: u32,
    poisoned: bool,
    newly_poisoned: bool = false,
};

/// One mailbox-owned dead-letter entry.
pub const DeadLetterEntry = struct {
    id: u64,
    message: Message,
    reason: DeadLetterReason,
    dead_lettered_at_ms: i64,
    poisoned: bool,

    pub fn deinit(self: *const DeadLetterEntry) void {
        self.message.deinit();
    }

    fn cloneWithAllocator(self: *const DeadLetterEntry, allocator: Allocator) !DeadLetterEntry {
        return .{
            .id = self.id,
            .message = try self.message.cloneWithAllocator(allocator),
            .reason = self.reason,
            .dead_lettered_at_ms = self.dead_lettered_at_ms,
            .poisoned = self.poisoned,
        };
    }

    fn notice(self: *const DeadLetterEntry, newly_poisoned: bool) DeadLetterNotice {
        return .{
            .id = self.id,
            .reason = self.reason,
            .attempt_count = self.message.metadata.attempt_count,
            .poisoned = self.poisoned,
            .newly_poisoned = newly_poisoned,
        };
    }
};

/// Owned copy of a mailbox's current dead-letter entries.
pub const DeadLetterSnapshot = struct {
    allocator: Allocator,
    entries: []DeadLetterEntry,

    pub fn deinit(self: *DeadLetterSnapshot) void {
        for (self.entries) |*entry| entry.deinit();
        self.allocator.free(self.entries);
    }
};

/// Non-consuming snapshot of one active queued message.
///
/// `id` and `sender` are copied and owned by the enclosing
/// `MailboxQueueSnapshot`. Payload bytes are intentionally not copied; only
/// the payload length is captured so inspection stays cheap and safe.
pub const QueuedMessageSnapshot = struct {
    /// Copied message id.
    id: []const u8,
    /// Copied sender identifier.
    sender: []const u8,
    /// Message priority.
    priority: MessagePriority,
    /// Optional process signal.
    signal: ?Signal,
    /// Payload size in bytes; zero when the message has no payload.
    payload_len: usize,
    /// Delivery attempts made so far.
    attempt_count: u32,
    /// Creation timestamp in Unix milliseconds.
    timestamp_ms: i64,
    /// Time-to-live in milliseconds, when set.
    ttl_ms: ?u32,
    /// Whether the message had already expired when the snapshot was taken.
    expired: bool,
};

/// Owned snapshot of a mailbox's active queue in delivery order.
pub const MailboxQueueSnapshot = struct {
    allocator: Allocator,
    entries: []QueuedMessageSnapshot,

    /// Release copied identity strings and snapshot storage.
    pub fn deinit(self: *MailboxQueueSnapshot) void {
        for (self.entries) |entry| {
            self.allocator.free(entry.id);
            self.allocator.free(entry.sender);
        }
        self.allocator.free(self.entries);
    }
};

/// Result of accepting a message into the active queue or dead-letter storage.
pub const MessageDelivery = union(enum) {
    enqueued,
    dead_lettered: DeadLetterNotice,
};

/// Result of trying to move a dead-letter entry back to the active queue.
pub const DeadLetterReplayStatus = enum {
    replayed,
    retained,
    poison,
    not_found,
};

pub const DeadLetterReplayResult = struct {
    status: DeadLetterReplayStatus,
    notice: ?DeadLetterNotice,
};

/// Configuration options for mailbox behavior.
/// Use this to customize mailbox capacity, message size limits,
/// TTL defaults, and optional features.
///
/// Fields:
/// - capacity: usize, // Maximum number of messages
/// - max_message_size: usize, // Maximum message size (1MB default)
/// - default_ttl_ms: ?u32, // Default message TTL (1 minute)
/// - priority_queues: bool, // Enable priority-based queuing
/// - enable_deadletter: bool, // Enable dead letter queue
pub const MailboxConfig = struct {
    /// Maximum number of queued messages.
    capacity: usize,
    /// Maximum accepted message size. Defaults to 1 MiB.
    max_message_size: usize = 1024 * 1024,
    /// Default message TTL. Null disables the default.
    default_ttl_ms: ?u32 = 60_000,
    /// Enable priority-based queues.
    priority_queues: bool = true,
    /// Enable dead-letter storage for undeliverable messages.
    enable_deadletter: bool = true,
    /// Maximum retained dead-letter entries. Zero rejects all dead letters.
    dead_letter_capacity: usize = 100,
    /// Failed delivery attempts after which a rejected message becomes poison.
    max_delivery_attempts: u32 = 3,
};

/// Process mailbox with priority queues and monitoring.
/// Provides thread-safe message handling with optional priority queues
/// and dead letter support for undeliverable messages.
///
/// Fields:
/// - messages: std.ArrayList(Message), // Main message queue
/// - priority_queues: ?[5]std.ArrayList(Message), // Priority-based queues (optional)
/// - deadletter_queue: ?std.ArrayList(Message), // Queue for undeliverable messages (optional)
/// - mutex: Mutex, // Thread synchronization
/// - config: MailboxConfig, // Mailbox configuration
/// - stats: MailboxStats, // Usage statistics
///
/// Methods:
/// - init: fn (allocator: Allocator, config: MailboxConfig) ProcessMailbox
/// - deinit: fn (self: *ProcessMailbox) void
/// - send: fn (self: *ProcessMailbox, msg: Message) MessageError!void
/// - receive: fn (self: *ProcessMailbox) MessageError!Message
/// - getStats: fn (self: *ProcessMailbox) MailboxStats
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
    /// FIFO queue used when priority queues are disabled.
    messages: RingQueue(Message),
    /// Priority queues indexed by `MessagePriority.toInt()`.
    priority_queues: ?[5]RingQueue(Message),
    /// Bounded queue for undeliverable messages when enabled.
    deadletter_queue: ?std.ArrayList(DeadLetterEntry),
    /// Monotonic identifier assigned to the next dead-letter entry.
    next_dead_letter_id: u64,
    /// Current number of poison entries in dead-letter storage.
    current_poison_count: usize,
    /// Protects queue state.
    mutex: Mutex,
    /// Signaled when a message enters the active queue; used by blocking
    /// receives instead of polling.
    not_empty: compat.Condition,
    /// Mailbox behavior settings.
    config: MailboxConfig,
    /// Usage statistics.
    stats: MailboxStats,
    /// Allocator for queue storage.
    allocator: Allocator,

    /// Statistics for monitoring mailbox performance and usage.
    pub const MailboxStats = struct {
        /// Total messages accepted by `send()`.
        messages_received: usize = 0,
        /// Total messages returned by `receive()`.
        messages_sent: usize = 0,
        /// Messages expired before delivery.
        messages_expired: usize = 0,
        /// Messages dropped due to constraints.
        messages_dropped: usize = 0,
        /// Messages retained in dead-letter storage.
        messages_dead_lettered: usize = 0,
        /// Dead-letter entries successfully returned to the active queue.
        dead_letters_replayed: usize = 0,
        /// Dead-letter entries explicitly discarded.
        dead_letters_discarded: usize = 0,
        /// Messages classified as poison after repeated failed delivery.
        poison_messages: usize = 0,
        /// Maximum queue size reached.
        peak_usage: usize = 0,
        /// Total size of queued messages.
        total_size_bytes: usize = 0,
    };

    /// Initialize an empty mailbox.
    pub fn init(allocator: Allocator, config: MailboxConfig) ProcessMailbox {
        const priority_queues: ?[5]RingQueue(Message) = if (config.priority_queues)
            .{ .empty, .empty, .empty, .empty, .empty }
        else
            null;

        return .{
            .messages = .empty,
            .priority_queues = priority_queues,
            .deadletter_queue = if (config.enable_deadletter)
                .empty
            else
                null,
            .next_dead_letter_id = 1,
            .current_poison_count = 0,
            .mutex = .{},
            .not_empty = .{},
            .config = config,
            .stats = .{},
            .allocator = allocator,
        };
    }

    /// Deinitialize all queued messages and queue storage.
    pub fn deinit(self: *ProcessMailbox) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Clean up main message queue
        while (self.messages.popFront()) |msg| {
            msg.deinit();
        }
        self.messages.deinit(self.allocator);

        // Clean up priority queues if enabled
        if (self.priority_queues) |*queues| {
            for (queues) |*queue| {
                while (queue.popFront()) |msg| {
                    msg.deinit();
                }
                queue.deinit(self.allocator);
            }
        }

        // Clean up deadletter queue if enabled
        if (self.deadletter_queue) |*queue| {
            for (queue.items) |*entry| {
                entry.deinit();
            }
            queue.deinit(self.allocator);
        }
    }

    /// Send a message with priority handling and size checks.
    ///
    /// This function consumes `msg`; after calling it, do not use or deinit the
    /// original message value, even when an error is returned.
    pub fn send(self: *ProcessMailbox, msg: Message) MessageError!void {
        _ = try self.sendWithDisposition(msg);
    }

    /// Send a message and report whether it entered the active or dead-letter queue.
    ///
    /// This function consumes `msg` on both success and error.
    pub fn sendWithDisposition(self: *ProcessMailbox, msg: Message) MessageError!MessageDelivery {
        self.mutex.lock();
        defer self.mutex.unlock();

        var msg_mut = msg;
        errdefer msg_mut.deinit();

        if (msg_mut.metadata.size_bytes > self.config.max_message_size) {
            return MessageError.MessageTooLarge;
        }

        if (msg_mut.metadata.ttl_ms == null) {
            msg_mut.metadata.ttl_ms = self.config.default_ttl_ms;
        }

        const now_ms = compat.milliTimestamp();
        if (msg_mut.isExpiredAt(now_ms)) {
            self.stats.messages_expired +|= 1;
            if (self.deadletter_queue != null) {
                const notice = self.appendDeadLetterLocked(msg_mut, .expired) catch |err| {
                    self.stats.messages_dropped +|= 1;
                    return err;
                };
                return .{ .dead_lettered = notice };
            }
            self.stats.messages_dropped +|= 1;
            return MessageError.MessageExpired;
        }

        if (self.activeQueuedCountLocked() >= self.config.capacity) {
            // Expiry is lazy on the receive path, so an apparently full
            // mailbox may hold expired messages. Reclaim them in one sweep
            // before treating the send as overflow.
            self.expireAllLocked(now_ms);
        }

        if (self.activeQueuedCountLocked() >= self.config.capacity) {
            if (self.deadletter_queue != null) {
                const notice = self.appendDeadLetterLocked(msg_mut, .mailbox_full) catch |err| {
                    self.stats.messages_dropped +|= 1;
                    return err;
                };
                return .{ .dead_lettered = notice };
            }
            self.stats.messages_dropped +|= 1;
            return MessageError.MailboxFull;
        }

        try self.appendActiveLocked(msg_mut, true);
        return .enqueued;
    }

    /// Move a caller-owned failed message into dead-letter storage.
    ///
    /// The message is consumed on both success and error. Messages rejected
    /// after `max_delivery_attempts` are classified as poison.
    pub fn deadLetter(self: *ProcessMailbox, msg: Message, reason: DeadLetterReason) MessageError!DeadLetterNotice {
        self.mutex.lock();
        defer self.mutex.unlock();

        var msg_mut = msg;
        errdefer msg_mut.deinit();

        if (reason == .delivery_failed and msg_mut.metadata.attempt_count == 0) {
            msg_mut.metadata.attempt_count = 1;
        }
        if (self.deadletter_queue == null) {
            self.stats.messages_dropped +|= 1;
            return MessageError.DeliveryFailed;
        }
        return self.appendDeadLetterLocked(msg_mut, reason) catch |err| {
            self.stats.messages_dropped +|= 1;
            return err;
        };
    }

    /// Return an owned, deep-copy snapshot of all dead-letter entries.
    pub fn snapshotDeadLetters(self: *ProcessMailbox, allocator: Allocator) !DeadLetterSnapshot {
        self.mutex.lock();
        defer self.mutex.unlock();

        const queue = self.deadletter_queue orelse return .{
            .allocator = allocator,
            .entries = try allocator.alloc(DeadLetterEntry, 0),
        };
        const entries = try allocator.alloc(DeadLetterEntry, queue.items.len);
        errdefer allocator.free(entries);

        var written: usize = 0;
        errdefer for (entries[0..written]) |*entry| entry.deinit();
        for (queue.items) |*entry| {
            entries[written] = try entry.cloneWithAllocator(allocator);
            written += 1;
        }
        return .{ .allocator = allocator, .entries = entries };
    }

    /// Return the number of retained dead-letter entries.
    pub fn deadLetterCount(self: *ProcessMailbox) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return if (self.deadletter_queue) |queue| queue.items.len else 0;
    }

    /// Return the number of currently retained poison entries.
    pub fn poisonCount(self: *ProcessMailbox) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.current_poison_count;
    }

    /// Try to replay one dead-letter entry by its stable mailbox-local id.
    ///
    /// A full active queue retains the entry for a later replay. Poison entries
    /// are never replayed implicitly.
    pub fn replayDeadLetter(self: *ProcessMailbox, id: u64) MessageError!DeadLetterReplayResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        const queue = if (self.deadletter_queue) |*deadletters| deadletters else return .{
            .status = .not_found,
            .notice = null,
        };
        const index = findDeadLetterIndex(queue.items, id) orelse return .{
            .status = .not_found,
            .notice = null,
        };
        const entry = &queue.items[index];
        const notice = entry.notice(false);
        if (entry.poisoned) return .{ .status = .poison, .notice = notice };
        if (self.activeQueuedCountLocked() >= self.config.capacity) {
            return .{ .status = .retained, .notice = notice };
        }

        // A replay is a new delivery window, so renew the original TTL clock.
        entry.message.metadata.timestamp = compat.milliTimestamp();
        try self.appendActiveLocked(entry.message, false);
        _ = queue.orderedRemove(index);
        self.stats.dead_letters_replayed +|= 1;
        return .{ .status = .replayed, .notice = notice };
    }

    /// Discard and deinitialize one dead-letter entry.
    pub fn discardDeadLetter(self: *ProcessMailbox, id: u64) ?DeadLetterNotice {
        self.mutex.lock();
        defer self.mutex.unlock();

        const queue = if (self.deadletter_queue) |*deadletters| deadletters else return null;
        const index = findDeadLetterIndex(queue.items, id) orelse return null;
        var entry = queue.orderedRemove(index);
        const notice = entry.notice(false);
        if (entry.poisoned) self.current_poison_count -|= 1;
        entry.deinit();
        self.stats.dead_letters_discarded +|= 1;
        return notice;
    }

    /// Discard and deinitialize every retained dead-letter entry.
    pub fn discardAllDeadLetters(self: *ProcessMailbox) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        const queue = if (self.deadletter_queue) |*deadletters| deadletters else return 0;
        const discarded = queue.items.len;
        for (queue.items) |*entry| entry.deinit();
        queue.clearRetainingCapacity();
        self.current_poison_count = 0;
        self.stats.dead_letters_discarded +|= discarded;
        return discarded;
    }

    /// Receive the next message with priority handling.
    ///
    /// The caller owns the returned message and must call `deinit()`.
    pub fn receive(self: *ProcessMailbox) MessageError!Message {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.receiveLocked();
    }

    /// Receive the next message, sleeping until one arrives or `timeout_ms`
    /// elapses.
    ///
    /// Unlike polling `receive()` in a loop, the calling thread parks on a
    /// condition that senders signal, so an idle receiver wakes as soon as a
    /// message is enqueued. Returns `error.EmptyMailbox` on timeout. External
    /// wrappers that close over this mailbox must call `wakeWaiters()` during
    /// their shutdown sequence to release parked receivers promptly.
    pub fn receiveWait(self: *ProcessMailbox, timeout_ms: u32) MessageError!Message {
        const deadline_ms = compat.monotonicMilliTimestamp() +| @as(i64, timeout_ms);

        self.mutex.lock();
        defer self.mutex.unlock();

        while (true) {
            if (self.receiveLocked()) |msg| {
                return msg;
            } else |err| switch (err) {
                MessageError.EmptyMailbox => {},
                else => return err,
            }

            const remaining_ms = deadline_ms - compat.monotonicMilliTimestamp();
            if (remaining_ms <= 0) return MessageError.EmptyMailbox;
            self.not_empty.timedWait(
                &self.mutex,
                @as(u64, @intCast(remaining_ms)) * std.time.ns_per_ms,
            ) catch return MessageError.EmptyMailbox;
        }
    }

    /// Wake every receiver parked in `receiveWait()`.
    ///
    /// Used by owners during shutdown so blocked receivers re-check their
    /// closed state instead of sleeping out their timeout.
    pub fn wakeWaiters(self: *ProcessMailbox) void {
        self.not_empty.broadcast();
    }

    /// Receive up to `buffer.len` messages under one lock and one expiry
    /// sweep, in delivery order.
    ///
    /// Nonblocking: returns the number of messages written to `buffer`, which
    /// is zero when the mailbox is empty. The caller owns every returned
    /// message and must deinitialize each one.
    pub fn receiveBatch(self: *ProcessMailbox, buffer: []Message) usize {
        if (buffer.len == 0) return 0;

        self.mutex.lock();
        defer self.mutex.unlock();

        const now_ms = compat.milliTimestamp();
        var written: usize = 0;

        if (self.priority_queues) |*queues| {
            for (queues) |*queue| {
                while (written < buffer.len) {
                    const taken = self.takeFreshFrontLocked(queue, now_ms) orelse break;
                    buffer[written] = self.markDeliveredLocked(taken);
                    written += 1;
                }
                if (written == buffer.len) break;
            }
            return written;
        }

        while (written < buffer.len) {
            const taken = self.takeFreshFrontLocked(&self.messages, now_ms) orelse break;
            buffer[written] = self.markDeliveredLocked(taken);
            written += 1;
        }
        return written;
    }

    fn markDeliveredLocked(self: *ProcessMailbox, msg: Message) Message {
        var delivered = msg;
        delivered.metadata.attempt_count +|= 1;
        self.stats.messages_sent +|= 1;
        self.stats.total_size_bytes -|= delivered.metadata.size_bytes;
        return delivered;
    }

    fn receiveLocked(self: *ProcessMailbox) MessageError!Message {
        // Expiry is lazy: only queue heads are checked here, so a receive
        // costs O(1) regardless of queue depth. Expired messages deeper in
        // the queue are reaped when they reach the head, or in bulk when a
        // send finds the mailbox at capacity.
        const now_ms = compat.milliTimestamp();

        if (self.priority_queues) |*queues| {
            for (queues) |*queue| {
                if (self.takeFreshFrontLocked(queue, now_ms)) |taken| {
                    return self.markDeliveredLocked(taken);
                }
            }
            return MessageError.EmptyMailbox;
        }

        const taken = self.takeFreshFrontLocked(&self.messages, now_ms) orelse
            return MessageError.EmptyMailbox;
        return self.markDeliveredLocked(taken);
    }

    /// Pop the first non-expired message from `queue`, reaping any expired
    /// messages encountered at the head. Returns null when the queue has no
    /// fresh message.
    fn takeFreshFrontLocked(self: *ProcessMailbox, queue: *RingQueue(Message), now_ms: i64) ?Message {
        while (queue.peekFront()) |front| {
            if (!front.isExpiredAt(now_ms)) {
                return queue.popFront().?;
            }
            const expired = queue.popFront().?;
            self.stats.messages_expired +|= 1;
            self.stats.total_size_bytes -|= expired.metadata.size_bytes;
            expired.deinit();
        }
        return null;
    }

    fn expireAllLocked(self: *ProcessMailbox, now_ms: i64) void {
        if (self.priority_queues) |*queues| {
            for (queues) |*queue| {
                self.expireQueueLocked(queue, now_ms);
            }
        } else {
            self.expireQueueLocked(&self.messages, now_ms);
        }
    }

    fn expireQueueLocked(self: *ProcessMailbox, queue: *RingQueue(Message), now_ms: i64) void {
        var i: usize = 0;
        while (i < queue.len()) {
            if (queue.at(i).isExpiredAt(now_ms)) {
                const msg = queue.removeAt(i);
                self.stats.messages_expired +|= 1;
                self.stats.total_size_bytes -|= msg.metadata.size_bytes;
                msg.deinit();
            } else {
                i += 1;
            }
        }
    }

    /// Drop and deinitialize the oldest active message without delivering it.
    ///
    /// Returns false when the mailbox is empty. This is used by send-side
    /// backpressure and does not increment delivery-attempt or sent counters.
    pub fn dropOldest(self: *ProcessMailbox) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        var dropped: Message = undefined;
        if (self.priority_queues) |*queues| {
            var selected_queue: ?usize = null;
            var oldest_timestamp: i64 = std.math.maxInt(i64);
            for (queues, 0..) |*queue, index| {
                if (queue.peekFront()) |front| {
                    if (front.metadata.timestamp < oldest_timestamp) {
                        selected_queue = index;
                        oldest_timestamp = front.metadata.timestamp;
                    }
                }
            }
            const index = selected_queue orelse return false;
            dropped = queues[index].popFront().?;
        } else {
            dropped = self.messages.popFront() orelse return false;
        }

        self.stats.messages_dropped +|= 1;
        self.stats.total_size_bytes -|= dropped.metadata.size_bytes;
        dropped.deinit();
        return true;
    }

    /// Return a snapshot of mailbox statistics.
    pub fn getStats(self: *ProcessMailbox) MailboxStats {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.stats;
    }

    /// Return the current number of queued messages.
    ///
    /// Expiry is lazy, so the count may include expired messages that have
    /// not yet been reaped by a receive or an at-capacity send.
    pub fn queuedCount(self: *ProcessMailbox) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.activeQueuedCountLocked();
    }

    /// Capture an owned snapshot of active queued messages without consuming
    /// them.
    ///
    /// Entries appear in delivery order: priority queues are listed highest
    /// priority first, matching what `receive()` would return next. Payload
    /// bytes are not copied; only scalar metadata and copied identity strings
    /// are captured. The caller owns the snapshot and must call `deinit()`.
    pub fn snapshotQueue(self: *ProcessMailbox, allocator: Allocator) !MailboxQueueSnapshot {
        self.mutex.lock();
        defer self.mutex.unlock();

        const total = self.activeQueuedCountLocked();
        const entries = try allocator.alloc(QueuedMessageSnapshot, total);
        errdefer allocator.free(entries);

        var written: usize = 0;
        errdefer for (entries[0..written]) |entry| {
            allocator.free(entry.id);
            allocator.free(entry.sender);
        };

        const now_ms = compat.milliTimestamp();
        if (self.priority_queues) |*queues| {
            for (queues) |*queue| {
                for (0..queue.len()) |i| {
                    entries[written] = try snapshotQueuedMessage(allocator, queue.at(i).*, now_ms);
                    written += 1;
                }
            }
        } else {
            for (0..self.messages.len()) |i| {
                entries[written] = try snapshotQueuedMessage(allocator, self.messages.at(i).*, now_ms);
                written += 1;
            }
        }

        return .{
            .allocator = allocator,
            .entries = entries,
        };
    }

    fn snapshotQueuedMessage(allocator: Allocator, msg: Message, now_ms: i64) !QueuedMessageSnapshot {
        const id_copy = try allocator.dupe(u8, msg.id);
        errdefer allocator.free(id_copy);
        const sender_copy = try allocator.dupe(u8, msg.sender);

        return .{
            .id = id_copy,
            .sender = sender_copy,
            .priority = msg.priority,
            .signal = msg.signal,
            .payload_len = if (msg.payload) |payload| payload.len else 0,
            .attempt_count = msg.metadata.attempt_count,
            .timestamp_ms = msg.metadata.timestamp,
            .ttl_ms = msg.metadata.ttl_ms,
            .expired = msg.isExpiredAt(now_ms),
        };
    }

    fn activeQueuedCountLocked(self: *ProcessMailbox) usize {
        if (self.priority_queues) |*queues| {
            var total: usize = 0;
            for (queues) |*queue| total +|= queue.len();
            return total;
        }
        return self.messages.len();
    }

    fn appendActiveLocked(self: *ProcessMailbox, msg: Message, count_received: bool) MessageError!void {
        if (self.priority_queues) |*queues| {
            queues[msg.priority.toInt()].pushBack(self.allocator, msg) catch return MessageError.OutOfMemory;
        } else {
            self.messages.pushBack(self.allocator, msg) catch return MessageError.OutOfMemory;
        }
        if (count_received) self.stats.messages_received +|= 1;
        self.stats.total_size_bytes +|= msg.metadata.size_bytes;
        self.stats.peak_usage = @max(self.stats.peak_usage, self.activeQueuedCountLocked());
        self.not_empty.signal();
    }

    fn appendDeadLetterLocked(
        self: *ProcessMailbox,
        msg: Message,
        requested_reason: DeadLetterReason,
    ) MessageError!DeadLetterNotice {
        const queue = if (self.deadletter_queue) |*deadletters| deadletters else return MessageError.DeliveryFailed;
        if (queue.items.len >= self.config.dead_letter_capacity) return MessageError.DeadLetterFull;

        const attempt_limit = @max(@as(u32, 1), self.config.max_delivery_attempts);
        const poisoned = requested_reason == .max_attempts or
            (requested_reason == .delivery_failed and msg.metadata.attempt_count >= attempt_limit);
        const reason: DeadLetterReason = if (poisoned) .max_attempts else requested_reason;
        const id = self.next_dead_letter_id;
        self.next_dead_letter_id +%= 1;
        if (self.next_dead_letter_id == 0) self.next_dead_letter_id = 1;

        const entry: DeadLetterEntry = .{
            .id = id,
            .message = msg,
            .reason = reason,
            .dead_lettered_at_ms = compat.milliTimestamp(),
            .poisoned = poisoned,
        };
        queue.append(self.allocator, entry) catch return MessageError.OutOfMemory;
        self.stats.messages_dead_lettered +|= 1;
        if (poisoned) {
            self.stats.poison_messages +|= 1;
            self.current_poison_count +|= 1;
        }
        return entry.notice(poisoned);
    }

    fn findDeadLetterIndex(entries: []const DeadLetterEntry, id: u64) ?usize {
        for (entries, 0..) |entry, index| {
            if (entry.id == id) return index;
        }
        return null;
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
    mailbox.messages.at(0).metadata.timestamp -= 2_000;

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

test "Message metadata replacement preserves old values on allocation failure" {
    var correlation_allocator = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 2 });
    var correlation_message = try Message.init(
        correlation_allocator.allocator(),
        "id",
        "sender",
        "payload",
        null,
        .normal,
        null,
    );
    defer correlation_message.deinit();
    try correlation_message.setCorrelationId("old-correlation");
    try testing.expectError(error.OutOfMemory, correlation_message.setCorrelationId("new-correlation"));
    try testing.expectEqualStrings("old-correlation", correlation_message.metadata.correlation_id.?);

    var reply_allocator = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 2 });
    var reply_message = try Message.init(
        reply_allocator.allocator(),
        "id",
        "sender",
        "payload",
        null,
        .normal,
        null,
    );
    defer reply_message.deinit();
    try reply_message.setReplyTo("old-reply");
    try testing.expectError(error.OutOfMemory, reply_message.setReplyTo("new-reply"));
    try testing.expectEqualStrings("old-reply", reply_message.metadata.reply_to.?);
}

test "Message size tracks owned metadata and response id replacement" {
    const allocator = testing.allocator;
    var message = try Message.init(allocator, "id", "sender", "payload", null, .normal, null);
    defer message.deinit();

    try testing.expectEqual(@as(usize, 15), message.metadata.size_bytes);
    try message.setCorrelationId("corr");
    try testing.expectEqual(@as(usize, 19), message.metadata.size_bytes);
    try message.setCorrelationId("c2");
    try testing.expectEqual(@as(usize, 17), message.metadata.size_bytes);
    try message.setReplyTo("reply");
    try testing.expectEqual(@as(usize, 22), message.metadata.size_bytes);
    try message.setReplyTo("r");
    try testing.expectEqual(@as(usize, 18), message.metadata.size_bytes);

    var response = try message.createResponse(allocator, "ok", .info);
    defer response.deinit();
    const expected_response_size = response.id.len + response.sender.len + response.payload.?.len +
        response.metadata.correlation_id.?.len;
    try testing.expectEqual(expected_response_size, response.metadata.size_bytes);
}

test "Mailbox message-size limit includes correlation and reply metadata" {
    const allocator = testing.allocator;
    var mailbox = ProcessMailbox.init(allocator, .{
        .capacity = 1,
        .max_message_size = 16,
        .enable_deadletter = false,
    });
    defer mailbox.deinit();

    var message = try Message.init(allocator, "id", "sender", "payload", null, .normal, null);
    try message.setCorrelationId("extra");
    try testing.expect(message.metadata.size_bytes > 16);
    try testing.expectError(MessageError.MessageTooLarge, mailbox.send(message));
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

test "ProcessMailbox queuedCount reports actual queued messages" {
    const allocator = testing.allocator;
    var mailbox = ProcessMailbox.init(allocator, .{
        .capacity = 4,
        .priority_queues = true,
    });
    defer mailbox.deinit();

    try mailbox.send(try Message.init(allocator, "a", "sender", "one", null, .normal, null));
    try mailbox.send(try Message.init(allocator, "b", "sender", "two", null, .high, null));
    try testing.expectEqual(@as(usize, 2), mailbox.queuedCount());

    var received = try mailbox.receive();
    defer received.deinit();
    try testing.expectEqual(@as(usize, 1), mailbox.queuedCount());
}

test "ProcessMailbox retains overflow in bounded dead-letter storage" {
    const allocator = testing.allocator;
    var mailbox = ProcessMailbox.init(allocator, .{
        .capacity = 1,
        .priority_queues = false,
        .dead_letter_capacity = 1,
    });
    defer mailbox.deinit();

    try mailbox.send(try Message.init(allocator, "active", "sender", "one", null, .normal, null));
    const overflow = try mailbox.sendWithDisposition(
        try Message.init(allocator, "overflow", "sender", "two", null, .normal, null),
    );
    const first_notice = switch (overflow) {
        .enqueued => return error.ExpectedDeadLetter,
        .dead_lettered => |notice| notice,
    };
    try testing.expectEqual(@as(u64, 1), first_notice.id);
    try testing.expectEqual(DeadLetterReason.mailbox_full, first_notice.reason);
    try testing.expectEqual(@as(usize, 1), mailbox.deadLetterCount());

    try testing.expectError(
        MessageError.DeadLetterFull,
        mailbox.send(try Message.init(allocator, "overflow-2", "sender", "three", null, .normal, null)),
    );
    const stats = mailbox.getStats();
    try testing.expectEqual(@as(usize, 1), stats.messages_dead_lettered);
    try testing.expectEqual(@as(usize, 1), stats.messages_dropped);
}

test "ProcessMailbox snapshots replays and discards dead letters" {
    const allocator = testing.allocator;
    var mailbox = ProcessMailbox.init(allocator, .{
        .capacity = 1,
        .priority_queues = true,
        .dead_letter_capacity = 4,
    });
    defer mailbox.deinit();

    try mailbox.send(try Message.init(allocator, "active", "sender", "one", null, .low, null));
    try mailbox.send(try Message.init(allocator, "retained", "sender", "two", null, .critical, null));

    var snapshot = try mailbox.snapshotDeadLetters(allocator);
    defer snapshot.deinit();
    try testing.expectEqual(@as(usize, 1), snapshot.entries.len);
    try testing.expectEqualStrings("retained", snapshot.entries[0].message.id);
    const dead_letter_id = snapshot.entries[0].id;

    const retained = try mailbox.replayDeadLetter(dead_letter_id);
    try testing.expectEqual(DeadLetterReplayStatus.retained, retained.status);

    var active = try mailbox.receive();
    active.deinit();
    const replayed = try mailbox.replayDeadLetter(dead_letter_id);
    try testing.expectEqual(DeadLetterReplayStatus.replayed, replayed.status);
    try testing.expectEqual(@as(usize, 0), mailbox.deadLetterCount());

    var delivered = try mailbox.receive();
    defer delivered.deinit();
    try testing.expectEqualStrings("retained", delivered.id);
    try testing.expectEqual(@as(u32, 1), delivered.metadata.attempt_count);

    try testing.expectEqual(@as(usize, 0), mailbox.discardAllDeadLetters());
    const stats = mailbox.getStats();
    try testing.expectEqual(@as(usize, 1), stats.dead_letters_replayed);
}

test "ProcessMailbox classifies repeatedly rejected delivery as poison" {
    const allocator = testing.allocator;
    var mailbox = ProcessMailbox.init(allocator, .{
        .capacity = 1,
        .dead_letter_capacity = 4,
        .max_delivery_attempts = 2,
    });
    defer mailbox.deinit();

    try mailbox.send(try Message.init(allocator, "job", "sender", "work", null, .normal, null));
    const first_attempt = try mailbox.receive();
    const first_dead_letter = try mailbox.deadLetter(first_attempt, .delivery_failed);
    try testing.expect(!first_dead_letter.poisoned);

    const first_replay = try mailbox.replayDeadLetter(first_dead_letter.id);
    try testing.expectEqual(DeadLetterReplayStatus.replayed, first_replay.status);
    const second_attempt = try mailbox.receive();
    const poison = try mailbox.deadLetter(second_attempt, .delivery_failed);
    try testing.expect(poison.poisoned);
    try testing.expect(poison.newly_poisoned);
    try testing.expectEqual(DeadLetterReason.max_attempts, poison.reason);

    const poison_replay = try mailbox.replayDeadLetter(poison.id);
    try testing.expectEqual(DeadLetterReplayStatus.poison, poison_replay.status);
    try testing.expect(mailbox.discardDeadLetter(poison.id) != null);
    try testing.expectEqual(@as(usize, 0), mailbox.deadLetterCount());

    const stats = mailbox.getStats();
    try testing.expectEqual(@as(usize, 1), stats.poison_messages);
    try testing.expectEqual(@as(usize, 1), stats.dead_letters_discarded);
}

test "ProcessMailbox serializes concurrent replay and discard" {
    const allocator = std.heap.smp_allocator;
    var mailbox = ProcessMailbox.init(allocator, .{
        .capacity = 1,
        .dead_letter_capacity = 4,
    });
    defer mailbox.deinit();

    try mailbox.send(try Message.init(allocator, "active", "sender", "one", null, .normal, null));
    const overflow = try mailbox.sendWithDisposition(
        try Message.init(allocator, "overflow", "sender", "two", null, .normal, null),
    );
    const id = switch (overflow) {
        .enqueued => return error.ExpectedDeadLetter,
        .dead_lettered => |notice| notice.id,
    };
    var active = try mailbox.receive();
    active.deinit();

    const Context = struct {
        target: *ProcessMailbox,
        id: u64,
    };
    const replay = struct {
        fn run(context: Context) void {
            _ = context.target.replayDeadLetter(context.id) catch return;
        }
    }.run;
    const discard = struct {
        fn run(context: Context) void {
            _ = context.target.discardDeadLetter(context.id);
        }
    }.run;
    const context = Context{ .target = &mailbox, .id = id };
    const replay_thread = try std.Thread.spawn(.{}, replay, .{context});
    const discard_thread = try std.Thread.spawn(.{}, discard, .{context});
    replay_thread.join();
    discard_thread.join();

    try testing.expect(mailbox.deadLetterCount() + mailbox.queuedCount() <= 1);
    if (mailbox.receive()) |message| {
        var owned = message;
        owned.deinit();
    } else |err| try testing.expectEqual(MessageError.EmptyMailbox, err);
    const stats = mailbox.getStats();
    try testing.expectEqual(@as(usize, 1), stats.dead_letters_replayed + stats.dead_letters_discarded);
}

test "ProcessMailbox snapshotQueue reports queued messages without consuming" {
    const allocator = testing.allocator;
    var mailbox = ProcessMailbox.init(allocator, .{ .capacity = 8 });
    defer mailbox.deinit();

    const normal = try Message.init(allocator, "normal-msg", "worker", "payload", null, .normal, null);
    try mailbox.send(normal);
    const critical = try Message.init(allocator, "critical-msg", "worker", null, .healthCheck, .critical, 5_000);
    try mailbox.send(critical);

    var snapshot = try mailbox.snapshotQueue(allocator);
    defer snapshot.deinit();

    try testing.expectEqual(@as(usize, 2), snapshot.entries.len);
    // Delivery order: critical priority is listed before normal.
    try testing.expectEqualStrings("critical-msg", snapshot.entries[0].id);
    try testing.expectEqual(MessagePriority.critical, snapshot.entries[0].priority);
    try testing.expectEqual(Signal.healthCheck, snapshot.entries[0].signal.?);
    try testing.expectEqual(@as(usize, 0), snapshot.entries[0].payload_len);
    try testing.expectEqual(@as(?u32, 5_000), snapshot.entries[0].ttl_ms);
    try testing.expect(!snapshot.entries[0].expired);

    try testing.expectEqualStrings("normal-msg", snapshot.entries[1].id);
    try testing.expectEqualStrings("worker", snapshot.entries[1].sender);
    try testing.expectEqual(@as(usize, "payload".len), snapshot.entries[1].payload_len);

    // Nothing was consumed.
    try testing.expectEqual(@as(usize, 2), mailbox.queuedCount());
    var received = try mailbox.receive();
    defer received.deinit();
    try testing.expectEqualStrings("critical-msg", received.id);
}

test {
    _ = @import("ring_queue.zig");
}

test "ProcessMailbox lazy expiry skips stale messages at delivery time" {
    const allocator = testing.allocator;
    var mailbox = ProcessMailbox.init(allocator, .{
        .capacity = 8,
        .priority_queues = false,
        .default_ttl_ms = null,
    });
    defer mailbox.deinit();

    const stale = try Message.init(allocator, "stale", "sender", "old", null, .normal, 1_000);
    try mailbox.send(stale);
    const fresh = try Message.init(allocator, "fresh", "sender", "new", null, .normal, null);
    try mailbox.send(fresh);

    // Expire the queued head in place; it is reaped when it reaches the head.
    mailbox.messages.at(0).metadata.timestamp -= 10_000;
    try testing.expectEqual(@as(usize, 2), mailbox.queuedCount());

    var received = try mailbox.receive();
    defer received.deinit();
    try testing.expectEqualStrings("fresh", received.id);
    try testing.expectEqual(@as(usize, 1), mailbox.getStats().messages_expired);
    try testing.expectEqual(@as(usize, 0), mailbox.queuedCount());
}

test "ProcessMailbox reclaims expired messages when a send finds it full" {
    const allocator = testing.allocator;
    var mailbox = ProcessMailbox.init(allocator, .{
        .capacity = 2,
        .priority_queues = false,
        .enable_deadletter = false,
        .default_ttl_ms = null,
    });
    defer mailbox.deinit();

    const first = try Message.init(allocator, "first", "sender", "a", null, .normal, 1_000);
    try mailbox.send(first);
    const second = try Message.init(allocator, "second", "sender", "b", null, .normal, 1_000);
    try mailbox.send(second);
    try testing.expectEqual(@as(usize, 2), mailbox.queuedCount());

    // Both queued messages expire; the mailbox looks full until a send
    // triggers the reclaim sweep.
    mailbox.messages.at(0).metadata.timestamp -= 10_000;
    mailbox.messages.at(1).metadata.timestamp -= 10_000;

    const fresh = try Message.init(allocator, "fresh", "sender", "c", null, .normal, null);
    try mailbox.send(fresh);

    try testing.expectEqual(@as(usize, 1), mailbox.queuedCount());
    try testing.expectEqual(@as(usize, 2), mailbox.getStats().messages_expired);

    var received = try mailbox.receive();
    defer received.deinit();
    try testing.expectEqualStrings("fresh", received.id);
}
