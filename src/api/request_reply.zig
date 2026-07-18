//! Request/reply pattern for Vigil.
//!
//! These helpers layer synchronous waiting on top of normal inbox messaging by
//! assigning and matching message correlation ids. They are useful for local
//! service calls where the caller needs one response and wants timeout
//! handling.

const std = @import("std");
const Message = @import("../messages.zig").Message;
const MessageError = @import("../messages.zig").MessageError;
const Inbox = @import("./inbox.zig").Inbox;
const compat = @import("../compat.zig");

/// Value snapshot of reply-mailbox state.
pub const ReplyMailboxSnapshot = struct {
    /// Number of active correlation ids being waited on.
    pending_count: usize,
    /// Number of non-matching messages temporarily stashed.
    stashed_count: usize,
};

/// Reply mailbox for handling responses.
///
/// Non-matching messages are re-queued to avoid dropping messages
/// intended for other pending requests.
pub const ReplyMailbox = struct {
    /// Inbox used to receive candidate replies.
    inbox: *Inbox,
    /// Tracks active correlation ids.
    correlation_map: std.StringHashMap(void),
    /// Buffer for messages that didn't match the awaited correlation ID.
    /// These are re-sent to the inbox so other consumers can process them.
    stash: std.ArrayListUnmanaged(Message),
    /// Protects correlation map updates.
    mutex: compat.Mutex,
    /// Protects non-matching message storage.
    stash_mutex: compat.Mutex,
    /// Ensures only one waiter flushes the stash at a time.
    flush_mutex: compat.Mutex,
    /// Allocator for copied correlation ids and stash storage.
    allocator: std.mem.Allocator,

    /// Initialize a reply mailbox over an existing inbox.
    ///
    /// The reply mailbox does not own the inbox. Call `deinit()` before
    /// closing the inbox.
    pub fn init(allocator: std.mem.Allocator, inbox: *Inbox) ReplyMailbox {
        return .{
            .inbox = inbox,
            .correlation_map = std.StringHashMap(void).init(allocator),
            .stash = .empty,
            .mutex = .{},
            .stash_mutex = .{},
            .flush_mutex = .{},
            .allocator = allocator,
        };
    }

    /// Release correlation tracking and any stashed messages.
    pub fn deinit(self: *ReplyMailbox) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.correlation_map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.correlation_map.deinit();

        // Clean up any stashed messages
        for (self.stash.items) |*msg| {
            msg.deinit();
        }
        self.stash.deinit(self.allocator);
    }

    /// Return a value snapshot of pending replies and stashed messages.
    pub fn snapshot(self: *ReplyMailbox) ReplyMailboxSnapshot {
        self.mutex.lock();
        const pending_count = self.correlation_map.count();
        self.mutex.unlock();

        self.stash_mutex.lock();
        const stashed_count = self.stash.items.len;
        self.stash_mutex.unlock();

        return .{
            .pending_count = pending_count,
            .stashed_count = stashed_count,
        };
    }

    /// Flush stashed (non-matching) messages back to the inbox so they
    /// are available for other consumers or future waitForReply calls.
    fn flushStash(self: *ReplyMailbox) void {
        self.flush_mutex.lock();
        defer self.flush_mutex.unlock();

        while (true) {
            self.stash_mutex.lock();
            if (self.stash.items.len == 0) {
                self.stash_mutex.unlock();
                return;
            }
            const stashed = self.stash.items[0];
            if (stashed.payload != null) {
                const copy = stashed.dupe() catch {
                    self.stash_mutex.unlock();
                    return;
                };
                self.stash_mutex.unlock();
                self.inbox.sendMessage(copy) catch {
                    // If inbox is closed or full, keep in stash and stop
                    return;
                };
                // Sent successfully, free the stashed message and remove
                self.stash_mutex.lock();
                var removed = self.stash.orderedRemove(0);
                self.stash_mutex.unlock();
                removed.deinit();
            } else {
                // No payload to re-send, discard
                var removed = self.stash.orderedRemove(0);
                self.stash_mutex.unlock();
                removed.deinit();
            }
        }
    }

    /// Wait for a reply with the given correlation id.
    ///
    /// Non-matching messages are stashed and re-queued to the inbox
    /// when the wait completes (on match, timeout, or error).
    ///
    /// The returned `Message` is owned by the caller and must be deinitialized.
    pub fn waitForReply(
        self: *ReplyMailbox,
        correlation_id: []const u8,
        timeout_ms: u32,
    ) !Message {
        const corr_id_copy = try self.allocator.dupe(u8, correlation_id);
        var registered = false;
        errdefer if (!registered) self.allocator.free(corr_id_copy);
        self.mutex.lock();
        if (self.correlation_map.contains(correlation_id)) {
            self.mutex.unlock();
            return MessageError.DuplicateMessage;
        }
        self.correlation_map.put(corr_id_copy, {}) catch |err| {
            self.mutex.unlock();
            return err;
        };
        registered = true;
        self.mutex.unlock();
        defer {
            self.mutex.lock();
            _ = self.correlation_map.remove(corr_id_copy);
            self.mutex.unlock();
            self.allocator.free(corr_id_copy);
        }

        // Wait for reply
        const start_ms = compat.monotonicMilliTimestamp();
        var first_poll = true;
        while (true) {
            // Always poll at least once, even when the deadline has already
            // passed, so short timeouts still observe queued replies.
            const elapsed = compat.monotonicMilliTimestamp() - start_ms;
            if (!first_poll and (timeout_ms == 0 or elapsed >= timeout_ms)) {
                self.flushStash();
                return MessageError.DeliveryTimeout;
            }
            const poll_timeout: u32 = if (timeout_ms == 0)
                0
            else
                @intCast(@max(0, @min(@as(i64, 100), @as(i64, timeout_ms) - elapsed)));
            first_poll = false;

            // Check inbox for reply
            if (self.inbox.recvTimeout(poll_timeout)) |msg_opt| {
                if (msg_opt) |msg| {
                    if (msg.metadata.correlation_id) |msg_corr_id| {
                        if (std.mem.eql(u8, msg_corr_id, corr_id_copy)) {
                            self.flushStash();
                            return msg;
                        }
                    }
                    // Not our reply — stash it for re-queuing
                    self.stash_mutex.lock();
                    self.stash.append(self.allocator, msg) catch {
                        // If we can't stash, deinit to avoid leak
                        var m = msg;
                        m.deinit();
                    };
                    self.stash_mutex.unlock();
                }
            } else |err| {
                // Check if inbox is closed
                if (err == MessageError.InboxClosed) {
                    self.flushStash();
                    return MessageError.ReceiverUnavailable;
                }
            }
        }
    }
};

/// Build a reply message for a request.
///
/// The request must contain a correlation id. The returned `Message` copies
/// that id so callers can send it through an inbox and the requester can match
/// it. The caller owns the returned message and must call `deinit()`.
pub fn reply(request_msg: Message, response_payload: []const u8, allocator: std.mem.Allocator) !Message {
    if (request_msg.metadata.correlation_id == null) {
        return MessageError.InvalidMessage;
    }

    const response_id = try std.fmt.allocPrint(allocator, "resp_{s}", .{request_msg.id});
    defer allocator.free(response_id);

    // Create response message with same correlation ID
    var response = try Message.init(
        allocator,
        response_id,
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

test "ReplyMailbox snapshot reports pending and stashed counts" {
    const allocator = std.testing.allocator;

    var inbox = try Inbox.init(allocator);
    defer inbox.close();

    var reply_mailbox = ReplyMailbox.init(allocator, inbox);
    defer reply_mailbox.deinit();

    const snapshot = reply_mailbox.snapshot();
    try std.testing.expectEqual(@as(usize, 0), snapshot.pending_count);
    try std.testing.expectEqual(@as(usize, 0), snapshot.stashed_count);
}

test "reply does not leak temporary response id" {
    const allocator = std.testing.allocator;

    var request_msg = try Message.init(allocator, "req2", "client", "request", null, .normal, null);
    defer request_msg.deinit();
    try request_msg.setCorrelationId("corr456");

    var response = try reply(request_msg, "response_data", allocator);
    defer response.deinit();

    try std.testing.expectEqualSlices(u8, "corr456", response.metadata.correlation_id.?);
}

test "ReplyMailbox requeues non-matching messages without losing metadata" {
    const allocator = std.testing.allocator;
    var inbox = try Inbox.init(allocator);
    defer inbox.close();
    var reply_mailbox = ReplyMailbox.init(allocator, inbox);
    defer reply_mailbox.deinit();

    var unrelated = try Message.init(allocator, "other-id", "sender", "other", null, .high, null);
    try unrelated.setCorrelationId("other-correlation");
    try inbox.sendMessage(unrelated);

    try std.testing.expectError(
        MessageError.DeliveryTimeout,
        reply_mailbox.waitForReply("target-correlation", 1),
    );

    var requeued = try inbox.recv();
    defer requeued.deinit();
    try std.testing.expectEqualStrings("other-id", requeued.id);
    try std.testing.expectEqualStrings("other-correlation", requeued.metadata.correlation_id.?);
    try std.testing.expectEqual(@as(u32, 2), requeued.metadata.attempt_count);
}

test "ReplyMailbox zero timeout performs one nonblocking correlation poll" {
    const allocator = std.testing.allocator;
    var inbox = try Inbox.init(allocator);
    defer inbox.close();
    var reply_mailbox = ReplyMailbox.init(allocator, inbox);
    defer reply_mailbox.deinit();

    var response = try Message.init(allocator, "ready", "server", "response", null, .normal, null);
    try response.setCorrelationId("ready-correlation");
    try inbox.sendMessage(response);

    const received = try reply_mailbox.waitForReply("ready-correlation", 0);
    defer received.deinit();
    try std.testing.expectEqualStrings("response", received.payload.?);

    try std.testing.expectError(
        MessageError.DeliveryTimeout,
        reply_mailbox.waitForReply("missing", 0),
    );
}
