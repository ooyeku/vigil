//! Process groups for Vigil.
//!
//! A process group is a named set of inboxes that can receive broadcast,
//! round-robin, or keyed messages. Groups are useful for worker pools, fanout,
//! and simple sharding where the caller does not want to look up each mailbox
//! manually.

const std = @import("std");
const Message = @import("messages.zig").Message;
const Inbox = @import("api/inbox.zig").Inbox;
const telemetry = @import("telemetry.zig");
const compat = @import("compat.zig");

/// Result of a broadcast operation, reporting delivery outcomes.
pub const BroadcastResult = struct {
    /// Number of group members that accepted the payload.
    delivered: usize = 0,
    /// Number of group members whose inbox rejected the payload.
    failed: usize = 0,
};

/// Member entry in a process group.
pub const GroupMember = struct {
    /// Stable member id copied by `ProcessGroup.add`.
    id: []const u8,
    /// Inbox owned by the caller. The group does not close or free it.
    inbox: *Inbox,
};

/// Snapshot of one process-group member.
pub const ProcessGroupMemberSnapshot = struct {
    /// Stable member id.
    id: []const u8,
    /// Current queued message count for the member inbox.
    queue_depth: usize,
    /// Whether the member inbox has been closed.
    closed: bool,
};

/// Owned snapshot of process-group membership.
pub const ProcessGroupSnapshot = struct {
    allocator: std.mem.Allocator,
    /// Copied process-group name.
    name: []const u8,
    /// Number of registered members.
    member_count: usize,
    /// Next member index used for round-robin routing.
    round_robin_index: usize,
    /// Lifetime successful broadcast deliveries.
    total_delivered: u64,
    /// Lifetime failed broadcast deliveries.
    total_failed: u64,
    /// Per-member snapshots.
    members: []ProcessGroupMemberSnapshot,

    /// Release copied member ids, group name, and snapshot storage.
    pub fn deinit(self: *ProcessGroupSnapshot) void {
        for (self.members) |member| {
            self.allocator.free(member.id);
        }
        self.allocator.free(self.members);
        self.allocator.free(self.name);
    }
};

/// Thread-safe collection of named inboxes.
///
/// The group owns copied member ids and its own name. It does not own member
/// inboxes; callers must keep inboxes alive while they are registered.
pub const ProcessGroup = struct {
    /// Allocator for copied names and member storage.
    allocator: std.mem.Allocator,
    /// Group name, used in telemetry metadata.
    name: []const u8,
    /// Registered members.
    members: std.ArrayListUnmanaged(GroupMember),
    /// Next member index for round-robin routing.
    round_robin_index: usize,
    /// Optional emitter for delivery-failure events. Not owned.
    telemetry_emitter: ?*telemetry.TelemetryEmitter,
    /// Protects membership and round-robin state.
    mutex: compat.Mutex,
    /// Lifetime successful deliveries across all broadcasts.
    total_delivered: std.atomic.Value(u64),
    /// Lifetime failed deliveries across all broadcasts.
    total_failed: std.atomic.Value(u64),

    /// Initialize an empty process group with a copied name.
    pub fn init(allocator: std.mem.Allocator, name: []const u8) !ProcessGroup {
        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);

        return .{
            .allocator = allocator,
            .name = name_copy,
            .members = .empty,
            .round_robin_index = 0,
            .telemetry_emitter = null,
            .mutex = .{},
            .total_delivered = std.atomic.Value(u64).init(0),
            .total_failed = std.atomic.Value(u64).init(0),
        };
    }

    /// Attach an emitter for delivery-failure events. Not owned.
    pub fn setTelemetryEmitter(self: *ProcessGroup, emitter: ?*telemetry.TelemetryEmitter) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.telemetry_emitter = emitter;
    }

    /// Release group-owned names and member storage.
    ///
    /// Registered inboxes are not closed.
    pub fn deinit(self: *ProcessGroup) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.members.items) |member| {
            self.allocator.free(member.id);
        }
        self.members.deinit(self.allocator);
        self.allocator.free(self.name);
    }

    /// Add an inbox to the group under `id`.
    ///
    /// The id is copied. The inbox remains caller-owned and must outlive its
    /// membership or be removed before closing.
    pub fn add(self: *ProcessGroup, id: []const u8, inbox: *Inbox) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.members.items) |member| {
            if (std.mem.eql(u8, member.id, id)) return error.AlreadyMember;
        }

        const id_copy = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(id_copy);

        try self.members.append(self.allocator, .{
            .id = id_copy,
            .inbox = inbox,
        });
    }

    /// Remove a member by id.
    ///
    /// Returns true when a member was removed.
    pub fn remove(self: *ProcessGroup, id: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.members.items, 0..) |member, i| {
            if (std.mem.eql(u8, member.id, id)) {
                self.allocator.free(member.id);
                _ = self.members.orderedRemove(i);
                if (self.members.items.len == 0) {
                    self.round_robin_index = 0;
                } else {
                    self.round_robin_index %= self.members.items.len;
                }
                return true;
            }
        }
        return false;
    }

    /// Return the number of registered members.
    pub fn memberCount(self: *ProcessGroup) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.members.items.len;
    }

    /// Capture an owned snapshot of process-group membership.
    ///
    /// Registered inboxes must remain alive while this function runs. The
    /// caller owns the returned snapshot and must call `deinit()`.
    pub fn snapshot(self: *ProcessGroup, allocator: std.mem.Allocator) !ProcessGroupSnapshot {
        self.mutex.lock();
        defer self.mutex.unlock();

        const name_copy = try allocator.dupe(u8, self.name);
        errdefer allocator.free(name_copy);

        const members = try allocator.alloc(ProcessGroupMemberSnapshot, self.members.items.len);
        errdefer allocator.free(members);

        var written: usize = 0;
        errdefer {
            for (members[0..written]) |member| {
                allocator.free(member.id);
            }
        }

        for (self.members.items) |member| {
            const id_copy = try allocator.dupe(u8, member.id);
            members[written] = .{
                .id = id_copy,
                .queue_depth = member.inbox.mailbox.queuedCount(),
                .closed = member.inbox.isClosed(),
            };
            written += 1;
        }

        return .{
            .allocator = allocator,
            .name = name_copy,
            .member_count = members.len,
            .round_robin_index = self.round_robin_index,
            .total_delivered = self.total_delivered.load(.monotonic),
            .total_failed = self.total_failed.load(.monotonic),
            .members = members,
        };
    }

    /// Broadcast a message to all members.
    ///
    /// Returns a `BroadcastResult` with delivery/failure counts.
    /// Emits `message_dropped` telemetry events for each failed delivery.
    /// Delivery is best-effort: one failed inbox does not stop the broadcast.
    pub fn broadcast(self: *ProcessGroup, payload: []const u8) !BroadcastResult {
        return self.broadcastBatch(&.{payload});
    }

    /// Broadcast several payloads to all members with one membership
    /// snapshot.
    ///
    /// Delivery semantics match `broadcast()` per payload. For typical group
    /// sizes the membership snapshot lives on the stack, so batched
    /// broadcasts avoid per-call allocation entirely.
    pub fn broadcastBatch(self: *ProcessGroup, payloads: []const []const u8) !BroadcastResult {
        var stack_snapshot: [32]GroupMember = undefined;
        var heap_snapshot: ?[]GroupMember = null;

        self.mutex.lock();
        const count = self.members.items.len;
        const members_copy: []const GroupMember = if (count <= stack_snapshot.len) blk: {
            @memcpy(stack_snapshot[0..count], self.members.items);
            break :blk stack_snapshot[0..count];
        } else blk: {
            const copy = self.allocator.alloc(GroupMember, count) catch {
                self.mutex.unlock();
                return error.OutOfMemory;
            };
            @memcpy(copy, self.members.items);
            heap_snapshot = copy;
            break :blk copy;
        };
        self.mutex.unlock();
        defer if (heap_snapshot) |copy| self.allocator.free(copy);

        var result = BroadcastResult{};
        for (members_copy) |member| {
            for (payloads) |payload| {
                member.inbox.send(payload) catch {
                    result.failed += 1;
                    // Emit telemetry for failed delivery
                    if (self.telemetry_emitter) |t| {
                        t.emit(.{
                            .event_type = .message_dropped,
                            .timestamp_ms = compat.milliTimestamp(),
                            .metadata = self.name,
                        });
                    }
                    continue;
                };
                result.delivered += 1;
            }
        }

        _ = self.total_delivered.fetchAdd(result.delivered, .monotonic);
        _ = self.total_failed.fetchAdd(result.failed, .monotonic);
        return result;
    }

    /// Send a payload to the next member in round-robin order.
    ///
    /// Returns `error.NoMembers` when the group is empty.
    pub fn roundRobin(self: *ProcessGroup, payload: []const u8) !void {
        self.mutex.lock();
        if (self.members.items.len == 0) {
            self.mutex.unlock();
            return error.NoMembers;
        }

        const inbox = self.members.items[self.round_robin_index].inbox;
        self.round_robin_index = (self.round_robin_index + 1) % self.members.items.len;
        self.mutex.unlock();

        try inbox.send(payload);
    }

    /// Route a payload by hashing `key`.
    ///
    /// The same key routes to the same member while membership order is
    /// unchanged. Returns `error.NoMembers` when the group is empty.
    pub fn route(self: *ProcessGroup, payload: []const u8, key: []const u8) !void {
        self.mutex.lock();
        if (self.members.items.len == 0) {
            self.mutex.unlock();
            return error.NoMembers;
        }

        const index = routeIndex(key, self.members.items.len);
        const inbox = self.members.items[index].inbox;
        self.mutex.unlock();

        try inbox.send(payload);
    }

    /// Return the member index that `route()` would pick for `key`, or null
    /// when the group is empty.
    ///
    /// This is a non-mutating preview. Combined with `snapshot()`, it lets
    /// callers inspect the effective route table for a set of keys.
    pub fn routeIndexForKey(self: *ProcessGroup, key: []const u8) ?usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.members.items.len == 0) return null;
        return routeIndex(key, self.members.items.len);
    }

    /// Return a copied member id that `route()` would pick for `key`, or null
    /// when the group is empty. The caller owns the returned slice.
    pub fn routeMemberForKey(
        self: *ProcessGroup,
        allocator: std.mem.Allocator,
        key: []const u8,
    ) !?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.members.items.len == 0) return null;
        const index = routeIndex(key, self.members.items.len);
        return try allocator.dupe(u8, self.members.items[index].id);
    }

    fn routeIndex(key: []const u8, member_count: usize) usize {
        var hash: u64 = 0;
        for (key) |byte| {
            hash = hash *% 31 +% byte;
        }
        return @intCast(hash % member_count);
    }
};

test "ProcessGroup basic operations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var group = try ProcessGroup.init(allocator, "workers");
    defer group.deinit();

    var inbox1 = try Inbox.init(allocator);
    defer inbox1.close();

    var inbox2 = try Inbox.init(allocator);
    defer inbox2.close();

    try group.add("worker1", inbox1);
    try group.add("worker2", inbox2);

    try std.testing.expect(group.memberCount() == 2);

    const result = try group.broadcast("test");
    try std.testing.expectEqual(@as(usize, 2), result.delivered);
    try std.testing.expectEqual(@as(usize, 0), result.failed);
    try std.testing.expect(group.remove("worker1"));
    try std.testing.expect(group.memberCount() == 1);
}

test "ProcessGroup rejects duplicate ids and normalizes routing after removal" {
    const allocator = std.testing.allocator;
    var group = try ProcessGroup.init(allocator, "workers");
    defer group.deinit();
    var first = try Inbox.init(allocator);
    defer first.close();
    var second = try Inbox.init(allocator);
    defer second.close();

    try group.add("first", first);
    try std.testing.expectError(error.AlreadyMember, group.add("first", second));
    try group.add("second", second);

    try group.roundRobin("first-message");
    try std.testing.expect(group.remove("second"));
    try group.roundRobin("after-removal");
    try std.testing.expectEqual(@as(usize, 2), first.mailbox.queuedCount());

    const long_key = "a" ** 128;
    try group.route("wrapped-hash", long_key);
    try std.testing.expectEqual(@as(usize, 3), first.mailbox.queuedCount());
}

test "ProcessGroup round robin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var group = try ProcessGroup.init(allocator, "workers");
    defer group.deinit();

    var inbox1 = try Inbox.init(allocator);
    defer inbox1.close();

    var inbox2 = try Inbox.init(allocator);
    defer inbox2.close();

    try group.add("worker1", inbox1);
    try group.add("worker2", inbox2);

    try group.roundRobin("msg1");
    try group.roundRobin("msg2");

    // Messages should be distributed
    const msg1 = try inbox1.recvTimeout(100);
    const msg2 = try inbox2.recvTimeout(100);

    try std.testing.expect(msg1 != null);
    try std.testing.expect(msg2 != null);
    if (msg1) |m| {
        m.deinit();
    }
    if (msg2) |m| {
        m.deinit();
    }
}

test "ProcessGroup snapshot reports members and queue depth" {
    const allocator = std.testing.allocator;

    var group = try ProcessGroup.init(allocator, "workers");
    defer group.deinit();

    var inbox1 = try Inbox.init(allocator);
    defer inbox1.close();

    var inbox2 = try Inbox.init(allocator);
    defer inbox2.close();

    try inbox1.send("queued");
    try group.add("worker1", inbox1);
    try group.add("worker2", inbox2);

    var snapshot = try group.snapshot(allocator);
    defer snapshot.deinit();

    try std.testing.expectEqualStrings("workers", snapshot.name);
    try std.testing.expectEqual(@as(usize, 2), snapshot.member_count);
    try std.testing.expectEqual(@as(usize, 2), snapshot.members.len);
    try std.testing.expectEqualStrings("worker1", snapshot.members[0].id);
    try std.testing.expectEqual(@as(usize, 1), snapshot.members[0].queue_depth);
    try std.testing.expect(!snapshot.members[0].closed);
}

test "ProcessGroup broadcast stress delivers to all members" {
    const allocator = std.testing.allocator;
    const member_count = 4;
    const iterations = 32;

    var group = try ProcessGroup.init(allocator, "stress-workers");
    defer group.deinit();

    var inboxes: [member_count]*Inbox = undefined;
    for (&inboxes, 0..) |*slot, i| {
        slot.* = try Inbox.init(allocator);
        const id = try std.fmt.allocPrint(allocator, "worker-{d}", .{i});
        defer allocator.free(id);
        try group.add(id, slot.*);
    }
    defer for (inboxes) |inbox| {
        inbox.close();
    };

    for (0..iterations) |_| {
        const result = try group.broadcast("payload");
        try std.testing.expectEqual(@as(usize, member_count), result.delivered);
        try std.testing.expectEqual(@as(usize, 0), result.failed);
    }

    for (inboxes) |inbox| {
        try std.testing.expectEqual(iterations, inbox.mailbox.queuedCount());
    }
}

test "ProcessGroup route preview matches actual routing" {
    const allocator = std.testing.allocator;

    var group = try ProcessGroup.init(allocator, "workers");
    defer group.deinit();

    try std.testing.expect(group.routeIndexForKey("order-1") == null);
    try std.testing.expect(try group.routeMemberForKey(allocator, "order-1") == null);

    var inbox1 = try Inbox.init(allocator);
    defer inbox1.close();
    var inbox2 = try Inbox.init(allocator);
    defer inbox2.close();
    try group.add("worker1", inbox1);
    try group.add("worker2", inbox2);

    const keys = [_][]const u8{ "order-1", "order-2", "customer-42" };
    for (keys) |key| {
        const index = group.routeIndexForKey(key).?;
        const member_id = (try group.routeMemberForKey(allocator, key)).?;
        defer allocator.free(member_id);

        const target = if (index == 0) inbox1 else inbox2;
        const expected_id = if (index == 0) "worker1" else "worker2";
        try std.testing.expectEqualStrings(expected_id, member_id);

        const before = target.mailbox.queuedCount();
        try group.route("payload", key);
        try std.testing.expectEqual(before + 1, target.mailbox.queuedCount());
    }
}

test "ProcessGroup property: keyed routing is stable and in bounds" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x9047_e11a);
    const random = prng.random();

    var group = try ProcessGroup.init(allocator, "sharded");
    defer group.deinit();

    const member_count = 5;
    var inboxes: [member_count]*Inbox = undefined;
    for (&inboxes, 0..) |*slot, i| {
        slot.* = try Inbox.init(allocator);
        var id_buffer: [16]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buffer, "member-{d}", .{i});
        try group.add(id, slot.*);
    }
    defer for (inboxes) |inbox| {
        inbox.close();
    };

    var key_buffer: [32]u8 = undefined;
    for (0..500) |_| {
        const key_len = 1 + random.uintLessThan(usize, key_buffer.len - 1);
        const key = key_buffer[0..key_len];
        random.bytes(key);

        const first = group.routeIndexForKey(key).?;
        try std.testing.expect(first < member_count);
        // Same key, same member, as long as membership is unchanged.
        try std.testing.expectEqual(first, group.routeIndexForKey(key).?);
    }
}

test "ProcessGroup broadcastBatch delivers all payloads and tracks counters" {
    const allocator = std.testing.allocator;

    var group = try ProcessGroup.init(allocator, "workers");
    defer group.deinit();

    var inbox1 = try Inbox.init(allocator);
    defer inbox1.close();
    var inbox2 = try Inbox.init(allocator);
    defer inbox2.close();
    try group.add("worker1", inbox1);
    try group.add("worker2", inbox2);

    const payloads = [_][]const u8{ "tick", "tock" };
    const result = try group.broadcastBatch(&payloads);
    try std.testing.expectEqual(@as(usize, 4), result.delivered);
    try std.testing.expectEqual(@as(usize, 0), result.failed);
    try std.testing.expectEqual(@as(usize, 2), inbox1.mailbox.queuedCount());
    try std.testing.expectEqual(@as(usize, 2), inbox2.mailbox.queuedCount());

    var snapshot = try group.snapshot(allocator);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(u64, 4), snapshot.total_delivered);
    try std.testing.expectEqual(@as(u64, 0), snapshot.total_failed);
}
