//! Request/Reply pattern for Vigil
//! Synchronous messaging with automatic correlation.

const std = @import("std");
const Message = @import("../messages.zig").Message;
const MessageError = @import("../messages.zig").MessageError;
const Inbox = @import("./inbox.zig").Inbox;
const InboxError = @import("./inbox.zig").InboxError;

/// Request options
pub const RequestOptions = struct {
    timeout_ms: u32 = 5000,
};

/// Reply mailbox for handling responses
pub const ReplyMailbox = struct {
    inbox: *Inbox,
    correlation_map: std.StringHashMap(*std.Thread.ResetEvent),
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    /// Initialize a reply mailbox
    pub fn init(allocator: std.mem.Allocator, inbox: *Inbox) ReplyMailbox {
        return .{
            .inbox = inbox,
            .correlation_map = std.StringHashMap(*std.Thread.ResetEvent).init(allocator),
            .mutex = .{},
            .allocator = allocator,
        };
    }

    /// Cleanup resources
    pub fn deinit(self: *ReplyMailbox) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.correlation_map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.correlation_map.deinit();
    }

    /// Wait for a reply with the given correlation ID
    pub fn waitForReply(
        self: *ReplyMailbox,
        correlation_id: []const u8,
        timeout_ms: u32,
    ) !Message {
        const event = try self.allocator.create(std.Thread.ResetEvent);
        errdefer self.allocator.destroy(event);
        event.* = .{};

        const corr_id_copy = try self.allocator.dupe(u8, correlation_id);
        errdefer self.allocator.free(corr_id_copy);

        {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.correlation_map.put(corr_id_copy, event);
        }

        // Helper to cleanup map entry using the copied key
        const cleanup = struct {
            fn remove(map: *std.StringHashMap(*std.Thread.ResetEvent), mutex: *std.Thread.Mutex, key: []const u8) void {
                mutex.lock();
                _ = map.remove(key);
                mutex.unlock();
            }
        };

        // Wait for reply
        const start_ms = std.time.milliTimestamp();
        while (true) {
            const elapsed = std.time.milliTimestamp() - start_ms;
            if (elapsed > timeout_ms) {
                cleanup.remove(&self.correlation_map, &self.mutex, corr_id_copy);
                self.allocator.free(corr_id_copy);
                self.allocator.destroy(event);
                return MessageError.DeliveryTimeout;
            }

            // Check inbox for reply
            if (self.inbox.recvTimeout(100)) |msg_opt| {
                if (msg_opt) |msg| {
                    defer msg.deinit();
                    if (msg.metadata.correlation_id) |msg_corr_id| {
                        if (std.mem.eql(u8, msg_corr_id, corr_id_copy)) {
                            // Found matching reply
                            cleanup.remove(&self.correlation_map, &self.mutex, corr_id_copy);
                            self.allocator.free(corr_id_copy);
                            self.allocator.destroy(event);

                            // Return a copy of the message
                            return msg.dupe();
                        }
                    }
                    // Not our reply, put it back (simplified - in real impl might need a queue)
                }
            } else |err| {
                // Check if inbox is closed
                if (err == InboxError.InboxClosed) {
                    cleanup.remove(&self.correlation_map, &self.mutex, corr_id_copy);
                    self.allocator.free(corr_id_copy);
                    self.allocator.destroy(event);
                    return MessageError.ReceiverUnavailable;
                }
            }

            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }

    /// Signal that a reply was received (internal use)
    fn signalReply(self: *ReplyMailbox, correlation_id: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.correlation_map.get(correlation_id)) |event| {
            event.reset();
        }
    }
};

/// Send a request and wait for reply
pub fn request(
    inbox: *Inbox,
    request_msg: Message,
    options: RequestOptions,
) !Message {
    const allocator = inbox.allocator;

    // Create correlation ID
    const correlation_id = try std.fmt.allocPrint(
        allocator,
        "req_{d}",
        .{std.time.milliTimestamp()},
    );
    defer allocator.free(correlation_id);

    // Set correlation ID on request
    var mutable_msg = request_msg;
    try mutable_msg.setCorrelationId(correlation_id);

    // Create reply mailbox
    var reply_mailbox = ReplyMailbox.init(allocator, inbox);
    defer reply_mailbox.deinit();

    // Send request
    try inbox.send(request_msg.payload orelse "");

    // Wait for reply
    return reply_mailbox.waitForReply(correlation_id, options.timeout_ms);
}

/// Reply to a request message
pub fn reply(request_msg: Message, response_payload: []const u8, allocator: std.mem.Allocator) !Message {
    if (request_msg.metadata.correlation_id == null) {
        return MessageError.InvalidMessage;
    }

    // Create response message with same correlation ID
    var response = try Message.init(
        allocator,
        try std.fmt.allocPrint(allocator, "resp_{s}", .{request_msg.id}),
        request_msg.sender,
        response_payload,
        null,
        request_msg.priority,
        null,
    );
    errdefer response.deinit();

    // Copy correlation ID
    if (request_msg.metadata.correlation_id) |corr_id| {
        try response.setCorrelationId(corr_id);
    }

    return response;
}

test "Request/Reply basic flow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Test ReplyMailbox initialization
    var inbox = try Inbox.init(allocator);
    defer inbox.close();

    var reply_mailbox = ReplyMailbox.init(allocator, inbox);
    defer reply_mailbox.deinit();

    // Test reply function
    var request_msg = try Message.init(allocator, "req1", "client", "request", null, .normal, null);
    defer request_msg.deinit();
    try request_msg.setCorrelationId("corr123");

    var response = try reply(request_msg, "response_data", allocator);
    defer response.deinit();

    try std.testing.expect(response.metadata.correlation_id != null);
    try std.testing.expectEqualSlices(u8, "corr123", response.metadata.correlation_id.?);
    try std.testing.expectEqualSlices(u8, "response_data", response.payload.?);
}
