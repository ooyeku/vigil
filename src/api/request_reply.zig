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

/// Reply mailbox for handling responses.
/// Non-matching messages are re-queued to avoid dropping messages
/// intended for other pending requests.
pub const ReplyMailbox = struct {
    inbox: *Inbox,
    correlation_map: std.StringHashMap(*std.Thread.ResetEvent),
    /// Buffer for messages that didn't match the awaited correlation ID.
    /// These are re-sent to the inbox so other consumers can process them.
    stash: std.ArrayListUnmanaged(Message),
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    /// Initialize a reply mailbox
    pub fn init(allocator: std.mem.Allocator, inbox: *Inbox) ReplyMailbox {
        return .{
            .inbox = inbox,
            .correlation_map = std.StringHashMap(*std.Thread.ResetEvent).init(allocator),
            .stash = .{},
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

        // Clean up any stashed messages
        for (self.stash.items) |*msg| {
            msg.deinit();
        }
        self.stash.deinit(self.allocator);
    }

    /// Flush stashed (non-matching) messages back to the inbox so they
    /// are available for other consumers or future waitForReply calls.
    fn flushStash(self: *ReplyMailbox) void {
        while (self.stash.items.len > 0) {
            const stashed = self.stash.items[0];
            if (stashed.payload) |payload| {
                self.inbox.send(payload) catch {
                    // If inbox is closed or full, keep in stash and stop
                    break;
                };
                // Sent successfully, free the stashed message and remove
                var removed = self.stash.orderedRemove(0);
                removed.deinit();
            } else {
                // No payload to re-send, discard
                var removed = self.stash.orderedRemove(0);
                removed.deinit();
            }
        }
    }

    /// Wait for a reply with the given correlation ID.
    /// Non-matching messages are stashed and re-queued to the inbox
    /// when the wait completes (on match, timeout, or error).
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
                self.flushStash();
                return MessageError.DeliveryTimeout;
            }

            // Check inbox for reply
            if (self.inbox.recvTimeout(100)) |msg_opt| {
                if (msg_opt) |msg| {
                    if (msg.metadata.correlation_id) |msg_corr_id| {
                        if (std.mem.eql(u8, msg_corr_id, corr_id_copy)) {
                            // Found matching reply
                            cleanup.remove(&self.correlation_map, &self.mutex, corr_id_copy);
                            self.allocator.free(corr_id_copy);
                            self.allocator.destroy(event);

                            // Return a copy of the message, free original
                            const duped = msg.dupe() catch |err| {
                                var m = msg;
                                m.deinit();
                                self.flushStash();
                                return err;
                            };
                            var orig = msg;
                            orig.deinit();
                            self.flushStash();
                            return duped;
                        }
                    }
                    // Not our reply — stash it for re-queuing
                    self.stash.append(self.allocator, msg) catch {
                        // If we can't stash, deinit to avoid leak
                        var m = msg;
                        m.deinit();
                    };
                }
            } else |err| {
                // Check if inbox is closed
                if (err == InboxError.InboxClosed) {
                    cleanup.remove(&self.correlation_map, &self.mutex, corr_id_copy);
                    self.allocator.free(corr_id_copy);
                    self.allocator.destroy(event);
                    self.flushStash();
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
