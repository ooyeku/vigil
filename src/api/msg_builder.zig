//! High-level message builder API for Vigil
//! Provides a fluent builder pattern for creating messages.
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

pub const Message = legacy.Message;
pub const MessagePriority = legacy.MessagePriority;
pub const Signal = legacy.Signal;

/// Fluent message builder
pub const MessageBuilder = struct {
    payload: []const u8,
    sender: ?[]const u8 = null,
    priority_val: MessagePriority = .normal,
    ttl_ms: ?u32 = null,
    signal_val: ?Signal = null,
    correlation_id: ?[]const u8 = null,
    reply_to: ?[]const u8 = null,

    pub fn from(self: MessageBuilder, sender: []const u8) MessageBuilder {
        var result = self;
        result.sender = sender;
        return result;
    }

    pub fn priority(self: MessageBuilder, p: MessagePriority) MessageBuilder {
        var result = self;
        result.priority_val = p;
        return result;
    }

    pub fn ttl(self: MessageBuilder, ms: u32) MessageBuilder {
        var result = self;
        result.ttl_ms = ms;
        return result;
    }

    pub fn signal(self: MessageBuilder, sig: Signal) MessageBuilder {
        var result = self;
        result.signal_val = sig;
        return result;
    }

    pub fn withCorrelation(self: MessageBuilder, id: []const u8) MessageBuilder {
        var result = self;
        result.correlation_id = id;
        return result;
    }

    pub fn replyTo(self: MessageBuilder, addr: []const u8) MessageBuilder {
        var result = self;
        result.reply_to = addr;
        return result;
    }

    pub fn build(self: MessageBuilder, allocator: std.mem.Allocator) !Message {
        var message = try Message.init(
            allocator,
            try std.fmt.allocPrint(allocator, "msg_{d}", .{std.time.milliTimestamp()}),
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

/// Create a new message builder with the given payload
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
