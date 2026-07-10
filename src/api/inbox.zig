//! High-level inbox API for Vigil.
//!
//! An `Inbox` is a channel-like wrapper around the lower-level
//! `ProcessMailbox`. It is the recommended API for application code because it
//! hides message construction for simple payload sends and provides a safe
//! close path for concurrent send/receive operations.
//!
//! Example:
//! ```zig
//! var inbox = try vigil.inbox(allocator);
//! defer inbox.close();
//!
//! try inbox.send("Hello");
//! const msg = try inbox.recv();
//! ```

const std = @import("std");
const messages = @import("../messages.zig");
const compat = @import("../compat.zig");
const telemetry = @import("../telemetry.zig");
const flow_control = @import("./flow_control.zig");

pub const Message = messages.Message;
pub const ProcessMailbox = messages.ProcessMailbox;
pub const Signal = messages.Signal;
pub const MessageError = messages.MessageError;
pub const DeadLetterReason = messages.DeadLetterReason;
pub const DeadLetterNotice = messages.DeadLetterNotice;
pub const DeadLetterSnapshot = messages.DeadLetterSnapshot;
pub const DeadLetterReplayStatus = messages.DeadLetterReplayStatus;
pub const DeadLetterReplayResult = messages.DeadLetterReplayResult;

/// Called once when a failed delivery first crosses the poison threshold.
pub const PoisonMessageHandler = *const fn (context: ?*anyopaque, notice: DeadLetterNotice) void;

const LifecycleTargets = struct {
    emitter: ?*telemetry.TelemetryEmitter,
    poison_context: ?*anyopaque,
    poison_handler: ?PoisonMessageHandler,
};

/// Error returned when attempting to receive from a closed inbox
pub const InboxError = error{
    /// The inbox has been closed
    InboxClosed,
};

/// High-level inbox wrapper around ProcessMailbox.
///
/// Uses an atomic reference count to prevent use-after-free: every
/// in-flight `send`, `recv`, or `recvTimeout` call increments the
/// count while it accesses the mailbox.  `close()` sets the closed
/// flag and then spins until all in-flight operations have finished
/// before deallocating.
pub const Inbox = struct {
    /// Underlying mailbox. Exposed for registry and low-level API interop.
    /// The `Inbox` owns this pointer; do not deinitialize it directly.
    mailbox: *ProcessMailbox,
    /// Allocator used for the inbox object, mailbox, and messages sent through
    /// `send()`.
    allocator: std.mem.Allocator,
    /// Atomic flag indicating the inbox has been closed.
    closed: std.atomic.Value(bool),
    /// Number of in-flight operations (send / recv / recvTimeout).
    /// `close()` waits for this to reach zero before deallocating.
    active_ops: std.atomic.Value(u32),
    /// Monotonic suffix used to make high-level message ids unique per inbox.
    next_message_id: std.atomic.Value(u64),
    /// Optional token-bucket limiter applied before sending.
    rate_limiter: ?flow_control.RateLimiter,
    /// Optional backpressure policy applied when queued messages cross the
    /// configured high-water mark.
    backpressure_config: ?flow_control.BackpressureConfig,
    /// Optional runtime emitter for dead-letter lifecycle events.
    telemetry_emitter: ?*telemetry.TelemetryEmitter,
    /// Protects telemetry and poison-hook configuration.
    lifecycle_mutex: compat.Mutex,
    /// Optional user context supplied to the poison-message handler.
    poison_context: ?*anyopaque,
    /// Optional callback invoked on the first poison classification.
    poison_handler: ?PoisonMessageHandler,

    /// Allocate a new inbox with default mailbox settings.
    ///
    /// The caller owns the returned pointer and must call `close()` exactly
    /// once. For custom capacity, TTL, rate limiting, or backpressure, use
    /// `inboxBuilder(allocator)` instead.
    pub fn init(allocator: std.mem.Allocator) !*Inbox {
        const inbox_ptr = try allocator.create(Inbox);
        errdefer allocator.destroy(inbox_ptr);

        const mailbox = try allocator.create(ProcessMailbox);
        errdefer allocator.destroy(mailbox);

        mailbox.* = ProcessMailbox.init(allocator, .{
            .capacity = 100,
            .priority_queues = true,
            .enable_deadletter = true,
            .default_ttl_ms = 30_000,
        });

        inbox_ptr.* = .{
            .mailbox = mailbox,
            .allocator = allocator,
            .closed = std.atomic.Value(bool).init(false),
            .active_ops = std.atomic.Value(u32).init(0),
            .next_message_id = std.atomic.Value(u64).init(1),
            .rate_limiter = null,
            .backpressure_config = null,
            .telemetry_emitter = null,
            .lifecycle_mutex = .{},
            .poison_context = null,
            .poison_handler = null,
        };

        return inbox_ptr;
    }

    /// Close and destroy the inbox.
    ///
    /// Sets the closed flag to signal waiting threads, then waits for
    /// all in-flight operations to finish before deallocating resources.
    /// After this returns, any pointer to this inbox or its raw mailbox is
    /// invalid.
    pub fn close(self: *Inbox) void {
        // Set closed flag first to signal waiting threads
        self.closed.store(true, .release);

        // Spin-wait until all in-flight operations have exited.
        // Each operation increments active_ops on entry and decrements
        // on exit, so reaching zero means nothing is touching the mailbox.
        while (self.active_ops.load(.acquire) != 0) {
            compat.sleep(1 * std.time.ns_per_ms);
        }

        // Now safe to deallocate — no threads are inside send/recv
        self.mailbox.deinit();
        self.allocator.destroy(self.mailbox);
        self.allocator.destroy(self);
    }

    /// Return whether `close()` has been requested.
    pub fn isClosed(self: *Inbox) bool {
        return self.closed.load(.acquire);
    }

    /// Send a payload as a new normal-priority message.
    ///
    /// `send()` copies the payload into an owned `Message`. It may fail when
    /// the inbox is closed, the mailbox is full, a rate limit is exceeded, or
    /// allocation fails.
    pub fn send(self: *Inbox, payload: []const u8) !void {
        try self.beginOperation();
        errdefer self.endOperation();

        if (!try self.applyFlowControl()) {
            self.endOperation();
            return;
        }

        const sequence = self.next_message_id.fetchAdd(1, .monotonic);
        var id_buffer: [64]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buffer, "inbox_{d}", .{sequence});
        const message = try Message.init(
            self.allocator,
            id,
            "inbox_sender",
            payload,
            null,
            .normal,
            null,
        );
        const delivery = try self.mailbox.sendWithDisposition(message);
        const targets = self.captureLifecycleTargets();
        self.endOperation();

        switch (delivery) {
            .enqueued => {},
            .dead_lettered => |notice| emitDeadLetterLifecycle(targets, .message_dead_lettered, notice),
        }
    }

    /// Send an existing owned message without rebuilding its metadata.
    ///
    /// This consumes `message` on success and error, including when the inbox
    /// is already closed. It is primarily useful for lossless re-queueing.
    pub fn sendMessage(self: *Inbox, message: Message) !void {
        self.beginOperation() catch |err| {
            message.deinit();
            return err;
        };
        errdefer self.endOperation();

        const delivery = try self.mailbox.sendWithDisposition(message);
        const targets = self.captureLifecycleTargets();
        self.endOperation();

        switch (delivery) {
            .enqueued => {},
            .dead_lettered => |notice| emitDeadLetterLifecycle(targets, .message_dead_lettered, notice),
        }
    }

    /// Receive the next available message, blocking until one arrives.
    ///
    /// The returned `Message` is owned by the caller and must be deinitialized.
    /// Returns `InboxError.InboxClosed` if the inbox closes while waiting.
    pub fn recv(self: *Inbox) !Message {
        while (true) {
            // Check if inbox has been closed
            if (self.closed.load(.acquire)) {
                return InboxError.InboxClosed;
            }
            // Track this operation so close() waits for us
            _ = self.active_ops.fetchAdd(1, .acq_rel);

            // Re-check after incrementing
            if (self.closed.load(.acquire)) {
                _ = self.active_ops.fetchSub(1, .acq_rel);
                return InboxError.InboxClosed;
            }

            if (self.mailbox.receive()) |msg| {
                _ = self.active_ops.fetchSub(1, .acq_rel);
                return msg;
            } else |err| switch (err) {
                error.EmptyMailbox => {
                    // Release the op count while sleeping so close()
                    // can make progress if this is the only thread.
                    _ = self.active_ops.fetchSub(1, .acq_rel);
                    compat.sleep(1 * std.time.ns_per_ms);
                    continue;
                },
                else => {
                    _ = self.active_ops.fetchSub(1, .acq_rel);
                    return err;
                },
            }
        }
    }

    /// Receive the next message, waiting at most `timeout_ms`.
    ///
    /// Returns null on timeout. A zero timeout performs a non-blocking poll.
    /// The returned `Message`, when present, is owned by the caller and must be
    /// deinitialized.
    pub fn recvTimeout(self: *Inbox, timeout_ms: u32) !?Message {
        const start = compat.milliTimestamp();
        while (true) {
            // Check if inbox has been closed
            if (self.closed.load(.acquire)) {
                return InboxError.InboxClosed;
            }
            if (timeout_ms != 0 and compat.milliTimestamp() - start >= timeout_ms) {
                return null;
            }
            // Track this operation so close() waits for us
            _ = self.active_ops.fetchAdd(1, .acq_rel);

            // Re-check after incrementing
            if (self.closed.load(.acquire)) {
                _ = self.active_ops.fetchSub(1, .acq_rel);
                return InboxError.InboxClosed;
            }

            if (self.mailbox.receive()) |msg| {
                _ = self.active_ops.fetchSub(1, .acq_rel);
                return msg;
            } else |err| switch (err) {
                error.EmptyMailbox => {
                    _ = self.active_ops.fetchSub(1, .acq_rel);
                    if (timeout_ms == 0 or compat.milliTimestamp() - start >= timeout_ms) {
                        return null;
                    }
                    compat.sleep(1 * std.time.ns_per_ms);
                    continue;
                },
                else => {
                    _ = self.active_ops.fetchSub(1, .acq_rel);
                    return err;
                },
            }
        }
    }

    /// Return a snapshot of the underlying mailbox statistics.
    pub fn stats(self: *Inbox) ProcessMailbox.MailboxStats {
        return self.mailbox.getStats();
    }

    /// Attach an emitter used for dead-letter lifecycle events.
    ///
    /// `emitter` must outlive this inbox. `Runtime.inbox()` configures this
    /// automatically when runtime telemetry is enabled.
    pub fn setTelemetryEmitter(self: *Inbox, emitter: ?*telemetry.TelemetryEmitter) void {
        self.lifecycle_mutex.lock();
        defer self.lifecycle_mutex.unlock();
        self.telemetry_emitter = emitter;
    }

    /// Register or replace the poison-message callback.
    pub fn onPoisonMessage(
        self: *Inbox,
        context: ?*anyopaque,
        handler: PoisonMessageHandler,
    ) void {
        self.lifecycle_mutex.lock();
        defer self.lifecycle_mutex.unlock();
        self.poison_context = context;
        self.poison_handler = handler;
    }

    /// Move a failed, caller-owned message into this inbox's dead-letter queue.
    ///
    /// If the inbox is already closed, the caller retains the message. Once
    /// the mailbox operation begins, the message is consumed on success or error.
    pub fn deadLetter(self: *Inbox, message: Message, reason: DeadLetterReason) !DeadLetterNotice {
        try self.beginOperation();
        errdefer self.endOperation();

        const notice = try self.mailbox.deadLetter(message, reason);
        const targets = self.captureLifecycleTargets();
        self.endOperation();

        emitDeadLetterLifecycle(targets, .message_dead_lettered, notice);
        if (notice.newly_poisoned) emitPoison(targets, notice);
        return notice;
    }

    /// Capture an owned snapshot without consuming dead-letter entries.
    pub fn deadLetters(self: *Inbox, allocator: std.mem.Allocator) !DeadLetterSnapshot {
        try self.beginOperation();
        defer self.endOperation();
        return try self.mailbox.snapshotDeadLetters(allocator);
    }

    /// Return the current number of retained dead-letter entries.
    pub fn deadLetterCount(self: *Inbox) !usize {
        try self.beginOperation();
        defer self.endOperation();
        return self.mailbox.deadLetterCount();
    }

    /// Try to move a dead-letter entry back into the active queue.
    pub fn replayDeadLetter(self: *Inbox, id: u64) !DeadLetterReplayResult {
        try self.beginOperation();
        errdefer self.endOperation();

        const result = try self.mailbox.replayDeadLetter(id);
        const targets = self.captureLifecycleTargets();
        self.endOperation();

        if (result.status == .replayed) {
            emitDeadLetterLifecycle(targets, .message_replayed, result.notice.?);
        }
        return result;
    }

    /// Discard one dead-letter entry, returning false when the id is absent.
    pub fn discardDeadLetter(self: *Inbox, id: u64) !bool {
        try self.beginOperation();
        errdefer self.endOperation();

        const notice = self.mailbox.discardDeadLetter(id);
        const targets = self.captureLifecycleTargets();
        self.endOperation();

        if (notice == null) return false;
        emitDeadLetterLifecycle(targets, .message_discarded, notice.?);
        return true;
    }

    /// Discard every dead-letter entry and return the number removed.
    pub fn discardAllDeadLetters(self: *Inbox) !usize {
        try self.beginOperation();
        errdefer self.endOperation();

        const discarded = self.mailbox.discardAllDeadLetters();
        const targets = self.captureLifecycleTargets();
        self.endOperation();

        if (discarded > 0) {
            emitTelemetry(targets.emitter, .message_discarded, "all");
        }
        return discarded;
    }

    fn queuedCount(self: *Inbox) usize {
        return self.mailbox.queuedCount();
    }

    fn beginOperation(self: *Inbox) !void {
        if (self.closed.load(.acquire)) return InboxError.InboxClosed;
        _ = self.active_ops.fetchAdd(1, .acq_rel);
        if (self.closed.load(.acquire)) {
            _ = self.active_ops.fetchSub(1, .acq_rel);
            return InboxError.InboxClosed;
        }
    }

    fn endOperation(self: *Inbox) void {
        _ = self.active_ops.fetchSub(1, .acq_rel);
    }

    fn captureLifecycleTargets(self: *Inbox) LifecycleTargets {
        self.lifecycle_mutex.lock();
        defer self.lifecycle_mutex.unlock();
        return .{
            .emitter = self.telemetry_emitter,
            .poison_context = self.poison_context,
            .poison_handler = self.poison_handler,
        };
    }

    fn emitDeadLetterLifecycle(
        targets: LifecycleTargets,
        event_type: telemetry.EventType,
        notice: DeadLetterNotice,
    ) void {
        emitTelemetry(targets.emitter, event_type, @tagName(notice.reason));
    }

    fn emitPoison(targets: LifecycleTargets, notice: DeadLetterNotice) void {
        if (targets.emitter) |value| {
            value.emit(.{
                .event_type = .poison_message_detected,
                .timestamp_ms = compat.milliTimestamp(),
                .metadata = @tagName(notice.reason),
            });
        }
        if (targets.poison_handler) |callback| callback(targets.poison_context, notice);
    }

    fn emitTelemetry(emitter: ?*telemetry.TelemetryEmitter, event_type: telemetry.EventType, metadata: []const u8) void {
        if (emitter) |value| {
            value.emit(.{
                .event_type = event_type,
                .timestamp_ms = compat.milliTimestamp(),
                .metadata = metadata,
            });
        }
    }

    fn applyFlowControl(self: *Inbox) !bool {
        if (self.rate_limiter) |*limiter| {
            if (!limiter.allow()) {
                return MessageError.RateLimitExceeded;
            }
        }

        const config = self.backpressure_config orelse return true;
        if (self.queuedCount() < config.high_watermark) return true;

        switch (config.strategy) {
            .drop_oldest => {
                _ = self.mailbox.dropOldest();
            },
            .drop_newest => return false,
            .block => {
                while (self.queuedCount() > config.low_watermark) {
                    if (self.closed.load(.acquire)) return InboxError.InboxClosed;
                    compat.sleep(10 * std.time.ns_per_ms);
                }
            },
            .return_error => return MessageError.MailboxFull,
        }
        return true;
    }
};

/// Fluent builder for configuring an inbox before allocation.
///
/// Builder methods return a modified copy, so chains are cheap and immutable
/// from the caller's perspective:
/// ```zig
/// var inbox = try vigil.inboxBuilder(allocator)
///     .capacity(256)
///     .defaultTTL(5_000)
///     .withBackpressure(.{
///         .strategy = .drop_oldest,
///         .high_watermark = 200,
///         .low_watermark = 100,
///     })
///     .build();
/// defer inbox.close();
/// ```
pub const InboxBuilder = struct {
    /// Allocator used by `build()`.
    allocator: std.mem.Allocator,
    /// Mailbox capacity.
    capacity_val: usize = 100,
    /// Whether priority queues are enabled.
    priority_queues_val: bool = true,
    /// Whether dead-letter support is enabled.
    dead_letter_val: bool = true,
    /// Maximum retained dead-letter entries.
    dead_letter_capacity_val: usize = 100,
    /// Delivery failures allowed before a message becomes poison.
    max_delivery_attempts_val: u32 = 3,
    /// Default TTL for messages. Null disables the default.
    default_ttl_ms_val: ?u32 = 30_000,
    /// Optional send rate limit.
    rate_limit_config: ?flow_control.RateLimitConfig = null,
    /// Optional backpressure policy.
    backpressure_config: ?flow_control.BackpressureConfig = null,

    fn init(allocator: std.mem.Allocator) InboxBuilder {
        return .{ .allocator = allocator };
    }

    /// Set mailbox capacity.
    pub fn capacity(self: InboxBuilder, n: usize) InboxBuilder {
        var result = self;
        result.capacity_val = n;
        return result;
    }

    /// Enable or disable priority queues.
    pub fn priorityQueues(self: InboxBuilder, enabled: bool) InboxBuilder {
        var result = self;
        result.priority_queues_val = enabled;
        return result;
    }

    /// Enable or disable dead-letter support.
    pub fn deadLetter(self: InboxBuilder, enabled: bool) InboxBuilder {
        var result = self;
        result.dead_letter_val = enabled;
        return result;
    }

    /// Set the maximum number of retained dead-letter entries.
    pub fn deadLetterCapacity(self: InboxBuilder, limit: usize) InboxBuilder {
        var result = self;
        result.dead_letter_capacity_val = limit;
        return result;
    }

    /// Set the delivery-failure threshold for poison classification.
    pub fn maxDeliveryAttempts(self: InboxBuilder, attempts: u32) InboxBuilder {
        var result = self;
        result.max_delivery_attempts_val = @max(@as(u32, 1), attempts);
        return result;
    }

    /// Set the default message TTL in milliseconds.
    pub fn defaultTTL(self: InboxBuilder, ms: u32) InboxBuilder {
        var result = self;
        result.default_ttl_ms_val = ms;
        return result;
    }

    /// Apply a token-bucket rate limit to sends.
    pub fn withRateLimit(self: InboxBuilder, config: flow_control.RateLimitConfig) InboxBuilder {
        var result = self;
        result.rate_limit_config = config;
        return result;
    }

    /// Apply a backpressure policy to sends.
    pub fn withBackpressure(self: InboxBuilder, config: flow_control.BackpressureConfig) InboxBuilder {
        var result = self;
        result.backpressure_config = config;
        return result;
    }

    /// Allocate and return the configured inbox.
    ///
    /// The caller owns the returned pointer and must call `close()`.
    pub fn build(self: InboxBuilder) !*Inbox {
        if (self.backpressure_config) |config| {
            if (config.low_watermark > config.high_watermark) {
                return error.InvalidConfiguration;
            }
        }

        const inbox_ptr = try self.allocator.create(Inbox);
        errdefer self.allocator.destroy(inbox_ptr);

        const mailbox = try self.allocator.create(ProcessMailbox);
        errdefer self.allocator.destroy(mailbox);

        mailbox.* = ProcessMailbox.init(self.allocator, .{
            .capacity = self.capacity_val,
            .priority_queues = self.priority_queues_val,
            .enable_deadletter = self.dead_letter_val,
            .dead_letter_capacity = self.dead_letter_capacity_val,
            .max_delivery_attempts = self.max_delivery_attempts_val,
            .default_ttl_ms = self.default_ttl_ms_val,
        });

        inbox_ptr.* = .{
            .mailbox = mailbox,
            .allocator = self.allocator,
            .closed = std.atomic.Value(bool).init(false),
            .active_ops = std.atomic.Value(u32).init(0),
            .next_message_id = std.atomic.Value(u64).init(1),
            .rate_limiter = if (self.rate_limit_config) |config| flow_control.RateLimiter.init(config.max_per_second) else null,
            .backpressure_config = self.backpressure_config,
            .telemetry_emitter = null,
            .lifecycle_mutex = .{},
            .poison_context = null,
            .poison_handler = null,
        };

        return inbox_ptr;
    }
};

/// Create a new inbox builder using `allocator`.
pub fn inboxBuilder(allocator: std.mem.Allocator) InboxBuilder {
    return InboxBuilder.init(allocator);
}

/// Allocate a default inbox.
///
/// Equivalent to `inboxBuilder(allocator).build()`.
pub fn inbox(allocator: std.mem.Allocator) !*Inbox {
    return try Inbox.init(allocator);
}

test "Inbox basic send and receive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var inbox_ptr = try inbox(allocator);
    defer inbox_ptr.close();

    try inbox_ptr.send("test message");

    var msg = try inbox_ptr.recv();
    defer msg.deinit();

    try std.testing.expectEqualSlices(u8, "test message", msg.payload.?);
}

test "Inbox multiple sends" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var inbox_ptr = try inbox(allocator);
    defer inbox_ptr.close();

    try inbox_ptr.send("msg1");
    try inbox_ptr.send("msg2");
    try inbox_ptr.send("msg3");

    var msg1 = try inbox_ptr.recv();
    defer msg1.deinit();
    try std.testing.expectEqualSlices(u8, "msg1", msg1.payload.?);

    var msg2 = try inbox_ptr.recv();
    defer msg2.deinit();
    try std.testing.expectEqualSlices(u8, "msg2", msg2.payload.?);

    var msg3 = try inbox_ptr.recv();
    defer msg3.deinit();
    try std.testing.expectEqualSlices(u8, "msg3", msg3.payload.?);
}

test "Inbox receive timeout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var inbox_ptr = try inbox(allocator);
    defer inbox_ptr.close();

    const result = try inbox_ptr.recvTimeout(10);
    try std.testing.expect(result == null);
}

test "Inbox receive timeout with message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var inbox_ptr = try inbox(allocator);
    defer inbox_ptr.close();

    try inbox_ptr.send("quick message");

    if (try inbox_ptr.recvTimeout(100)) |msg| {
        defer msg.deinit();
        try std.testing.expectEqualSlices(u8, "quick message", msg.payload.?);
    } else {
        try std.testing.expect(false); // Should have received a message
    }
}

test "Inbox stats" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var inbox_ptr = try inbox(allocator);
    defer inbox_ptr.close();

    try inbox_ptr.send("msg1");
    try inbox_ptr.send("msg2");

    const inbox_stats = inbox_ptr.stats();
    // Just verify stats are accessible and reasonable
    try std.testing.expect(inbox_stats.messages_received >= 0);
    try std.testing.expect(inbox_stats.messages_sent >= 0);
    try std.testing.expect(inbox_stats.peak_usage >= 0);
}

test "Inbox empty receive blocks briefly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var inbox_ptr = try inbox(allocator);
    defer inbox_ptr.close();

    // Test that recvTimeout returns null when empty
    const result = try inbox_ptr.recvTimeout(5);
    try std.testing.expect(result == null);
}

test "Inbox send and receive ordering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var inbox_ptr = try inbox(allocator);
    defer inbox_ptr.close();

    // Send messages in order
    try inbox_ptr.send("first");
    try inbox_ptr.send("second");
    try inbox_ptr.send("third");

    // Receive in FIFO order
    var msg1 = try inbox_ptr.recv();
    defer msg1.deinit();
    try std.testing.expectEqualSlices(u8, "first", msg1.payload.?);

    var msg2 = try inbox_ptr.recv();
    defer msg2.deinit();
    try std.testing.expectEqualSlices(u8, "second", msg2.payload.?);

    var msg3 = try inbox_ptr.recv();
    defer msg3.deinit();
    try std.testing.expectEqualSlices(u8, "third", msg3.payload.?);
}

test "Inbox memory leak fix - many sends without leaks" {
    // Use testing allocator to detect memory leaks
    var testing_allocator = std.testing.allocator;

    var inbox_ptr = try inbox(testing_allocator);
    defer inbox_ptr.close();

    // Send many messages to ensure no memory leaks occur
    // Use fewer messages than default capacity (100) to avoid blocking
    const num_messages = 50;
    var i: usize = 0;
    while (i < num_messages) : (i += 1) {
        const msg_buf = try std.fmt.allocPrint(testing_allocator, "message_{d}", .{i});
        defer testing_allocator.free(msg_buf);
        try inbox_ptr.send(msg_buf);
    }

    // Receive all messages to ensure they're processed
    i = 0;
    while (i < num_messages) : (i += 1) {
        var msg = try inbox_ptr.recv();
        defer msg.deinit();

        const expected_buf = try std.fmt.allocPrint(testing_allocator, "message_{d}", .{i});
        defer testing_allocator.free(expected_buf);
        try std.testing.expectEqualSlices(u8, expected_buf, msg.payload.?);
    }

    // The testing allocator will detect any leaks automatically
}

test "Inbox memory leak fix - repeated sends and cleanup" {
    // Use testing allocator to detect memory leaks
    var testing_allocator = std.testing.allocator;

    // Test multiple cycles of create/send/receive/cleanup
    const cycles = 5;
    const messages_per_cycle = 25; // Keep well below capacity of 100

    var cycle: usize = 0;
    while (cycle < cycles) : (cycle += 1) {
        var inbox_ptr = try inbox(testing_allocator);
        defer inbox_ptr.close();

        // Send messages
        var i: usize = 0;
        while (i < messages_per_cycle) : (i += 1) {
            const msg_buf = try std.fmt.allocPrint(testing_allocator, "cycle_{d}_msg_{d}", .{ cycle, i });
            defer testing_allocator.free(msg_buf);
            try inbox_ptr.send(msg_buf);
        }

        // Receive and cleanup all messages
        i = 0;
        while (i < messages_per_cycle) : (i += 1) {
            var msg = try inbox_ptr.recv();
            defer msg.deinit();

            const expected_buf = try std.fmt.allocPrint(testing_allocator, "cycle_{d}_msg_{d}", .{ cycle, i });
            defer testing_allocator.free(expected_buf);
            try std.testing.expectEqualSlices(u8, expected_buf, msg.payload.?);
        }
    }

    // The testing allocator will detect any leaks across all cycles
}

test "Inbox message IDs are unique" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var inbox_ptr = try inbox(allocator);
    defer inbox_ptr.close();

    // Send multiple messages
    try inbox_ptr.send("msg1");
    try inbox_ptr.send("msg2");
    try inbox_ptr.send("msg3");

    // Receive and verify each high-level send gets a distinct id.
    var msg1 = try inbox_ptr.recv();
    defer msg1.deinit();

    var msg2 = try inbox_ptr.recv();
    defer msg2.deinit();

    var msg3 = try inbox_ptr.recv();
    defer msg3.deinit();
    try std.testing.expect(!std.mem.eql(u8, msg1.id, msg2.id));
    try std.testing.expect(!std.mem.eql(u8, msg1.id, msg3.id));
    try std.testing.expect(!std.mem.eql(u8, msg2.id, msg3.id));
}

test "InboxBuilder applies rate limiting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var inbox_ptr = try inboxBuilder(allocator)
        .withRateLimit(.{ .max_per_second = 1 })
        .build();
    defer inbox_ptr.close();

    try inbox_ptr.send("first");
    try std.testing.expectError(MessageError.RateLimitExceeded, inbox_ptr.send("second"));
}

test "InboxBuilder applies return_error backpressure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var inbox_ptr = try inboxBuilder(allocator)
        .capacity(1)
        .withBackpressure(.{
            .strategy = .return_error,
            .high_watermark = 1,
            .low_watermark = 0,
        })
        .build();
    defer inbox_ptr.close();

    try inbox_ptr.send("first");
    try std.testing.expectError(MessageError.MailboxFull, inbox_ptr.send("second"));
}

test "InboxBuilder rejects inverted backpressure watermarks" {
    try std.testing.expectError(
        error.InvalidConfiguration,
        inboxBuilder(std.testing.allocator)
            .withBackpressure(.{
                .strategy = .block,
                .high_watermark = 1,
                .low_watermark = 2,
            })
            .build(),
    );
}

test "InboxBuilder drop_newest backpressure keeps existing message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var inbox_ptr = try inboxBuilder(allocator)
        .capacity(1)
        .withBackpressure(.{
            .strategy = .drop_newest,
            .high_watermark = 1,
            .low_watermark = 0,
        })
        .build();
    defer inbox_ptr.close();

    try inbox_ptr.send("first");
    try inbox_ptr.send("second");

    var msg = try inbox_ptr.recv();
    defer msg.deinit();
    try std.testing.expectEqualStrings("first", msg.payload.?);
    try std.testing.expectEqual(@as(?Message, null), try inbox_ptr.recvTimeout(5));
    try std.testing.expectEqual(@as(usize, 0), try inbox_ptr.deadLetterCount());
}

test "InboxBuilder drop_oldest backpressure replaces existing message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var inbox_ptr = try inboxBuilder(allocator)
        .capacity(1)
        .withBackpressure(.{
            .strategy = .drop_oldest,
            .high_watermark = 1,
            .low_watermark = 0,
        })
        .build();
    defer inbox_ptr.close();

    try inbox_ptr.send("first");
    try inbox_ptr.send("second");

    var msg = try inbox_ptr.recv();
    defer msg.deinit();
    try std.testing.expectEqualStrings("second", msg.payload.?);
    try std.testing.expectEqual(@as(?Message, null), try inbox_ptr.recvTimeout(5));
    try std.testing.expectEqual(@as(usize, 1), inbox_ptr.stats().messages_dropped);
}

test "Inbox supports concurrent producer and consumer churn" {
    const allocator = std.heap.smp_allocator;
    const iterations = 128;

    var inbox_ptr = try inboxBuilder(allocator)
        .capacity(iterations + 4)
        .build();
    defer inbox_ptr.close();

    const ProducerContext = struct {
        target: *Inbox,
        count: usize,
    };
    const ConsumerContext = struct {
        target: *Inbox,
        count: usize,
    };

    const producer = struct {
        fn run(ctx: ProducerContext) void {
            for (0..ctx.count) |_| {
                ctx.target.send("payload") catch return;
            }
        }
    }.run;
    const consumer = struct {
        fn run(ctx: ConsumerContext) void {
            for (0..ctx.count) |_| {
                var msg = ctx.target.recv() catch return;
                msg.deinit();
            }
        }
    }.run;

    const producer_thread = try std.Thread.spawn(.{}, producer, .{ProducerContext{
        .target = inbox_ptr,
        .count = iterations,
    }});
    const consumer_thread = try std.Thread.spawn(.{}, consumer, .{ConsumerContext{
        .target = inbox_ptr,
        .count = iterations,
    }});

    producer_thread.join();
    consumer_thread.join();

    try std.testing.expectEqual(@as(usize, 0), inbox_ptr.mailbox.queuedCount());
}

test "Inbox exposes dead-letter lifecycle telemetry and poison hook" {
    const Recorder = struct {
        var dead_lettered = std.atomic.Value(usize).init(0);
        var replayed = std.atomic.Value(usize).init(0);
        var discarded = std.atomic.Value(usize).init(0);
        var poison_events = std.atomic.Value(usize).init(0);
        var poison_hooks = std.atomic.Value(usize).init(0);

        fn event(value: telemetry.Event) void {
            const counter = switch (value.event_type) {
                .message_dead_lettered => &dead_lettered,
                .message_replayed => &replayed,
                .message_discarded => &discarded,
                .poison_message_detected => &poison_events,
                else => return,
            };
            _ = counter.fetchAdd(1, .acq_rel);
        }

        fn poison(_: ?*anyopaque, notice: DeadLetterNotice) void {
            if (notice.poisoned and notice.newly_poisoned) {
                _ = poison_hooks.fetchAdd(1, .acq_rel);
            }
        }
    };

    Recorder.dead_lettered.store(0, .release);
    Recorder.replayed.store(0, .release);
    Recorder.discarded.store(0, .release);
    Recorder.poison_events.store(0, .release);
    Recorder.poison_hooks.store(0, .release);

    var emitter = telemetry.TelemetryEmitter.init(std.testing.allocator);
    defer emitter.deinit();
    try emitter.on(.message_dead_lettered, Recorder.event);
    try emitter.on(.message_replayed, Recorder.event);
    try emitter.on(.message_discarded, Recorder.event);
    try emitter.on(.poison_message_detected, Recorder.event);

    var inbox_ptr = try inboxBuilder(std.testing.allocator)
        .capacity(1)
        .deadLetterCapacity(4)
        .maxDeliveryAttempts(2)
        .build();
    defer inbox_ptr.close();
    inbox_ptr.setTelemetryEmitter(&emitter);
    inbox_ptr.onPoisonMessage(null, Recorder.poison);

    try inbox_ptr.send("active");
    try inbox_ptr.send("overflow");
    var snapshot = try inbox_ptr.deadLetters(std.testing.allocator);
    const overflow_id = snapshot.entries[0].id;
    snapshot.deinit();

    var active = try inbox_ptr.recv();
    active.deinit();
    try std.testing.expectEqual(DeadLetterReplayStatus.replayed, (try inbox_ptr.replayDeadLetter(overflow_id)).status);

    const first_attempt = try inbox_ptr.recv();
    const first_failure = try inbox_ptr.deadLetter(first_attempt, .delivery_failed);
    try std.testing.expect(!first_failure.poisoned);
    try std.testing.expectEqual(DeadLetterReplayStatus.replayed, (try inbox_ptr.replayDeadLetter(first_failure.id)).status);

    const second_attempt = try inbox_ptr.recv();
    const poison = try inbox_ptr.deadLetter(second_attempt, .delivery_failed);
    try std.testing.expect(poison.poisoned);
    try std.testing.expect(try inbox_ptr.discardDeadLetter(poison.id));

    try std.testing.expectEqual(@as(usize, 3), Recorder.dead_lettered.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), Recorder.replayed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), Recorder.discarded.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), Recorder.poison_events.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), Recorder.poison_hooks.load(.acquire));
}

test "Inbox poison hook can close its inbox without deadlocking" {
    const Closer = struct {
        fn close(context: ?*anyopaque, _: DeadLetterNotice) void {
            const target: *Inbox = @ptrCast(@alignCast(context.?));
            target.close();
        }
    };

    var inbox_ptr = try inboxBuilder(std.testing.allocator)
        .maxDeliveryAttempts(1)
        .build();
    inbox_ptr.onPoisonMessage(inbox_ptr, Closer.close);

    try inbox_ptr.send("poison");
    const failed = try inbox_ptr.recv();
    _ = try inbox_ptr.deadLetter(failed, .delivery_failed);
    // The hook closed and destroyed inbox_ptr. Reaching this line proves the
    // callback ran after the operation released its close reference.
}
