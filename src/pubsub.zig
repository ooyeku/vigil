//! Pub/Sub messaging system for Vigil
//! Topic-based messaging with wildcard support.

const std = @import("std");
const Message = @import("messages.zig").Message;
const Inbox = @import("api/inbox.zig").Inbox;

/// Topic pattern matching
pub const TopicPattern = struct {
    pattern: []const u8,

    /// Check if a topic matches this pattern
    /// Supports * (single level) and # (multi-level) wildcards
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

/// Subscriber for pub/sub
pub const Subscriber = struct {
    allocator: std.mem.Allocator,
    inbox: *Inbox,
    patterns: std.ArrayListUnmanaged(TopicPattern),
    mutex: std.Thread.Mutex,

    /// Initialize a new subscriber
    pub fn init(allocator: std.mem.Allocator, inbox: *Inbox) Subscriber {
        return .{
            .allocator = allocator,
            .inbox = inbox,
            .patterns = .{},
            .mutex = .{},
        };
    }

    /// Cleanup resources
    pub fn deinit(self: *Subscriber) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.patterns.items) |pattern| {
            self.allocator.free(pattern.pattern);
        }
        self.patterns.deinit(self.allocator);
    }

    /// Subscribe to topic patterns
    pub fn subscribe(self: *Subscriber, patterns: []const []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (patterns) |pattern| {
            const pattern_copy = try self.allocator.dupe(u8, pattern);
            errdefer self.allocator.free(pattern_copy);

            try self.patterns.append(self.allocator, .{ .pattern = pattern_copy });
        }
    }

    /// Check if subscriber matches a topic
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

/// Pub/Sub broker
pub const PubSubBroker = struct {
    allocator: std.mem.Allocator,
    subscribers: std.ArrayListUnmanaged(*Subscriber),
    mutex: std.Thread.Mutex,

    /// Initialize a new broker
    pub fn init(allocator: std.mem.Allocator) PubSubBroker {
        return .{
            .allocator = allocator,
            .subscribers = .{},
            .mutex = .{},
        };
    }

    /// Cleanup resources
    pub fn deinit(self: *PubSubBroker) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.subscribers.deinit(self.allocator);
    }

    /// Register a subscriber
    pub fn subscribe(self: *PubSubBroker, subscriber: *Subscriber) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.subscribers.append(self.allocator, subscriber);
    }

    /// Unregister a subscriber
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

    /// Publish a message to all matching subscribers
    pub fn publish(self: *PubSubBroker, topic: []const u8, payload: []const u8) !void {
        self.mutex.lock();
        const subscribers_copy = self.allocator.alloc(*Subscriber, self.subscribers.items.len) catch {
            self.mutex.unlock();
            return error.OutOfMemory;
        };
        @memcpy(subscribers_copy, self.subscribers.items);
        self.mutex.unlock();
        defer self.allocator.free(subscribers_copy);

        for (subscribers_copy) |subscriber| {
            if (subscriber.matches(topic)) {
                subscriber.inbox.send(payload) catch {};
            }
        }
    }
};

/// Global pub/sub broker
var global_broker: ?PubSubBroker = null;
var broker_mutex: std.Thread.Mutex = .{};

/// Initialize global broker
pub fn initGlobal(allocator: std.mem.Allocator) !void {
    broker_mutex.lock();
    defer broker_mutex.unlock();

    if (global_broker == null) {
        global_broker = PubSubBroker.init(allocator);
    }
}

/// Get global broker
pub fn getGlobal() ?*PubSubBroker {
    broker_mutex.lock();
    defer broker_mutex.unlock();
    return if (global_broker) |*b| b else null;
}

/// Publish to global broker
pub fn publish(topic: []const u8, payload: []const u8) !void {
    if (getGlobal()) |broker| {
        try broker.publish(topic, payload);
    }
}

/// Create a subscriber
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

    try broker.publish("events.user.created", "user123");
    try broker.publish("events.system.alert", "alert1");

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
