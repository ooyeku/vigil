//! Topic-based pub/sub messaging for Vigil.
//!
//! A `PubSubBroker` delivers payloads to subscribers whose topic patterns
//! match the publish topic. Patterns use dot-separated topics with `*` for one
//! level and `#` for the remaining suffix, for example `orders.*` or
//! `orders.#`.

const std = @import("std");
const Message = @import("messages.zig").Message;
const Inbox = @import("api/inbox.zig").Inbox;
const telemetry = @import("telemetry.zig");
const compat = @import("compat.zig");

/// Result of a publish operation, reporting delivery outcomes.
pub const PublishResult = struct {
    /// Number of matching subscribers that accepted the payload.
    delivered: usize = 0,
    /// Number of matching subscribers whose inbox rejected the payload.
    failed: usize = 0,
};

/// Snapshot of one subscriber.
pub const SubscriberSnapshot = struct {
    /// Number of topic patterns registered on the subscriber.
    pattern_count: usize,
    /// Current queued message count for the subscriber inbox.
    queue_depth: usize,
    /// Whether the subscriber inbox has been closed.
    closed: bool,
};

/// Owned inspection of one subscriber, including its topic patterns.
pub const SubscriberInspection = struct {
    /// Copied topic pattern strings, owned by the enclosing snapshot.
    patterns: []const []const u8,
    /// Current queued message count for the subscriber inbox.
    queue_depth: usize,
    /// Whether the subscriber inbox has been closed.
    closed: bool,
};

/// Owned snapshot of broker subscribers and their subscriptions.
pub const PubSubBrokerSnapshot = struct {
    allocator: std.mem.Allocator,
    /// Number of subscriber pointers registered with the broker.
    subscriber_count: usize,
    /// Total topic patterns across all subscribers.
    total_pattern_count: usize,
    /// Lifetime published payload count.
    total_publishes: u64,
    /// Lifetime successful deliveries.
    total_delivered: u64,
    /// Lifetime failed deliveries.
    total_failed: u64,
    /// Per-subscriber inspections with copied patterns.
    subscribers: []SubscriberInspection,

    /// Release copied patterns and snapshot storage.
    pub fn deinit(self: *PubSubBrokerSnapshot) void {
        for (self.subscribers) |subscriber| {
            for (subscriber.patterns) |pattern| {
                self.allocator.free(pattern);
            }
            self.allocator.free(subscriber.patterns);
        }
        self.allocator.free(self.subscribers);
    }
};

/// Topic pattern used by a subscriber.
///
/// Pattern memory is owned by `Subscriber` when registered through
/// `Subscriber.subscribe`, which also precompiles the pattern into segments
/// so publishes avoid re-parsing it. A manually constructed `TopicPattern`
/// borrows its pattern slice and matches through the parsing fallback.
pub const TopicPattern = struct {
    /// Pattern text, such as `events.*` or `orders.#`.
    pattern: []const u8,
    /// Precompiled dot-separated segments pointing into `pattern`.
    ///
    /// Owned by the subscriber when set. Null for manually constructed
    /// patterns, which parse on every match instead.
    segments: ?[]const []const u8 = null,

    /// Return whether `topic` matches this pattern.
    ///
    /// `*` matches a single dot-delimited level. `#` matches the rest of the
    /// topic.
    pub fn matches(self: TopicPattern, topic: []const u8) bool {
        return matchPattern(self.pattern, topic);
    }
};

/// Maximum topic depth eligible for pre-split fast-path matching. Deeper
/// topics fall back to parse-per-match, which handles any depth.
const max_topic_segments = 32;

fn splitTopic(topic: []const u8, buffer: [][]const u8) ?[]const []const u8 {
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, topic, '.');
    while (it.next()) |segment| {
        if (count >= buffer.len) return null;
        buffer[count] = segment;
        count += 1;
    }
    return buffer[0..count];
}

fn matchPattern(pattern: []const u8, topic: []const u8) bool {
    var pattern_segments = std.mem.splitScalar(u8, pattern, '.');
    var topic_segments = std.mem.splitScalar(u8, topic, '.');

    while (pattern_segments.next()) |pattern_segment| {
        if (std.mem.eql(u8, pattern_segment, "#")) {
            // The multi-level wildcard is valid only as the final segment and
            // matches zero or more remaining topic levels.
            return pattern_segments.next() == null;
        }

        const topic_segment = topic_segments.next() orelse return false;
        if (std.mem.eql(u8, pattern_segment, "*")) {
            // A single-level wildcard must consume one non-empty level.
            if (topic_segment.len == 0) return false;
            continue;
        }

        if (!std.mem.eql(u8, pattern_segment, topic_segment)) return false;
    }

    return topic_segments.next() == null;
}

/// Compiled-segment matcher with identical semantics to `matchPattern`.
fn matchCompiled(pattern_segments: []const []const u8, topic_segments: []const []const u8) bool {
    var topic_index: usize = 0;
    for (pattern_segments, 0..) |pattern_segment, pattern_index| {
        if (std.mem.eql(u8, pattern_segment, "#")) {
            return pattern_index == pattern_segments.len - 1;
        }

        if (topic_index >= topic_segments.len) return false;
        const topic_segment = topic_segments[topic_index];
        if (std.mem.eql(u8, pattern_segment, "*")) {
            if (topic_segment.len == 0) return false;
            topic_index += 1;
            continue;
        }

        if (!std.mem.eql(u8, pattern_segment, topic_segment)) return false;
        topic_index += 1;
    }
    return topic_index == topic_segments.len;
}

/// Inbox-backed pub/sub subscriber.
///
/// The subscriber owns copied topic patterns. It does not own the inbox; the
/// inbox must outlive the subscriber and any broker registration.
pub const Subscriber = struct {
    /// Allocator for copied pattern storage.
    allocator: std.mem.Allocator,
    /// Destination inbox for matching publishes.
    inbox: *Inbox,
    /// Subscribed topic patterns.
    patterns: std.ArrayListUnmanaged(TopicPattern),
    /// Protects the pattern list.
    mutex: compat.Mutex,

    /// Initialize a subscriber for an existing inbox.
    pub fn init(allocator: std.mem.Allocator, inbox: *Inbox) Subscriber {
        return .{
            .allocator = allocator,
            .inbox = inbox,
            .patterns = .empty,
            .mutex = .{},
        };
    }

    /// Release copied topic patterns.
    pub fn deinit(self: *Subscriber) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.patterns.items) |pattern| {
            if (pattern.segments) |segments| self.allocator.free(segments);
            self.allocator.free(pattern.pattern);
        }
        self.patterns.deinit(self.allocator);
    }

    /// Add topic patterns to this subscriber.
    ///
    /// Each pattern is copied and precompiled into segments so publish-time
    /// matching avoids re-parsing. Calling this more than once appends
    /// additional patterns.
    pub fn subscribe(self: *Subscriber, patterns: []const []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const original_len = self.patterns.items.len;
        errdefer while (self.patterns.items.len > original_len) {
            const removed = self.patterns.pop().?;
            if (removed.segments) |segments| self.allocator.free(segments);
            self.allocator.free(removed.pattern);
        };

        for (patterns) |pattern| {
            const pattern_copy = try self.allocator.dupe(u8, pattern);
            errdefer self.allocator.free(pattern_copy);

            const segment_count = std.mem.count(u8, pattern_copy, ".") + 1;
            const segments = try self.allocator.alloc([]const u8, segment_count);
            errdefer self.allocator.free(segments);

            var it = std.mem.splitScalar(u8, pattern_copy, '.');
            var index: usize = 0;
            while (it.next()) |segment| : (index += 1) {
                segments[index] = segment;
            }

            try self.patterns.append(self.allocator, .{
                .pattern = pattern_copy,
                .segments = segments,
            });
        }
    }

    /// Return true when any subscribed pattern matches `topic`.
    pub fn matches(self: *Subscriber, topic: []const u8) bool {
        return self.matchesPreSplit(topic, null);
    }

    /// Like `matches`, but reuses an already-split topic when available so
    /// batch fanout parses the topic once for every subscriber and pattern.
    fn matchesPreSplit(self: *Subscriber, topic: []const u8, topic_segments: ?[]const []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.patterns.items) |pattern| {
            if (pattern.segments) |pattern_segments| {
                if (topic_segments) |split| {
                    if (matchCompiled(pattern_segments, split)) return true;
                    continue;
                }
            }
            if (pattern.matches(topic)) return true;
        }
        return false;
    }

    /// Return a value snapshot of subscriber state.
    pub fn snapshot(self: *Subscriber) SubscriberSnapshot {
        self.mutex.lock();
        defer self.mutex.unlock();

        return .{
            .pattern_count = self.patterns.items.len,
            .queue_depth = self.inbox.mailbox.queuedCount(),
            .closed = self.inbox.isClosed(),
        };
    }

    /// Return owned copies of the subscribed topic patterns.
    ///
    /// The caller owns the returned slice and each pattern string.
    pub fn snapshotPatterns(self: *Subscriber, allocator: std.mem.Allocator) ![]const []const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const patterns = try allocator.alloc([]const u8, self.patterns.items.len);
        errdefer allocator.free(patterns);

        var written: usize = 0;
        errdefer for (patterns[0..written]) |pattern| {
            allocator.free(pattern);
        };

        for (self.patterns.items) |pattern| {
            patterns[written] = try allocator.dupe(u8, pattern.pattern);
            written += 1;
        }
        return patterns;
    }
};

/// Thread-safe broker for topic-based fanout.
///
/// The broker tracks subscriber pointers but does not own subscriber objects or
/// their inboxes. Unsubscribe or deinitialize the broker before destroying
/// subscribers.
pub const PubSubBroker = struct {
    /// Allocator for subscriber pointer storage.
    allocator: std.mem.Allocator,
    /// Registered subscriber pointers.
    subscribers: std.ArrayListUnmanaged(*Subscriber),
    /// Optional emitter for delivery-failure events. Not owned.
    telemetry_emitter: ?*telemetry.TelemetryEmitter,
    /// Protects subscriber registration.
    mutex: compat.Mutex,
    /// Lifetime publish operations.
    total_publishes: std.atomic.Value(u64),
    /// Lifetime successful deliveries across all publishes.
    total_delivered: std.atomic.Value(u64),
    /// Lifetime failed deliveries across all publishes.
    total_failed: std.atomic.Value(u64),

    /// Initialize an empty broker.
    pub fn init(allocator: std.mem.Allocator) PubSubBroker {
        return .{
            .allocator = allocator,
            .subscribers = .empty,
            .telemetry_emitter = null,
            .mutex = .{},
            .total_publishes = std.atomic.Value(u64).init(0),
            .total_delivered = std.atomic.Value(u64).init(0),
            .total_failed = std.atomic.Value(u64).init(0),
        };
    }

    /// Attach an emitter for delivery-failure events. Not owned.
    pub fn setTelemetryEmitter(self: *PubSubBroker, emitter: ?*telemetry.TelemetryEmitter) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.telemetry_emitter = emitter;
    }

    /// Release broker-owned subscriber pointer storage.
    ///
    /// Subscribers themselves are not deinitialized.
    pub fn deinit(self: *PubSubBroker) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.subscribers.deinit(self.allocator);
    }

    /// Register a subscriber pointer with the broker.
    pub fn subscribe(self: *PubSubBroker, subscriber: *Subscriber) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.subscribers.items) |existing| {
            if (existing == subscriber) return;
        }
        try self.subscribers.append(self.allocator, subscriber);
    }

    /// Unregister a subscriber pointer if present.
    pub fn unsubscribe(self: *PubSubBroker, subscriber: *Subscriber) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.subscribers.items, 0..) |sub, i| {
            if (sub == subscriber) {
                _ = self.subscribers.orderedRemove(i);
                return;
            }
        }
    }

    /// Publish a message to all matching subscribers.
    ///
    /// Returns a `PublishResult` with delivery/failure counts.
    /// Emits `message_dropped` telemetry events for each failed delivery.
    /// Delivery is best-effort: one failed subscriber does not stop delivery to
    /// other subscribers.
    pub fn publish(self: *PubSubBroker, topic: []const u8, payload: []const u8) !PublishResult {
        return self.publishBatch(topic, &.{payload});
    }

    /// Publish several payloads to one topic, matching each subscriber once.
    ///
    /// The subscriber set is snapshotted once and the topic parsed once for
    /// the whole batch, so publishing N payloads costs one matching pass
    /// instead of N. Delivery semantics match `publish()` per payload.
    pub fn publishBatch(
        self: *PubSubBroker,
        topic: []const u8,
        payloads: []const []const u8,
    ) !PublishResult {
        // Snapshot registered subscribers without allocating for typical
        // broker sizes, so registration changes cannot invalidate iteration.
        var stack_snapshot: [32]*Subscriber = undefined;
        var heap_snapshot: ?[]*Subscriber = null;

        self.mutex.lock();
        const count = self.subscribers.items.len;
        const subscribers_copy: []const *Subscriber = if (count <= stack_snapshot.len) blk: {
            @memcpy(stack_snapshot[0..count], self.subscribers.items);
            break :blk stack_snapshot[0..count];
        } else blk: {
            const copy = self.allocator.alloc(*Subscriber, count) catch {
                self.mutex.unlock();
                return error.OutOfMemory;
            };
            @memcpy(copy, self.subscribers.items);
            heap_snapshot = copy;
            break :blk copy;
        };
        self.mutex.unlock();
        defer if (heap_snapshot) |copy| self.allocator.free(copy);

        // Parse the topic once for the whole fanout.
        var segment_buffer: [max_topic_segments][]const u8 = undefined;
        const topic_segments = splitTopic(topic, &segment_buffer);

        var result = PublishResult{};
        for (subscribers_copy) |subscriber| {
            if (!subscriber.matchesPreSplit(topic, topic_segments)) continue;

            for (payloads) |payload| {
                subscriber.inbox.send(payload) catch {
                    result.failed += 1;
                    // Emit telemetry for failed delivery
                    if (self.telemetry_emitter) |t| {
                        t.emit(.{
                            .event_type = .message_dropped,
                            .timestamp_ms = compat.milliTimestamp(),
                            .metadata = topic,
                        });
                    }
                    continue;
                };
                result.delivered += 1;
            }
        }

        _ = self.total_publishes.fetchAdd(payloads.len, .monotonic);
        _ = self.total_delivered.fetchAdd(result.delivered, .monotonic);
        _ = self.total_failed.fetchAdd(result.failed, .monotonic);
        return result;
    }

    /// Capture an owned snapshot of broker subscribers.
    ///
    /// Subscribers and their inboxes must remain alive while this function
    /// runs. The caller owns the returned snapshot and must call `deinit()`.
    pub fn snapshot(self: *PubSubBroker, allocator: std.mem.Allocator) !PubSubBrokerSnapshot {
        self.mutex.lock();
        const subscribers_copy = allocator.alloc(*Subscriber, self.subscribers.items.len) catch {
            self.mutex.unlock();
            return error.OutOfMemory;
        };
        @memcpy(subscribers_copy, self.subscribers.items);
        self.mutex.unlock();
        defer allocator.free(subscribers_copy);

        const subscribers = try allocator.alloc(SubscriberInspection, subscribers_copy.len);
        errdefer allocator.free(subscribers);

        var written: usize = 0;
        errdefer for (subscribers[0..written]) |inspection| {
            for (inspection.patterns) |pattern| allocator.free(pattern);
            allocator.free(inspection.patterns);
        };

        var total_pattern_count: usize = 0;
        for (subscribers_copy) |subscriber| {
            const subscriber_snapshot = subscriber.snapshot();
            const patterns = try subscriber.snapshotPatterns(allocator);
            subscribers[written] = .{
                .patterns = patterns,
                .queue_depth = subscriber_snapshot.queue_depth,
                .closed = subscriber_snapshot.closed,
            };
            written += 1;
            total_pattern_count += patterns.len;
        }

        return .{
            .allocator = allocator,
            .subscriber_count = subscribers.len,
            .total_pattern_count = total_pattern_count,
            .total_publishes = self.total_publishes.load(.monotonic),
            .total_delivered = self.total_delivered.load(.monotonic),
            .total_failed = self.total_failed.load(.monotonic),
            .subscribers = subscribers,
        };
    }
};

test "TopicPattern matching" {
    const pattern = TopicPattern{ .pattern = "events.*" };
    try std.testing.expect(pattern.matches("events.user"));
    try std.testing.expect(pattern.matches("events.system"));
    try std.testing.expect(!pattern.matches("events.user.created"));

    const multi_pattern = TopicPattern{ .pattern = "events.#" };
    try std.testing.expect(multi_pattern.matches("events.user.created"));
    try std.testing.expect(multi_pattern.matches("events.system.alerts"));
    try std.testing.expect(multi_pattern.matches("events"));

    try std.testing.expect(!pattern.matches("events."));
    try std.testing.expect(!(TopicPattern{ .pattern = "events.#.invalid" }).matches("events.any.invalid"));
    try std.testing.expect(!(TopicPattern{ .pattern = "ev*nts.user" }).matches("events.user"));
}

test "Subscriber subscribe rolls back partial allocation failure" {
    const allocator = std.testing.allocator;
    var inbox = try Inbox.init(allocator);
    defer inbox.close();

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 2 });
    var subscriber = Subscriber.init(failing.allocator(), inbox);
    defer subscriber.deinit();

    try std.testing.expectError(error.OutOfMemory, subscriber.subscribe(&.{ "one", "two" }));
    try std.testing.expectEqual(@as(usize, 0), subscriber.patterns.items.len);
}

test "PubSubBroker ignores duplicate subscriber registration" {
    const allocator = std.testing.allocator;
    var broker = PubSubBroker.init(allocator);
    defer broker.deinit();
    var inbox = try Inbox.init(allocator);
    defer inbox.close();
    var subscriber = Subscriber.init(allocator, inbox);
    defer subscriber.deinit();
    try subscriber.subscribe(&.{"events.#"});

    try broker.subscribe(&subscriber);
    try broker.subscribe(&subscriber);
    const result = try broker.publish("events.created", "once");
    try std.testing.expectEqual(@as(usize, 1), result.delivered);
    try std.testing.expectEqual(@as(usize, 1), inbox.mailbox.queuedCount());
}

test "PubSubBroker publish/subscribe" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var broker = PubSubBroker.init(allocator);
    defer broker.deinit();

    var inbox1 = try Inbox.init(allocator);
    defer inbox1.close();

    var inbox2 = try Inbox.init(allocator);
    defer inbox2.close();

    var sub1 = Subscriber.init(allocator, inbox1);
    defer sub1.deinit();
    try sub1.subscribe(&[_][]const u8{"events.user.*"});

    var sub2 = Subscriber.init(allocator, inbox2);
    defer sub2.deinit();
    try sub2.subscribe(&[_][]const u8{"events.system.*"});

    try broker.subscribe(&sub1);
    try broker.subscribe(&sub2);

    const user_result = try broker.publish("events.user.created", "user123");
    try std.testing.expectEqual(@as(usize, 1), user_result.delivered);
    try std.testing.expectEqual(@as(usize, 0), user_result.failed);

    const sys_result = try broker.publish("events.system.alert", "alert1");
    try std.testing.expectEqual(@as(usize, 1), sys_result.delivered);
    try std.testing.expectEqual(@as(usize, 0), sys_result.failed);

    // Check inbox1 received user event
    if (try inbox1.recvTimeout(100)) |msg| {
        defer msg.deinit();
        try std.testing.expectEqualSlices(u8, "user123", msg.payload.?);
    }

    // Check inbox2 received system event
    if (try inbox2.recvTimeout(100)) |msg| {
        defer msg.deinit();
        try std.testing.expectEqualSlices(u8, "alert1", msg.payload.?);
    }
}

test "PubSubBroker snapshot reports subscribers and pattern counts" {
    const allocator = std.testing.allocator;

    var broker = PubSubBroker.init(allocator);
    defer broker.deinit();

    var inbox = try Inbox.init(allocator);
    defer inbox.close();

    var subscriber = Subscriber.init(allocator, inbox);
    defer subscriber.deinit();
    try subscriber.subscribe(&[_][]const u8{ "orders.*", "system.#" });

    try broker.subscribe(&subscriber);

    var snapshot = try broker.snapshot(allocator);
    defer snapshot.deinit();

    try std.testing.expectEqual(@as(usize, 1), snapshot.subscriber_count);
    try std.testing.expectEqual(@as(usize, 2), snapshot.total_pattern_count);
    try std.testing.expectEqual(@as(usize, 1), snapshot.subscribers.len);
    try std.testing.expectEqual(@as(usize, 2), snapshot.subscribers[0].patterns.len);
    try std.testing.expectEqualStrings("orders.*", snapshot.subscribers[0].patterns[0]);
    try std.testing.expectEqualStrings("system.#", snapshot.subscribers[0].patterns[1]);
    try std.testing.expectEqual(@as(usize, 0), snapshot.subscribers[0].queue_depth);
    try std.testing.expect(!snapshot.subscribers[0].closed);
}

test "PubSubBroker fanout stress reports all deliveries" {
    const allocator = std.testing.allocator;
    const subscriber_count = 3;
    const iterations = 32;

    var broker = PubSubBroker.init(allocator);
    defer broker.deinit();

    var inboxes: [subscriber_count]*Inbox = undefined;
    var subscribers: [subscriber_count]Subscriber = undefined;

    for (&inboxes, &subscribers) |*inbox_slot, *subscriber_slot| {
        inbox_slot.* = try Inbox.init(allocator);
        subscriber_slot.* = Subscriber.init(allocator, inbox_slot.*);
        try subscriber_slot.subscribe(&[_][]const u8{"stress.#"});
        try broker.subscribe(subscriber_slot);
    }
    defer for (&subscribers) |*subscriber| {
        subscriber.deinit();
    };
    defer for (inboxes) |inbox| {
        inbox.close();
    };

    var delivered: usize = 0;
    for (0..iterations) |_| {
        const result = try broker.publish("stress.event", "payload");
        delivered += result.delivered;
        try std.testing.expectEqual(@as(usize, 0), result.failed);
    }

    try std.testing.expectEqual(@as(usize, subscriber_count * iterations), delivered);
    for (inboxes) |inbox| {
        try std.testing.expectEqual(iterations, inbox.mailbox.queuedCount());
    }
}

test "pubsub property: generated topics match themselves and wildcard forms" {
    var prng = std.Random.DefaultPrng.init(0x70b1_c5);
    const random = prng.random();

    const segment_alphabet = "abcdefghijklmnopqrstuvwxyz0123456789";
    var topic_buffer: [128]u8 = undefined;
    var pattern_buffer: [128]u8 = undefined;

    for (0..500) |_| {
        // Build a random topic of 1..5 non-empty segments.
        const segment_count = 1 + random.uintLessThan(usize, 5);
        var topic_len: usize = 0;
        var last_segment_start: usize = 0;
        for (0..segment_count) |segment_index| {
            if (segment_index != 0) {
                topic_buffer[topic_len] = '.';
                topic_len += 1;
            }
            last_segment_start = topic_len;
            const segment_len = 1 + random.uintLessThan(usize, 8);
            for (0..segment_len) |_| {
                topic_buffer[topic_len] = segment_alphabet[random.uintLessThan(usize, segment_alphabet.len)];
                topic_len += 1;
            }
        }
        const topic = topic_buffer[0..topic_len];

        // A topic always matches itself as an exact pattern.
        try std.testing.expect(matchPattern(topic, topic));

        // Replacing the final segment with `*` still matches.
        const star_len = last_segment_start + 1;
        @memcpy(pattern_buffer[0..last_segment_start], topic[0..last_segment_start]);
        pattern_buffer[last_segment_start] = '*';
        try std.testing.expect(matchPattern(pattern_buffer[0..star_len], topic));

        // `*` must not match across additional levels.
        const extended = try std.fmt.bufPrint(topic_buffer[topic_len..], ".extra", .{});
        try std.testing.expect(!matchPattern(
            pattern_buffer[0..star_len],
            topic_buffer[0 .. topic_len + extended.len],
        ));

        // A `#` suffix matches the topic and any deeper topic.
        if (last_segment_start > 0) {
            pattern_buffer[last_segment_start] = '#';
            const hash_pattern = pattern_buffer[0..star_len];
            try std.testing.expect(matchPattern(hash_pattern, topic));
            try std.testing.expect(matchPattern(hash_pattern, topic_buffer[0 .. topic_len + extended.len]));
        }
    }
}

test "PubSubBroker publishBatch matches once and reports counters" {
    const allocator = std.testing.allocator;

    var broker = PubSubBroker.init(allocator);
    defer broker.deinit();

    var inbox = try Inbox.init(allocator);
    defer inbox.close();
    var subscriber = Subscriber.init(allocator, inbox);
    defer subscriber.deinit();
    try subscriber.subscribe(&.{"orders.#"});
    try broker.subscribe(&subscriber);

    var other_inbox = try Inbox.init(allocator);
    defer other_inbox.close();
    var other = Subscriber.init(allocator, other_inbox);
    defer other.deinit();
    try other.subscribe(&.{"alerts.#"});
    try broker.subscribe(&other);

    const payloads = [_][]const u8{ "created", "paid", "shipped" };
    const result = try broker.publishBatch("orders.lifecycle", &payloads);
    try std.testing.expectEqual(@as(usize, 3), result.delivered);
    try std.testing.expectEqual(@as(usize, 0), result.failed);
    try std.testing.expectEqual(@as(usize, 3), inbox.mailbox.queuedCount());
    try std.testing.expectEqual(@as(usize, 0), other_inbox.mailbox.queuedCount());

    var snapshot = try broker.snapshot(allocator);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(u64, 3), snapshot.total_publishes);
    try std.testing.expectEqual(@as(u64, 3), snapshot.total_delivered);
    try std.testing.expectEqual(@as(u64, 0), snapshot.total_failed);
}

test "pubsub property: compiled matching agrees with parsed matching" {
    var prng = std.Random.DefaultPrng.init(0xc0_1d5eed);
    const random = prng.random();

    var pattern_buffer: [64]u8 = undefined;
    var topic_buffer: [64]u8 = undefined;

    for (0..1000) |_| {
        // Random small patterns and topics with wildcards sprinkled in, so
        // both matchers see matching and non-matching cases.
        const pattern_len = buildRandomTopic(random, &pattern_buffer, true);
        const topic_len = buildRandomTopic(random, &topic_buffer, false);
        const pattern = pattern_buffer[0..pattern_len];
        const topic = topic_buffer[0..topic_len];

        var pattern_segment_buffer: [max_topic_segments][]const u8 = undefined;
        var topic_segment_buffer: [max_topic_segments][]const u8 = undefined;
        const pattern_segments = splitTopic(pattern, &pattern_segment_buffer).?;
        const topic_segments = splitTopic(topic, &topic_segment_buffer).?;

        try std.testing.expectEqual(
            matchPattern(pattern, topic),
            matchCompiled(pattern_segments, topic_segments),
        );
    }
}

fn buildRandomTopic(random: std.Random, buffer: []u8, allow_wildcards: bool) usize {
    const segment_alphabet = "abcz";
    const segment_count = 1 + random.uintLessThan(usize, 4);
    var len: usize = 0;
    for (0..segment_count) |i| {
        if (i != 0) {
            buffer[len] = '.';
            len += 1;
        }
        if (allow_wildcards and random.uintLessThan(u8, 4) == 0) {
            buffer[len] = if (random.boolean()) '*' else '#';
            len += 1;
            continue;
        }
        const seg_len = 1 + random.uintLessThan(usize, 3);
        for (0..seg_len) |_| {
            buffer[len] = segment_alphabet[random.uintLessThan(usize, segment_alphabet.len)];
            len += 1;
        }
    }
    return len;
}
