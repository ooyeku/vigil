//! Process Groups for Vigil
//! Manage related processes together with routing strategies.

const std = @import("std");
const Message = @import("messages.zig").Message;
const Inbox = @import("api/inbox.zig").Inbox;
const telemetry = @import("telemetry.zig");

/// Result of a broadcast operation, reporting delivery outcomes.
pub const BroadcastResult = struct {
    delivered: usize = 0,
    failed: usize = 0,
};

/// Routing strategy for process groups
pub const RoutingStrategy = enum {
    broadcast, // Send to all members
    round_robin, // Distribute evenly
    consistent_hash, // Route by key
};

/// Process group member
pub const GroupMember = struct {
    id: []const u8,
    inbox: *Inbox,
};

/// Process group for managing related processes
pub const ProcessGroup = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    members: std.ArrayListUnmanaged(GroupMember),
    round_robin_index: usize,
    mutex: std.Thread.Mutex,

    /// Initialize a new process group
    pub fn init(allocator: std.mem.Allocator, name: []const u8) !ProcessGroup {
        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);

        return .{
            .allocator = allocator,
            .name = name_copy,
            .members = .{},
            .round_robin_index = 0,
            .mutex = .{},
        };
    }

    /// Cleanup resources
    pub fn deinit(self: *ProcessGroup) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.members.items) |member| {
            self.allocator.free(member.id);
        }
        self.members.deinit(self.allocator);
        self.allocator.free(self.name);
    }

    /// Add a member to the group
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

    /// Remove a member from the group
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

    /// Get member count
    pub fn memberCount(self: *ProcessGroup) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.members.items.len;
    }

    /// Broadcast a message to all members.
    /// Returns a `BroadcastResult` with delivery/failure counts.
    /// Emits `message_dropped` telemetry events for each failed delivery.
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
                        .timestamp_ms = std.time.milliTimestamp(),
                        .metadata = self.name,
                    });
                }
                continue;
            };
            result.delivered += 1;
        }
        return result;
    }

    /// Send message using round-robin distribution
    pub fn roundRobin(self: *ProcessGroup, payload: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.members.items.len == 0) return error.NoMembers;

        const member = &self.members.items[self.round_robin_index];
        self.round_robin_index = (self.round_robin_index + 1) % self.members.items.len;

        try member.inbox.send(payload);
    }

    /// Route message using consistent hash
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

    /// Deprecated: use `memberCount()` instead.
    pub const count = memberCount;
};

pub const ProcessGroupError = error{
    NoMembers,
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
