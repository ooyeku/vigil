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
pub const QueuedMessageSnapshot = messages.QueuedMessageSnapshot;
pub const MailboxQueueSnapshot = messages.MailboxQueueSnapshot;

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
    const closed_operation_bit: u32 = 1 << 31;
    const operation_count_mask: u32 = closed_operation_bit - 1;

    /// RAII pin for higher-level wrappers that need several mailbox operations
    /// to share one shutdown-safe lifetime window.
    pub const OperationGuard = struct {
        inbox: ?*Inbox,

        /// Release this operation pin. Calling release more than once is safe.
        pub fn release(self: *OperationGuard) void {
            const target = self.inbox orelse return;
            self.inbox = null;
            target.endOperation();
        }
    };

    /// Underlying mailbox. Exposed for registry and low-level API interop.
    /// The `Inbox` owns this pointer; do not deinitialize it directly.
    mailbox: *ProcessMailbox,
    /// Allocator used for the inbox object, mailbox, and messages sent through
    /// `send()`.
    allocator: std.mem.Allocator,
    /// Atomic flag indicating the inbox has been closed.
    closed: std.atomic.Value(bool),
    /// Atomic lifecycle word: the high bit closes operation admission and the
    /// remaining bits count in-flight operations. `close()` waits for the count
    /// to reach zero before deallocating.
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
        // Atomically close admission for new operations. An operation either
        // increments before this bit is set (and close waits for it), or its
        // compare/exchange observes the bit and returns InboxClosed.
        _ = self.active_ops.fetchOr(closed_operation_bit, .acq_rel);

        // Spin-wait until all in-flight operations have exited.
        // Each operation increments active_ops on entry and decrements
        // on exit, so reaching zero means nothing is touching the mailbox.
        // Receivers may be parked in receiveWait(); broadcast on every
        // iteration so they wake, observe the closed flag, and exit.
        while (self.active_ops.load(.acquire) & operation_count_mask != 0) {
            self.mailbox.wakeWaiters();
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
        try self.beginOperation();
        defer self.endOperation();

        while (true) {
            if (self.closed.load(.acquire)) return InboxError.InboxClosed;

            // Park on the mailbox condition instead of polling. `close()`
            // broadcasts while draining operations, so a blocked receiver
            // re-checks the closed flag promptly during shutdown.
            if (self.mailbox.receiveWait(1000)) |msg| {
                return msg;
            } else |err| switch (err) {
                error.EmptyMailbox => continue,
                else => return err,
            }
        }
    }

    /// Receive the next message, waiting at most `timeout_ms`.
    ///
    /// Returns null on timeout. A zero timeout performs a non-blocking poll.
    /// The returned `Message`, when present, is owned by the caller and must be
    /// deinitialized.
    pub fn recvTimeout(self: *Inbox, timeout_ms: u32) !?Message {
        const start = compat.monotonicMilliTimestamp();
        try self.beginOperation();
        defer self.endOperation();

        var first_poll = true;
        while (true) {
            if (self.closed.load(.acquire)) return InboxError.InboxClosed;

            if (timeout_ms == 0) {
                // Non-blocking poll.
                if (self.mailbox.receive()) |msg| {
                    return msg;
                } else |err| switch (err) {
                    error.EmptyMailbox => return null,
                    else => return err,
                }
            }

            // Always poll at least once so short timeouts still observe
            // already-queued messages even when the thread was descheduled
            // past the deadline before the first attempt.
            const elapsed = compat.monotonicMilliTimestamp() - start;
            if (elapsed >= timeout_ms and !first_poll) return null;
            const remaining: u32 = if (elapsed >= timeout_ms)
                0
            else
                @intCast(@as(i64, timeout_ms) - elapsed);
            first_poll = false;

            if (self.mailbox.receiveWait(remaining)) |msg| {
                return msg;
            } else |err| switch (err) {
                error.EmptyMailbox => continue,
                else => return err,
            }
        }
    }

    /// Receive one message without blocking.
    ///
    /// Returns null immediately when the inbox is empty. The returned
    /// `Message`, when present, is owned by the caller and must be
    /// deinitialized. This is the explicit fast path; `recvTimeout(0)` is
    /// equivalent.
    pub fn tryRecv(self: *Inbox) !?Message {
        try self.beginOperation();
        defer self.endOperation();

        if (self.mailbox.receive()) |msg| {
            return msg;
        } else |err| switch (err) {
            error.EmptyMailbox => return null,
            else => return err,
        }
    }

    /// Receive up to `buffer.len` messages without blocking.
    ///
    /// The whole batch is taken under one mailbox lock and one expiry sweep,
    /// so draining N messages costs far less than N `tryRecv()` calls on deep
    /// queues. Returns the number of messages written, zero when empty. The
    /// caller owns each returned message and must deinitialize all of them.
    pub fn recvBatch(self: *Inbox, buffer: []Message) !usize {
        try self.beginOperation();
        defer self.endOperation();
        return self.mailbox.receiveBatch(buffer);
    }

    /// Send each payload in order, stopping at the first failure.
    ///
    /// Returns the number of payloads accepted. When the very first send
    /// fails its error is returned instead, so callers can distinguish "the
    /// inbox rejected everything" from partial progress and retry the
    /// remainder.
    pub fn sendBatch(self: *Inbox, payloads: []const []const u8) !usize {
        var accepted: usize = 0;
        for (payloads) |payload| {
            self.send(payload) catch |err| {
                if (accepted == 0) return err;
                return accepted;
            };
            accepted += 1;
        }
        return accepted;
    }

    /// Return a snapshot of the underlying mailbox statistics.
    pub fn stats(self: *Inbox) ProcessMailbox.MailboxStats {
        var operation = self.acquireOperation() catch return .{};
        defer operation.release();
        return self.mailbox.getStats();
    }

    /// Attach an emitter used for dead-letter lifecycle events.
    ///
    /// `emitter` must outlive this inbox. `Runtime.inbox()` configures this
    /// automatically when runtime telemetry is enabled.
    pub fn setTelemetryEmitter(self: *Inbox, emitter: ?*telemetry.TelemetryEmitter) void {
        var operation = self.acquireOperation() catch return;
        defer operation.release();
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
        var operation = self.acquireOperation() catch return;
        defer operation.release();
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

    /// Capture an owned snapshot of queued messages without consuming them.
    ///
    /// Entries appear in delivery order. Payload bytes are not copied; each
    /// entry carries scalar metadata plus copied id/sender strings. The caller
    /// owns the snapshot and must call `deinit()`.
    pub fn peekMessages(self: *Inbox, allocator: std.mem.Allocator) !messages.MailboxQueueSnapshot {
        try self.beginOperation();
        defer self.endOperation();
        return try self.mailbox.snapshotQueue(allocator);
    }

    fn queuedCount(self: *Inbox) usize {
        return self.mailbox.queuedCount();
    }

    /// Return the active queue depth while participating in shutdown safety.
    pub fn queueDepth(self: *Inbox) !usize {
        try self.beginOperation();
        defer self.endOperation();
        return self.mailbox.queuedCount();
    }

    /// Drop the oldest active message while participating in shutdown safety.
    pub fn dropOldest(self: *Inbox) !bool {
        try self.beginOperation();
        defer self.endOperation();
        return self.mailbox.dropOldest();
    }

    /// Pin the inbox lifetime across a multi-step operation.
    ///
    /// The returned guard must be released. This is intended for wrappers that
    /// need to inspect the raw mailbox and later delegate back to the inbox.
    pub fn acquireOperation(self: *Inbox) !OperationGuard {
        try self.beginOperation();
        return .{ .inbox = self };
    }

    fn beginOperation(self: *Inbox) !void {
        var lifecycle = self.active_ops.load(.acquire);
        while (true) {
            if (lifecycle & closed_operation_bit != 0) return InboxError.InboxClosed;
            if (lifecycle & operation_count_mask == operation_count_mask) {
                return error.TooManyOperations;
            }
            if (self.active_ops.cmpxchgWeak(
                lifecycle,
                lifecycle + 1,
                .acq_rel,
                .acquire,
            )) |observed| {
                lifecycle = observed;
                continue;
            }
            // close() publishes the user-visible flag before closing the
            // lifecycle word. If we won the narrow interval between those two
            // atomics, release the admitted reference and honor shutdown.
            if (self.closed.load(.acquire)) {
                self.endOperation();
                return InboxError.InboxClosed;
            }
            return;
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
        const depth = self.queuedCount();

        // Adaptive pressure band: slow the sender proportionally to queue
        // growth before the hard high-watermark reaction kicks in.
        if (config.strategy == .adaptive and
            depth >= config.low_watermark and
            depth < config.high_watermark)
        {
            const band = config.high_watermark - config.low_watermark;
            const fill = depth - config.low_watermark + 1;
            const delay_ms = @max(1, config.max_delay_ms * fill / band);
            compat.sleep(@as(u64, delay_ms) * std.time.ns_per_ms);
        }

        if (depth < config.high_watermark) return true;

        switch (config.strategy) {
            .drop_oldest => {
                _ = self.mailbox.dropOldest();
            },
            .drop_newest => return false,
            .block, .adaptive => {
                while (self.queuedCount() >= config.low_watermark) {
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
            if (config.low_watermark > config.high_watermark or
                (config.strategy == .block and config.low_watermark == 0))
            {
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
            .rate_limiter = if (self.rate_limit_config) |config| config.limiter() else null,
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

test "InboxBuilder rejects blocking backpressure with zero low watermark" {
    try std.testing.expectError(
        error.InvalidConfiguration,
        inboxBuilder(std.testing.allocator)
            .withBackpressure(.{
                .strategy = .block,
                .high_watermark = 1,
                .low_watermark = 0,
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

test "Inbox lifecycle bit atomically rejects operation admission" {
    var inbox_ptr = try Inbox.init(std.testing.allocator);
    defer inbox_ptr.close();

    _ = inbox_ptr.active_ops.fetchOr(Inbox.closed_operation_bit, .acq_rel);
    try std.testing.expectError(InboxError.InboxClosed, inbox_ptr.queueDepth());

    // Restore the lifecycle word so the deferred close remains the sole owner
    // of destruction in this test.
    inbox_ptr.active_ops.store(0, .release);
}

test "Inbox close waits for a blocked receiver to observe shutdown" {
    const Receiver = struct {
        inbox: *Inbox,
        observed_close: *std.atomic.Value(bool),

        fn run(context: *@This()) void {
            _ = context.inbox.recv() catch |err| {
                if (err == InboxError.InboxClosed) {
                    context.observed_close.store(true, .release);
                }
                return;
            };
        }
    };

    var observed_close = std.atomic.Value(bool).init(false);
    var inbox_ptr = try Inbox.init(std.testing.allocator);
    var receiver = Receiver{
        .inbox = inbox_ptr,
        .observed_close = &observed_close,
    };
    const thread = try std.Thread.spawn(.{}, Receiver.run, .{&receiver});

    while (inbox_ptr.active_ops.load(.acquire) & Inbox.operation_count_mask == 0) {
        compat.sleep(1 * std.time.ns_per_ms);
    }
    inbox_ptr.close();
    thread.join();

    try std.testing.expect(observed_close.load(.acquire));
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

test "Inbox peekMessages inspects the queue without consuming" {
    const allocator = std.testing.allocator;
    var target = try Inbox.init(allocator);
    defer target.close();

    try target.send("first");
    try target.send("second");

    var snapshot = try target.peekMessages(allocator);
    defer snapshot.deinit();

    try std.testing.expectEqual(@as(usize, 2), snapshot.entries.len);
    try std.testing.expectEqual(@as(usize, "first".len), snapshot.entries[0].payload_len);
    try std.testing.expectEqual(@as(usize, 2), target.mailbox.queuedCount());

    var msg = try target.recv();
    defer msg.deinit();
    try std.testing.expectEqualStrings("first", msg.payload.?);
}

test "Inbox batch send and receive preserve delivery order" {
    const allocator = std.testing.allocator;
    var target = try inboxBuilder(allocator).capacity(16).build();
    defer target.close();

    const payloads = [_][]const u8{ "one", "two", "three", "four", "five" };
    try std.testing.expectEqual(@as(usize, 5), try target.sendBatch(&payloads));

    var buffer: [3]Message = undefined;
    try std.testing.expectEqual(@as(usize, 3), try target.recvBatch(&buffer));
    defer for (buffer) |msg| msg.deinit();
    try std.testing.expectEqualStrings("one", buffer[0].payload.?);
    try std.testing.expectEqualStrings("two", buffer[1].payload.?);
    try std.testing.expectEqualStrings("three", buffer[2].payload.?);

    // Remaining messages come out through the nonblocking fast path.
    var fourth = (try target.tryRecv()).?;
    defer fourth.deinit();
    try std.testing.expectEqualStrings("four", fourth.payload.?);

    var fifth = (try target.tryRecv()).?;
    defer fifth.deinit();
    try std.testing.expectEqualStrings("five", fifth.payload.?);

    try std.testing.expect(try target.tryRecv() == null);

    var empty: [2]Message = undefined;
    try std.testing.expectEqual(@as(usize, 0), try target.recvBatch(&empty));
}

test "Inbox recvBatch respects priority delivery order" {
    const allocator = std.testing.allocator;
    var target = try inboxBuilder(allocator).capacity(8).build();
    defer target.close();

    // Raw mailbox sends with explicit priorities.
    const low = try Message.init(allocator, "low", "test", "low", null, .low, null);
    try target.mailbox.send(low);
    const critical = try Message.init(allocator, "critical", "test", "critical", null, .critical, null);
    try target.mailbox.send(critical);
    const normal = try Message.init(allocator, "normal", "test", "normal", null, .normal, null);
    try target.mailbox.send(normal);

    var buffer: [4]Message = undefined;
    const received = try target.recvBatch(&buffer);
    try std.testing.expectEqual(@as(usize, 3), received);
    defer for (buffer[0..received]) |msg| msg.deinit();

    try std.testing.expectEqualStrings("critical", buffer[0].id);
    try std.testing.expectEqualStrings("normal", buffer[1].id);
    try std.testing.expectEqualStrings("low", buffer[2].id);
}
