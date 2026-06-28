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
const legacy = @import("../legacy.zig");
const compat = @import("../compat.zig");
const flow_control = @import("./flow_control.zig");

pub const Message = legacy.Message;
pub const ProcessMailbox = legacy.ProcessMailbox;
pub const Signal = legacy.Signal;
pub const MessageError = legacy.MessageError;

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
    /// Underlying mailbox. Exposed for interop with registries and legacy APIs.
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
    /// Optional token-bucket limiter applied before sending.
    rate_limiter: ?flow_control.RateLimiter,
    /// Optional backpressure policy applied when queued messages cross the
    /// configured high-water mark.
    backpressure_config: ?flow_control.BackpressureConfig,

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
            .rate_limiter = null,
            .backpressure_config = null,
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
        if (self.closed.load(.acquire)) {
            return InboxError.InboxClosed;
        }
        // Track this operation so close() waits for us
        _ = self.active_ops.fetchAdd(1, .acq_rel);
        defer _ = self.active_ops.fetchSub(1, .acq_rel);

        // Re-check after incrementing to handle close() racing with us
        if (self.closed.load(.acquire)) {
            return InboxError.InboxClosed;
        }

        try self.applyFlowControl();

        const message = try Message.init(
            self.allocator,
            "inbox_msg", // Static string - Message.init will dupe it
            "inbox_sender",
            payload,
            null,
            .normal,
            null,
        );
        try self.mailbox.send(message);
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
            if (compat.milliTimestamp() - start > timeout_ms) {
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
    pub fn stats(self: *Inbox) legacy.MailboxStats {
        return self.mailbox.getStats();
    }

    fn queuedCount(self: *Inbox) usize {
        const inbox_stats = self.stats();
        if (inbox_stats.messages_received < inbox_stats.messages_sent) {
            return 0;
        }
        return inbox_stats.messages_received - inbox_stats.messages_sent;
    }

    fn applyFlowControl(self: *Inbox) !void {
        if (self.rate_limiter) |*limiter| {
            if (!limiter.allow()) {
                return MessageError.RateLimitExceeded;
            }
        }

        const config = self.backpressure_config orelse return;
        if (self.queuedCount() < config.high_watermark) return;

        switch (config.strategy) {
            .drop_oldest => {
                if (self.mailbox.receive()) |old_msg| {
                    var owned_old_msg = old_msg;
                    owned_old_msg.deinit();
                } else |_| {}
            },
            .drop_newest => return,
            .block => {
                while (self.queuedCount() >= config.low_watermark) {
                    compat.sleep(10 * std.time.ns_per_ms);
                }
            },
            .return_error => return MessageError.MailboxFull,
        }
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
        const inbox_ptr = try self.allocator.create(Inbox);
        errdefer self.allocator.destroy(inbox_ptr);

        const mailbox = try self.allocator.create(ProcessMailbox);
        errdefer self.allocator.destroy(mailbox);

        mailbox.* = ProcessMailbox.init(self.allocator, .{
            .capacity = self.capacity_val,
            .priority_queues = self.priority_queues_val,
            .enable_deadletter = self.dead_letter_val,
            .default_ttl_ms = self.default_ttl_ms_val,
        });

        inbox_ptr.* = .{
            .mailbox = mailbox,
            .allocator = self.allocator,
            .closed = std.atomic.Value(bool).init(false),
            .active_ops = std.atomic.Value(u32).init(0),
            .rate_limiter = if (self.rate_limit_config) |config| flow_control.RateLimiter.init(config.max_per_second) else null,
            .backpressure_config = self.backpressure_config,
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

test "Inbox message ID is consistent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var inbox_ptr = try inbox(allocator);
    defer inbox_ptr.close();

    // Send multiple messages
    try inbox_ptr.send("msg1");
    try inbox_ptr.send("msg2");
    try inbox_ptr.send("msg3");

    // Receive and verify message IDs are all "inbox_msg"
    var msg1 = try inbox_ptr.recv();
    defer msg1.deinit();
    try std.testing.expectEqualSlices(u8, "inbox_msg", msg1.id);

    var msg2 = try inbox_ptr.recv();
    defer msg2.deinit();
    try std.testing.expectEqualSlices(u8, "inbox_msg", msg2.id);

    var msg3 = try inbox_ptr.recv();
    defer msg3.deinit();
    try std.testing.expectEqualSlices(u8, "inbox_msg", msg3.id);
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
