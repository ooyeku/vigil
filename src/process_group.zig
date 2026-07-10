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
    /// Protects membership and round-robin state.
    mutex: compat.Mutex,

    /// Initialize an empty process group with a copied name.
    pub fn init(allocator: std.mem.Allocator, name: []const u8) !ProcessGroup {
        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);

        return .{
            .allocator = allocator,
            .name = name_copy,
            .members = .empty,
            .round_robin_index = 0,
            .mutex = .{},
        };
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
            .members = members,
        };
    }

    /// Broadcast a message to all members.
    ///
    /// Returns a `BroadcastResult` with delivery/failure counts.
    /// Emits `message_dropped` telemetry events for each failed delivery.
    /// Delivery is best-effort: one failed inbox does not stop the broadcast.
    pub fn broadcast(self: *ProcessGroup, payload: []const u8) !BroadcastResult {
        self.mutex.lock();
        const members_copy = self.allocator.alloc(GroupMember, self.members.items.len) catch {
            self.mutex.unlock();
            return error.OutOfMemory;
        };
        @memcpy(members_copy, self.members.items);
        self.mutex.unlock();
        defer self.allocator.free(members_copy);

        var result = BroadcastResult{};
        for (members_copy) |member| {
            member.inbox.send(payload) catch {
                result.failed += 1;
                // Emit telemetry for failed delivery
                if (telemetry.getGlobal()) |t| {
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
        return result;
    }

    /// Send a payload to the next member in round-robin order.
    ///
    /// Returns `error.NoMembers` when the group is empty.
    pub fn roundRobin(self: *ProcessGroup, payload: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.members.items.len == 0) return error.NoMembers;

        const member = &self.members.items[self.round_robin_index];
        self.round_robin_index = (self.round_robin_index + 1) % self.members.items.len;

        try member.inbox.send(payload);
    }

    /// Route a payload by hashing `key`.
    ///
    /// The same key routes to the same member while membership order is
    /// unchanged. Returns `error.NoMembers` when the group is empty.
    pub fn route(self: *ProcessGroup, payload: []const u8, key: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.members.items.len == 0) return error.NoMembers;

        // Simple hash-based routing
        var hash: u64 = 0;
        for (key) |byte| {
            hash = hash * 31 + byte;
        }

        const index = @as(usize, @intCast(hash % self.members.items.len));
        const member = &self.members.items[index];

        try member.inbox.send(payload);
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
