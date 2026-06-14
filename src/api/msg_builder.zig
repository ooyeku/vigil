//! High-level message builder API for Vigil.
//!
//! This module is the ergonomic way to create owned `Message` values without
//! touching the lower-level constructor. The builder stores borrowed option
//! slices while chaining; `build()` duplicates the data that the returned
//! `Message` owns.
//!
//! Example:
//! ```zig
//! const msg = try vigil.msg("Hello World")
//!     .from("sender")
//!     .priority(.high)
//!     .ttl(5000)
//!     .build(allocator);
//! defer msg.deinit();
//! ```

const std = @import("std");
const legacy = @import("../legacy.zig");
const compat = @import("../compat.zig");

pub const Message = legacy.Message;
pub const MessagePriority = legacy.MessagePriority;
pub const Signal = legacy.Signal;

/// Fluent builder for an owned `Message`.
///
/// `MessageBuilder` itself is cheap to copy. Its fields point at caller-owned
/// slices until `build()` is called. After `build()`, the returned `Message`
/// owns duplicated metadata and must be released with `Message.deinit()`.
pub const MessageBuilder = struct {
    /// Payload slice to copy into the built message.
    payload: []const u8,
    /// Optional sender name. Defaults to `"anonymous"`.
    sender: ?[]const u8 = null,
    /// Priority used by priority-aware mailboxes.
    priority_val: MessagePriority = .normal,
    /// Optional message time-to-live in milliseconds.
    ttl_ms: ?u32 = null,
    /// Optional control signal attached to the message.
    signal_val: ?Signal = null,
    /// Optional correlation id for request/reply workflows.
    correlation_id: ?[]const u8 = null,
    /// Optional return address for replies.
    reply_to: ?[]const u8 = null,

    /// Set the sender name copied into the message.
    pub fn from(self: MessageBuilder, sender: []const u8) MessageBuilder {
        var result = self;
        result.sender = sender;
        return result;
    }

    /// Set the mailbox priority for the message.
    pub fn priority(self: MessageBuilder, p: MessagePriority) MessageBuilder {
        var result = self;
        result.priority_val = p;
        return result;
    }

    /// Set the message time-to-live in milliseconds.
    pub fn ttl(self: MessageBuilder, ms: u32) MessageBuilder {
        var result = self;
        result.ttl_ms = ms;
        return result;
    }

    /// Attach a process control signal to the message.
    pub fn signal(self: MessageBuilder, sig: Signal) MessageBuilder {
        var result = self;
        result.signal_val = sig;
        return result;
    }

    /// Set a correlation id used to match replies to requests.
    pub fn withCorrelation(self: MessageBuilder, id: []const u8) MessageBuilder {
        var result = self;
        result.correlation_id = id;
        return result;
    }

    /// Set the logical reply address for the message.
    pub fn replyTo(self: MessageBuilder, addr: []const u8) MessageBuilder {
        var result = self;
        result.reply_to = addr;
        return result;
    }

    /// Allocate and return an owned message.
    ///
    /// The caller owns the returned `Message` and must call `deinit()`.
    /// The allocator must stay valid until that deinit call.
    pub fn build(self: MessageBuilder, allocator: std.mem.Allocator) !Message {
        var message = try Message.init(
            allocator,
            try std.fmt.allocPrint(allocator, "msg_{d}", .{compat.milliTimestamp()}),
            self.sender orelse "anonymous",
            self.payload,
            self.signal_val,
            self.priority_val,
            self.ttl_ms,
        );
        errdefer message.deinit();

        if (self.correlation_id) |id| {
            try message.setCorrelationId(id);
        }
        if (self.reply_to) |addr| {
            try message.setReplyTo(addr);
        }

        return message;
    }
};

/// Start building a message with the given payload.
///
/// The payload slice is borrowed by the builder and copied by `build()`.
pub fn msg(payload: []const u8) MessageBuilder {
    return .{ .payload = payload };
}

test "MessageBuilder basic creation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var builder = msg("test payload");
    var message = try builder.build(allocator);
    defer message.deinit();

    try std.testing.expectEqualSlices(u8, "test payload", message.payload.?);
    try std.testing.expectEqualSlices(u8, "anonymous", message.sender);
    try std.testing.expect(message.priority == .normal);
}

test "MessageBuilder with all options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var builder = msg("test")
        .from("sender1")
        .priority(.high)
        .ttl(10000)
        .signal(.alert);

    var message = try builder.build(allocator);
    defer message.deinit();

    try std.testing.expectEqualSlices(u8, "test", message.payload.?);
    try std.testing.expectEqualSlices(u8, "sender1", message.sender);
    try std.testing.expect(message.priority == .high);
    try std.testing.expect(message.metadata.ttl_ms == 10000);
    try std.testing.expect(message.signal == .alert);
}

test "MessageBuilder with correlation ID" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var builder = msg("test").withCorrelation("corr_123");
    var message = try builder.build(allocator);
    defer message.deinit();

    try std.testing.expectEqualSlices(u8, "corr_123", message.metadata.correlation_id.?);
}

test "MessageBuilder with reply-to" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var builder = msg("test").replyTo("response_queue");
    var message = try builder.build(allocator);
    defer message.deinit();

    try std.testing.expectEqualSlices(u8, "response_queue", message.metadata.reply_to.?);
}

test "MessageBuilder chaining all methods" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var builder = msg("complex message")
        .from("sender_app")
        .priority(.critical)
        .ttl(5000)
        .signal(.healthCheck)
        .withCorrelation("req_456")
        .replyTo("response_channel");

    var message = try builder.build(allocator);
    defer message.deinit();

    try std.testing.expectEqualSlices(u8, "complex message", message.payload.?);
    try std.testing.expectEqualSlices(u8, "sender_app", message.sender);
    try std.testing.expect(message.priority == .critical);
    try std.testing.expect(message.metadata.ttl_ms == 5000);
    try std.testing.expect(message.signal == .healthCheck);
    try std.testing.expectEqualSlices(u8, "req_456", message.metadata.correlation_id.?);
    try std.testing.expectEqualSlices(u8, "response_channel", message.metadata.reply_to.?);
}

test "MessageBuilder with different priorities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const priorities = [_]MessagePriority{ .critical, .high, .normal, .low, .batch };
    for (priorities) |prio| {
        var builder = msg("test").priority(prio);
        var message = try builder.build(allocator);
        defer message.deinit();
        try std.testing.expect(message.priority == prio);
    }
}

test "MessageBuilder with different signals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const signals = [_]Signal{ .restart, .shutdown, .healthCheck, .alert, .info };
    for (signals) |sig| {
        var builder = msg("test").signal(sig);
        var message = try builder.build(allocator);
        defer message.deinit();
        try std.testing.expect(message.signal == sig);
    }
}
