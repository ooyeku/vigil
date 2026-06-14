//! Flow control primitives for Vigil.
//!
//! Use these APIs when producers can temporarily outpace consumers. A
//! `RateLimiter` caps operation frequency, while backpressure policies define
//! what an inbox should do once queued work crosses a high-water mark.

const std = @import("std");
const Message = @import("../messages.zig").Message;
const MessageError = @import("../messages.zig").MessageError;
const compat = @import("../compat.zig");

/// Policy applied when queued messages reach a configured high-water mark.
pub const BackpressureStrategy = enum {
    /// Remove the oldest queued message and accept the new one.
    drop_oldest,
    /// Drop the new message and report success to the caller.
    drop_newest,
    /// Block the sender until queued work falls below the low-water mark.
    block,
    /// Return `MessageError.MailboxFull` immediately.
    return_error,
};

/// Token-bucket rate limiter.
///
/// `allow()` is thread-safe. The bucket starts full, so a new limiter permits
/// an initial burst up to `max_per_second`, then refills over time.
pub const RateLimiter = struct {
    /// Currently available tokens.
    tokens: f64,
    /// Maximum tokens the bucket can hold.
    max_tokens: f64,
    /// Tokens added per millisecond.
    refill_rate: f64,
    /// Timestamp of the last refill calculation.
    last_refill_ms: i64,
    /// Protects token accounting.
    mutex: compat.Mutex,

    /// Initialize a limiter for `max_per_second` successful operations.
    pub fn init(max_per_second: u32) RateLimiter {
        const tokens_per_ms = @as(f64, @floatFromInt(max_per_second)) / 1000.0;
        return .{
            .tokens = @as(f64, @floatFromInt(max_per_second)),
            .max_tokens = @as(f64, @floatFromInt(max_per_second)),
            .refill_rate = tokens_per_ms,
            .last_refill_ms = compat.milliTimestamp(),
            .mutex = .{},
        };
    }

    /// Try to consume one token.
    ///
    /// Returns true when the operation may proceed, false when the caller
    /// should drop, retry later, or return a rate-limit error.
    pub fn allow(self: *RateLimiter) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now_ms = compat.milliTimestamp();
        const elapsed_ms = @as(f64, @floatFromInt(now_ms - self.last_refill_ms));
        self.last_refill_ms = now_ms;

        // Refill tokens based on elapsed time
        self.tokens = @min(self.max_tokens, self.tokens + (elapsed_ms * self.refill_rate));

        if (self.tokens >= 1.0) {
            self.tokens -= 1.0;
            return true;
        }
        return false;
    }

    /// Refill the bucket and reset refill timing.
    pub fn reset(self: *RateLimiter) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.tokens = self.max_tokens;
        self.last_refill_ms = compat.milliTimestamp();
    }

    /// Return the current token count without forcing a refill calculation.
    pub fn available(self: *RateLimiter) f64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.tokens;
    }
};

/// Configuration for send-side rate limiting.
pub const RateLimitConfig = struct {
    /// Maximum allowed operations per second.
    max_per_second: u32,
    /// Reserved for future burst tuning. Current implementation uses
    /// `max_per_second` as both sustained rate and initial burst size.
    burst_size: ?u32 = null,
};

/// Configuration for send-side backpressure.
pub const BackpressureConfig = struct {
    /// Strategy to apply once `high_watermark` is reached.
    strategy: BackpressureStrategy,
    /// Queue depth at which backpressure starts.
    high_watermark: usize,
    /// Queue depth below which `.block` senders resume.
    low_watermark: usize,
};

/// Wrapper that applies flow control before delegating to an `Inbox`.
///
/// The wrapper does not own the wrapped inbox. Callers must keep the inbox
/// alive for the wrapper's lifetime and close the inbox through either the
/// wrapper or the original inbox pointer, but not both.
pub const FlowControlledInbox = struct {
    /// Wrapped inbox.
    inbox: *@import("./inbox.zig").Inbox,
    /// Optional limiter applied before each send.
    rate_limiter: ?RateLimiter,
    /// Optional backpressure policy.
    backpressure_config: ?BackpressureConfig,
    /// Allocator retained for future extensions and ABI consistency.
    allocator: std.mem.Allocator,

    /// Initialize a flow-control wrapper around an existing inbox.
    pub fn init(
        allocator: std.mem.Allocator,
        inbox: *@import("./inbox.zig").Inbox,
        rate_limit: ?RateLimitConfig,
        backpressure: ?BackpressureConfig,
    ) FlowControlledInbox {
        return .{
            .inbox = inbox,
            .rate_limiter = if (rate_limit) |rl| RateLimiter.init(rl.max_per_second) else null,
            .backpressure_config = backpressure,
            .allocator = allocator,
        };
    }

    /// Send a payload after applying rate-limit and backpressure rules.
    pub fn send(self: *FlowControlledInbox, payload: []const u8) !void {
        // Check rate limit
        if (self.rate_limiter) |*limiter| {
            if (!limiter.allow()) {
                return MessageError.RateLimitExceeded;
            }
        }

        // Check backpressure
        if (self.backpressure_config) |config| {
            const inbox_stats = self.inbox.stats();
            const current_count = inbox_stats.messages_received - inbox_stats.messages_sent;

            if (current_count >= config.high_watermark) {
                switch (config.strategy) {
                    .drop_oldest => {
                        // Try to receive and drop oldest
                        _ = self.inbox.recvTimeout(0) catch null;
                        // Then send new message
                        try self.inbox.send(payload);
                    },
                    .drop_newest => {
                        // Don't send, just drop
                        return;
                    },
                    .block => {
                        // Wait until below low watermark
                        while (true) {
                            const current_stats = self.inbox.stats();
                            const current = current_stats.messages_received - current_stats.messages_sent;
                            if (current < config.low_watermark) break;
                            compat.sleep(10 * std.time.ns_per_ms);
                        }
                        try self.inbox.send(payload);
                    },
                    .return_error => {
                        return MessageError.MailboxFull;
                    },
                }
            } else {
                try self.inbox.send(payload);
            }
        } else {
            try self.inbox.send(payload);
        }
    }

    /// Receive from the wrapped inbox.
    pub fn recv(self: *FlowControlledInbox) !Message {
        return self.inbox.recv();
    }

    /// Receive from the wrapped inbox with a timeout in milliseconds.
    pub fn recvTimeout(self: *FlowControlledInbox, timeout_ms: u32) !?Message {
        return self.inbox.recvTimeout(timeout_ms);
    }

    /// Close the wrapped inbox.
    ///
    /// After calling this, do not call `close()` on the original inbox pointer.
    pub fn close(self: *FlowControlledInbox) void {
        self.inbox.close();
    }

    /// Return statistics from the wrapped inbox.
    pub fn stats(self: *FlowControlledInbox) @import("../legacy.zig").MailboxStats {
        return self.inbox.stats();
    }
};

test "RateLimiter basic operations" {
    var limiter = RateLimiter.init(10); // 10 per second

    // Should allow first 10
    var allowed: u32 = 0;
    for (0..15) |_| {
        if (limiter.allow()) {
            allowed += 1;
        }
    }
    try std.testing.expect(allowed >= 10);
}

test "RateLimiter refill over time" {
    var limiter = RateLimiter.init(1000); // 1000 per second = 1 token per ms

    // Consume all tokens
    while (limiter.allow()) {}

    // Wait enough time for significant refill (200ms should give ~200 tokens)
    compat.sleep(200 * std.time.ns_per_ms);

    // Call allow() to trigger refill calculation, then check
    _ = limiter.allow();
    const avail = limiter.available();
    // With 1000/sec rate, 200ms should refill ~200 tokens (minus 1 for the allow call)
    try std.testing.expect(avail >= 50); // Conservative check to handle timing variance
}

test "FlowControlledInbox rate limiting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var inbox = try @import("./inbox.zig").inbox(allocator);
    defer inbox.close();

    var flow_inbox = FlowControlledInbox.init(
        allocator,
        inbox,
        .{ .max_per_second = 5 },
        null,
    );

    // Should allow some sends
    var success_count: u32 = 0;
    for (0..10) |_| {
        flow_inbox.send("test") catch {
            break;
        };
        success_count += 1;
    }
    try std.testing.expect(success_count > 0);
}

test "FlowControlledInbox backpressure drop_oldest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var inbox = try @import("./inbox.zig").inbox(allocator);
    defer inbox.close();

    var flow_inbox = FlowControlledInbox.init(
        allocator,
        inbox,
        null,
        .{
            .strategy = .drop_oldest,
            .high_watermark = 5,
            .low_watermark = 2,
        },
    );

    // Fill up to high watermark
    for (0..10) |_| {
        flow_inbox.send("test") catch {};
    }

    // Should still accept new messages (dropping oldest)
    try flow_inbox.send("new");
}
