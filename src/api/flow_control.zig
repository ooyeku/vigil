//! Flow control primitives for Vigil
//! Provides rate limiting and backpressure handling.

const std = @import("std");
const Message = @import("../messages.zig").Message;
const MessageError = @import("../messages.zig").MessageError;

/// Backpressure strategy when limits are exceeded
pub const BackpressureStrategy = enum {
    /// Drop oldest messages when full
    drop_oldest,
    /// Drop newest messages when full
    drop_newest,
    /// Block until space available
    block,
    /// Return error immediately
    return_error,
};

/// Rate limiter using token bucket algorithm
pub const RateLimiter = struct {
    tokens: f64,
    max_tokens: f64,
    refill_rate: f64, // tokens per millisecond
    last_refill_ms: i64,
    mutex: std.Thread.Mutex,

    /// Initialize a rate limiter
    /// max_per_second: Maximum number of operations per second
    pub fn init(max_per_second: u32) RateLimiter {
        const tokens_per_ms = @as(f64, @floatFromInt(max_per_second)) / 1000.0;
        return .{
            .tokens = @as(f64, @floatFromInt(max_per_second)),
            .max_tokens = @as(f64, @floatFromInt(max_per_second)),
            .refill_rate = tokens_per_ms,
            .last_refill_ms = std.time.milliTimestamp(),
            .mutex = .{},
        };
    }

    /// Check if an operation is allowed and consume a token
    pub fn allow(self: *RateLimiter) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now_ms = std.time.milliTimestamp();
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

    /// Reset the rate limiter
    pub fn reset(self: *RateLimiter) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.tokens = self.max_tokens;
        self.last_refill_ms = std.time.milliTimestamp();
    }

    /// Get current available tokens
    pub fn available(self: *RateLimiter) f64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.tokens;
    }
};

/// Rate limit configuration
pub const RateLimitConfig = struct {
    max_per_second: u32,
    burst_size: ?u32 = null, // Optional burst allowance
};

/// Backpressure configuration
pub const BackpressureConfig = struct {
    strategy: BackpressureStrategy,
    high_watermark: usize, // Start applying strategy at this count
    low_watermark: usize, // Resume normal operation below this count
};

/// Flow-controlled inbox wrapper
pub const FlowControlledInbox = struct {
    inbox: *@import("./inbox.zig").Inbox,
    rate_limiter: ?RateLimiter,
    backpressure_config: ?BackpressureConfig,
    allocator: std.mem.Allocator,

    /// Initialize flow-controlled inbox
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

    /// Send with flow control
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
                            std.Thread.sleep(10 * std.time.ns_per_ms);
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

    /// Receive (delegates to inbox)
    pub fn recv(self: *FlowControlledInbox) !Message {
        return self.inbox.recv();
    }

    /// Receive with timeout (delegates to inbox)
    pub fn recvTimeout(self: *FlowControlledInbox, timeout_ms: u32) !?Message {
        return self.inbox.recvTimeout(timeout_ms);
    }

    /// Close (delegates to inbox)
    pub fn close(self: *FlowControlledInbox) void {
        self.inbox.close();
    }

    /// Get stats (delegates to inbox)
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
    std.Thread.sleep(200 * std.time.ns_per_ms);

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
