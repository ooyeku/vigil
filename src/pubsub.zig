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

/// Topic pattern used by a subscriber.
///
/// Pattern memory is owned by `Subscriber` when registered through
/// `Subscriber.subscribe`. A manually constructed `TopicPattern` borrows its
/// pattern slice.
pub const TopicPattern = struct {
    /// Pattern text, such as `events.*` or `orders.#`.
    pattern: []const u8,

    /// Return whether `topic` matches this pattern.
    ///
    /// `*` matches a single dot-delimited level. `#` matches the rest of the
    /// topic.
    pub fn matches(self: TopicPattern, topic: []const u8) bool {
        return matchPattern(self.pattern, topic);
    }
};

fn matchPattern(pattern: []const u8, topic: []const u8) bool {
    var pattern_idx: usize = 0;
    var topic_idx: usize = 0;

    while (pattern_idx < pattern.len and topic_idx < topic.len) {
        if (pattern[pattern_idx] == '*') {
            // Single level wildcard - match until next separator
            pattern_idx += 1;
            while (topic_idx < topic.len and topic[topic_idx] != '.') {
                topic_idx += 1;
            }
        } else if (pattern[pattern_idx] == '#') {
            // Multi-level wildcard - match rest
            return true;
        } else if (pattern[pattern_idx] == topic[topic_idx]) {
            pattern_idx += 1;
            topic_idx += 1;
        } else {
            return false;
        }
    }

    return pattern_idx == pattern.len and topic_idx == topic.len;
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
            self.allocator.free(pattern.pattern);
        }
        self.patterns.deinit(self.allocator);
    }

    /// Add topic patterns to this subscriber.
    ///
    /// Each pattern is copied. Calling this more than once appends additional
    /// patterns.
    pub fn subscribe(self: *Subscriber, patterns: []const []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (patterns) |pattern| {
            const pattern_copy = try self.allocator.dupe(u8, pattern);
            errdefer self.allocator.free(pattern_copy);

            try self.patterns.append(self.allocator, .{ .pattern = pattern_copy });
        }
    }

    /// Return true when any subscribed pattern matches `topic`.
    pub fn matches(self: *Subscriber, topic: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.patterns.items) |pattern| {
            if (pattern.matches(topic)) {
                return true;
            }
        }
        return false;
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
    /// Protects subscriber registration.
    mutex: compat.Mutex,

    /// Initialize an empty broker.
    pub fn init(allocator: std.mem.Allocator) PubSubBroker {
        return .{
            .allocator = allocator,
            .subscribers = .empty,
            .mutex = .{},
        };
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
        self.mutex.lock();
        const subscribers_copy = self.allocator.alloc(*Subscriber, self.subscribers.items.len) catch {
            self.mutex.unlock();
            return error.OutOfMemory;
        };
        @memcpy(subscribers_copy, self.subscribers.items);
        self.mutex.unlock();
        defer self.allocator.free(subscribers_copy);

        var result = PublishResult{};
        for (subscribers_copy) |subscriber| {
            if (subscriber.matches(topic)) {
                subscriber.inbox.send(payload) catch {
                    result.failed += 1;
                    // Emit telemetry for failed delivery
                    if (telemetry.getGlobal()) |t| {
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
        return result;
    }
};

/// Optional global pub/sub broker used by convenience functions.
///
/// New v2 applications may prefer owning a `PubSubBroker` directly so tests and
/// services do not share process-wide state.
var global_broker: ?PubSubBroker = null;
var broker_mutex: compat.Mutex = .{};

/// Initialize the optional global broker if it has not already been created.
pub fn initGlobal(allocator: std.mem.Allocator) !void {
    broker_mutex.lock();
    defer broker_mutex.unlock();

    if (global_broker == null) {
        global_broker = PubSubBroker.init(allocator);
    }
}

/// Deinitialize and release the global broker.
/// Must only be called during shutdown when no other threads are
/// publishing or subscribing.
pub fn deinitGlobal() void {
    broker_mutex.lock();
    defer broker_mutex.unlock();

    if (global_broker) |*b| {
        b.deinit();
        global_broker = null;
    }
}

/// Get global broker.
///
/// SAFETY: The returned pointer is valid as long as `deinitGlobal()` has
/// not been called.  Callers must ensure `deinitGlobal()` is only invoked
/// during shutdown after all publish/subscribe operations have completed.
pub fn getGlobal() ?*PubSubBroker {
    broker_mutex.lock();
    defer broker_mutex.unlock();
    return if (global_broker) |*b| b else null;
}

/// Publish through the optional global broker.
///
/// Returns a `PublishResult` with delivery/failure counts, or null if no global
/// broker is initialized.
pub fn publish(topic: []const u8, payload: []const u8) !?PublishResult {
    if (getGlobal()) |broker| {
        return try broker.publish(topic, payload);
    }
    return null;
}

/// Allocate a subscriber and subscribe it to topic patterns.
///
/// If a global broker exists, the new subscriber is registered with it. The
/// caller owns the returned pointer and should call `deinit()` and destroy it
/// with the same allocator when finished.
pub fn subscribe(allocator: std.mem.Allocator, inbox: *Inbox, patterns: []const []const u8) !*Subscriber {
    const subscriber = try allocator.create(Subscriber);
    errdefer allocator.destroy(subscriber);

    subscriber.* = Subscriber.init(allocator, inbox);
    errdefer subscriber.deinit();

    try subscriber.subscribe(patterns);

    if (getGlobal()) |broker| {
        try broker.subscribe(subscriber);
    }

    return subscriber;
}

test "TopicPattern matching" {
    const pattern = TopicPattern{ .pattern = "events.*" };
    try std.testing.expect(pattern.matches("events.user"));
    try std.testing.expect(pattern.matches("events.system"));
    try std.testing.expect(!pattern.matches("events.user.created"));

    const multi_pattern = TopicPattern{ .pattern = "events.#" };
    try std.testing.expect(multi_pattern.matches("events.user.created"));
    try std.testing.expect(multi_pattern.matches("events.system.alerts"));
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
