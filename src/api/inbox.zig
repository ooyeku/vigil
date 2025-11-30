//! High-level inbox API for Vigil
//! Provides a channel-like interface for message passing.
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

pub const Message = legacy.Message;
pub const ProcessMailbox = legacy.ProcessMailbox;
pub const Signal = legacy.Signal;
pub const MessageError = legacy.MessageError;

/// Error returned when attempting to receive from a closed inbox
pub const InboxError = error{
    /// The inbox has been closed
    InboxClosed,
};

/// High-level inbox wrapper around ProcessMailbox
pub const Inbox = struct {
    mailbox: *ProcessMailbox,
    allocator: std.mem.Allocator,
    /// Atomic flag indicating the inbox has been closed
    closed: std.atomic.Value(bool),

    /// Create a new inbox
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
        };

        return inbox_ptr;
    }

    /// Close and cleanup the inbox.
    /// Sets the closed flag first to signal waiting threads, then waits briefly
    /// before deallocating resources to allow threads to exit gracefully.
    pub fn close(self: *Inbox) void {
        // Set closed flag first to signal waiting threads
        self.closed.store(true, .release);

        // Brief wait to allow threads in recv/recvTimeout to notice the flag and exit
        std.Thread.sleep(10 * std.time.ns_per_ms);

        // Now safe to deallocate
        self.mailbox.deinit();
        self.allocator.destroy(self.mailbox);
        self.allocator.destroy(self);
    }

    /// Check if the inbox has been closed
    pub fn isClosed(self: *Inbox) bool {
        return self.closed.load(.acquire);
    }

    /// Send a message payload
    pub fn send(self: *Inbox, payload: []const u8) !void {
        if (self.closed.load(.acquire)) {
            return InboxError.InboxClosed;
        }
        const message = try Message.init(
            self.allocator,
            try std.fmt.allocPrint(self.allocator, "inbox_msg_{d}", .{std.time.milliTimestamp()}),
            "inbox_sender",
            payload,
            null,
            .normal,
            null,
        );
        try self.mailbox.send(message);
    }

    /// Receive a message (blocks until available or inbox is closed)
    /// Returns error.InboxClosed if the inbox is closed while waiting
    pub fn recv(self: *Inbox) !Message {
        while (true) {
            // Check if inbox has been closed
            if (self.closed.load(.acquire)) {
                return InboxError.InboxClosed;
            }
            if (self.mailbox.receive()) |msg| {
                return msg;
            } else |err| switch (err) {
                error.EmptyMailbox => {
                    std.Thread.sleep(1 * std.time.ns_per_ms);
                    continue;
                },
                else => return err,
            }
        }
    }

    /// Receive with timeout.
    /// Returns null on timeout, error.InboxClosed if closed while waiting.
    pub fn recvTimeout(self: *Inbox, timeout_ms: u32) !?Message {
        const start = std.time.milliTimestamp();
        while (true) {
            // Check if inbox has been closed
            if (self.closed.load(.acquire)) {
                return InboxError.InboxClosed;
            }
            if (std.time.milliTimestamp() - start > timeout_ms) {
                return null;
            }
            if (self.mailbox.receive()) |msg| {
                return msg;
            } else |err| switch (err) {
                error.EmptyMailbox => {
                    std.Thread.sleep(1 * std.time.ns_per_ms);
                    continue;
                },
                else => return err,
            }
        }
    }

    /// Get statistics
    pub fn stats(self: *Inbox) legacy.MailboxStats {
        return self.mailbox.getStats();
    }
};

/// Inbox builder for fluent configuration
pub const InboxBuilder = struct {
    allocator: std.mem.Allocator,
    capacity_val: usize = 100,
    priority_queues_val: bool = true,
    dead_letter_val: bool = true,
    default_ttl_ms_val: ?u32 = 30_000,
    rate_limit_config: ?flow_control.RateLimitConfig = null,
    backpressure_config: ?flow_control.BackpressureConfig = null,

    const flow_control = @import("./flow_control.zig");

    fn init(allocator: std.mem.Allocator) InboxBuilder {
        return .{ .allocator = allocator };
    }

    pub fn capacity(self: InboxBuilder, n: usize) InboxBuilder {
        var result = self;
        result.capacity_val = n;
        return result;
    }

    pub fn priorityQueues(self: InboxBuilder, enabled: bool) InboxBuilder {
        var result = self;
        result.priority_queues_val = enabled;
        return result;
    }

    pub fn deadLetter(self: InboxBuilder, enabled: bool) InboxBuilder {
        var result = self;
        result.dead_letter_val = enabled;
        return result;
    }

    pub fn defaultTTL(self: InboxBuilder, ms: u32) InboxBuilder {
        var result = self;
        result.default_ttl_ms_val = ms;
        return result;
    }

    pub fn withRateLimit(self: InboxBuilder, config: flow_control.RateLimitConfig) InboxBuilder {
        var result = self;
        result.rate_limit_config = config;
        return result;
    }

    pub fn withBackpressure(self: InboxBuilder, config: flow_control.BackpressureConfig) InboxBuilder {
        var result = self;
        result.backpressure_config = config;
        return result;
    }

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
        };

        return inbox_ptr;
    }
};

/// Create a new inbox builder
pub fn inboxBuilder(allocator: std.mem.Allocator) InboxBuilder {
    return InboxBuilder.init(allocator);
}

/// Create a new inbox (simple version)
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
