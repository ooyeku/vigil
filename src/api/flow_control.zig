//! Flow control primitives for Vigil.
//!
//! Use these APIs when producers can temporarily outpace consumers. A
//! `RateLimiter` caps operation frequency, while backpressure policies define
//! what an inbox should do once queued work crosses a high-water mark. Both
//! are applied through the inbox builder (`withRateLimit`, `withBackpressure`)
//! and observed through `Inbox.flowMetrics()`.

const std = @import("std");
const messages = @import("../messages.zig");
const Message = messages.Message;
const MessageError = messages.MessageError;
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
    /// Slow producers progressively as the queue grows: between the low and
    /// high watermarks senders are delayed proportionally to queue fill, and
    /// at the high watermark they block until work drains below the low
    /// watermark.
    adaptive,
};

/// Lock-free rate limiter (GCRA / virtual-scheduling token bucket).
///
/// The limiter tracks one atomic "theoretical arrival time"; `allow()` and
/// `allowN()` are a load, a comparison, and a compare-and-swap — no mutex and
/// no per-call allocation. The bucket starts full, so a new limiter permits an
/// initial burst up to its burst size, then refills continuously over time.
pub const RateLimiter = struct {
    /// GCRA virtual time: the earliest instant (µs, monotonic) at which the
    /// limiter is fully drained of outstanding work.
    tat_us: std.atomic.Value(i64),
    /// Cost of one operation in microseconds.
    increment_us: i64,
    /// Burst tolerance in microseconds: `(burst - 1) * increment_us`.
    tolerance_us: i64,
    /// Configured burst size, retained for `available()`.
    burst: u32,

    /// Initialize a limiter for `max_per_second` sustained operations with a
    /// burst size equal to one second of allowance.
    pub fn init(max_per_second: u32) RateLimiter {
        return initBurst(max_per_second, max_per_second);
    }

    /// Initialize a limiter for `max_per_second` sustained operations that
    /// permits at most `burst` operations back to back.
    ///
    /// Rates above one million per second are clamped to the microsecond
    /// resolution of the limiter clock.
    pub fn initBurst(max_per_second: u32, burst: u32) RateLimiter {
        const rate = @max(@as(u32, 1), max_per_second);
        const effective_burst = @max(@as(u32, 1), burst);
        const increment_us = @max(@as(i64, 1), @divTrunc(@as(i64, std.time.us_per_s), rate));
        return .{
            .tat_us = std.atomic.Value(i64).init(nowUs()),
            .increment_us = increment_us,
            .tolerance_us = @as(i64, effective_burst - 1) * increment_us,
            .burst = effective_burst,
        };
    }

    fn nowUs() i64 {
        return compat.monotonicMilliTimestamp() *| std.time.us_per_ms;
    }

    /// Try to consume one token.
    ///
    /// Returns true when the operation may proceed, false when the caller
    /// should drop, retry later, or return a rate-limit error.
    pub fn allow(self: *RateLimiter) bool {
        return self.allowN(1);
    }

    /// Try to consume `n` tokens at once for a batch of operations.
    ///
    /// All-or-nothing: either the whole batch is admitted or no allowance is
    /// consumed. Batches larger than the burst size can never be admitted.
    pub fn allowN(self: *RateLimiter, n: u32) bool {
        if (n == 0) return true;

        const cost = @as(i64, n) * self.increment_us;
        const now = nowUs();
        var tat = self.tat_us.load(.monotonic);
        while (true) {
            const base = @max(tat, now);
            // Conforming when the last token of the batch still falls inside
            // the burst tolerance window.
            if (base + cost - self.increment_us > now + self.tolerance_us) return false;
            tat = self.tat_us.cmpxchgWeak(
                tat,
                base + cost,
                .acq_rel,
                .monotonic,
            ) orelse return true;
        }
    }

    /// Refill the bucket to its full burst allowance.
    pub fn reset(self: *RateLimiter) void {
        self.tat_us.store(nowUs(), .release);
    }

    /// Return the approximate number of operations that would currently be
    /// admitted back to back.
    pub fn available(self: *RateLimiter) f64 {
        const now = nowUs();
        const tat = self.tat_us.load(.monotonic);
        const headroom = now + self.tolerance_us - @max(tat, now);
        if (headroom < 0) return 0;
        const tokens = @divTrunc(headroom, self.increment_us) + 1;
        return @floatFromInt(@min(tokens, @as(i64, self.burst)));
    }
};

/// Configuration for send-side rate limiting.
pub const RateLimitConfig = struct {
    /// Maximum allowed operations per second.
    max_per_second: u32,
    /// Maximum operations admitted back to back. Defaults to
    /// `max_per_second` (one second of allowance) when null.
    burst_size: ?u32 = null,

    /// Build a limiter honoring the configured burst size.
    pub fn limiter(self: RateLimitConfig) RateLimiter {
        return RateLimiter.initBurst(
            self.max_per_second,
            self.burst_size orelse self.max_per_second,
        );
    }
};

/// Configuration for send-side backpressure.
pub const BackpressureConfig = struct {
    /// Strategy to apply once `high_watermark` is reached.
    strategy: BackpressureStrategy,
    /// Queue depth at which backpressure starts.
    high_watermark: usize,
    /// Queue depth below which `.block` and `.adaptive` senders resume.
    low_watermark: usize,
    /// Maximum per-send delay applied by `.adaptive` as the queue approaches
    /// the high watermark.
    max_delay_ms: u32 = 10,
};

/// Counters describing what flow control did to sends.
///
/// Producer overload shows up here (throttled, delayed, blocked, dropped);
/// consumer failure is handled separately by the dead-letter and poison
/// machinery on the inbox itself.
pub const FlowControlMetrics = struct {
    /// Sends that reached the inbox.
    accepted: u64 = 0,
    /// Sends rejected by the rate limiter.
    throttled: u64 = 0,
    /// Sends that displaced the oldest queued message.
    dropped_oldest: u64 = 0,
    /// Sends silently discarded by `drop_newest`.
    dropped_newest: u64 = 0,
    /// Sends rejected with `MailboxFull` by `return_error`.
    rejected: u64 = 0,
    /// Sends that blocked waiting for the queue to drain.
    blocked: u64 = 0,
    /// Sends slowed by the adaptive strategy's progressive delay.
    delayed: u64 = 0,
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

test "RateLimiter allowN admits batches all-or-nothing" {
    var limiter = RateLimiter.init(10);

    try std.testing.expect(limiter.allowN(0));
    try std.testing.expect(limiter.allowN(4));
    try std.testing.expect(limiter.allowN(4));
    // Only 2 tokens left; a batch of 4 must not consume anything.
    try std.testing.expect(!limiter.allowN(4));
    try std.testing.expect(limiter.allowN(2));
    try std.testing.expect(!limiter.allow());

    limiter.reset();
    try std.testing.expect(limiter.allowN(10));
    // Batches larger than the burst can never be admitted.
    var fresh = RateLimiter.init(4);
    try std.testing.expect(!fresh.allowN(5));
}

test "RateLimiter honors a burst size smaller than the sustained rate" {
    var limiter = RateLimiter.initBurst(1_000, 3);

    var allowed: u32 = 0;
    for (0..10) |_| {
        if (limiter.allow()) allowed += 1;
    }
    // Only the burst is admitted back to back, despite the 1000/s rate.
    try std.testing.expect(allowed <= 4);
    try std.testing.expect(allowed >= 3);

    const config = RateLimitConfig{ .max_per_second = 1_000, .burst_size = 3 };
    var from_config = config.limiter();
    try std.testing.expect(from_config.allowN(3));
}

test "Inbox adaptive backpressure delays, blocks, and reports flow metrics" {
    const allocator = std.testing.allocator;
    const inbox_api = @import("./inbox.zig");
    var inbox = try inbox_api.inboxBuilder(allocator).capacity(16).withBackpressure(.{
        .strategy = .adaptive,
        .high_watermark = 6,
        .low_watermark = 2,
        .max_delay_ms = 1,
    }).build();
    defer inbox.close();

    // Below the low watermark: no delay recorded.
    try inbox.send("m1");
    try inbox.send("m2");
    try std.testing.expectEqual(@as(u64, 0), inbox.flowMetrics().delayed);

    // Inside the pressure band: sends are delayed but accepted.
    try inbox.send("m3");
    try inbox.send("m4");
    const banded = inbox.flowMetrics();
    try std.testing.expectEqual(@as(u64, 2), banded.delayed);
    try std.testing.expectEqual(@as(u64, 4), banded.accepted);

    // At the high watermark a sender blocks until a consumer drains the
    // queue below the low watermark.
    try inbox.send("m5");
    try inbox.send("m6");

    const Drainer = struct {
        fn run(target: *inbox_api.Inbox) void {
            compat.sleep(20 * std.time.ns_per_ms);
            for (0..5) |_| {
                const msg = target.recvTimeout(100) catch return orelse return;
                msg.deinit();
            }
        }
    };
    const drainer = try std.Thread.spawn(.{}, Drainer.run, .{inbox});
    try inbox.send("m7");
    drainer.join();

    const final = inbox.flowMetrics();
    try std.testing.expectEqual(@as(u64, 1), final.blocked);
    try std.testing.expectEqual(@as(u64, 7), final.accepted);
}

test "Inbox records throttled and rejected sends in flow metrics" {
    const allocator = std.testing.allocator;
    const inbox_api = @import("./inbox.zig");

    // A slow rate keeps the refill interval (100ms) far larger than the test
    // duration, so the third send deterministically exceeds the burst.
    var throttled = try inbox_api.inboxBuilder(allocator).capacity(16).withRateLimit(.{
        .max_per_second = 10,
        .burst_size = 2,
    }).build();
    defer throttled.close();
    try throttled.send("a");
    try throttled.send("b");
    try std.testing.expectError(MessageError.RateLimitExceeded, throttled.send("c"));
    const throttled_metrics = throttled.flowMetrics();
    try std.testing.expectEqual(@as(u64, 2), throttled_metrics.accepted);
    try std.testing.expectEqual(@as(u64, 1), throttled_metrics.throttled);

    var rejecting = try inbox_api.inboxBuilder(allocator).capacity(16).withBackpressure(.{
        .strategy = .return_error,
        .high_watermark = 2,
        .low_watermark = 1,
    }).build();
    defer rejecting.close();
    try rejecting.send("d");
    try rejecting.send("e");
    try std.testing.expectError(MessageError.MailboxFull, rejecting.send("f"));
    const rejecting_metrics = rejecting.flowMetrics();
    try std.testing.expectEqual(@as(u64, 2), rejecting_metrics.accepted);
    try std.testing.expectEqual(@as(u64, 1), rejecting_metrics.rejected);
}
