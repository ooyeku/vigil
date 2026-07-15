const std = @import("std");
const compat = @import("compat.zig");
const Mutex = compat.Mutex;
const ProcessMailbox = @import("messages.zig").ProcessMailbox;

/// Local process registry for mapping names to process mailboxes.
///
/// Thread-safe implementation sharded by name hash: each shard has its own
/// mutex and hash map, so concurrent lookups of different names rarely
/// contend. `Registry` owns copied names, but it does not own mailbox
/// pointers.
pub const Registry = struct {
    /// Hash-partitioned shards, each independently locked.
    shards: [shard_count]Shard,
    /// Allocator for copied names and map storage.
    allocator: std.mem.Allocator,

    const shard_count = 64;

    const Shard = struct {
        /// Protects this shard's map. Cache-line aligned so neighboring
        /// shards never false-share a line under concurrent lookups.
        mutex: Mutex align(std.atomic.cache_line) = .{},
        /// Name to mailbox pointer mapping for this shard.
        map: std.StringHashMapUnmanaged(*ProcessMailbox) = .empty,
    };

    fn shardFor(self: *Registry, name: []const u8) *Shard {
        const hash = std.hash.Wyhash.hash(0, name);
        return &self.shards[@as(usize, @intCast(hash & (shard_count - 1)))];
    }

    /// Snapshot of one registered mailbox.
    pub const RegisteredMailboxSnapshot = struct {
        /// Registered process name.
        name: []const u8,
        /// Current queued message count.
        queue_depth: usize,
        /// Configured mailbox capacity.
        capacity: usize,
        /// Current retained dead-letter entry count.
        dead_letter_count: usize,
        /// Current retained poison-message count.
        poison_count: usize,
        /// Mailbox usage statistics.
        stats: ProcessMailbox.MailboxStats,
    };

    /// Owned snapshot of registry entries.
    pub const Snapshot = struct {
        allocator: std.mem.Allocator,
        entries: []RegisteredMailboxSnapshot,

        /// Release copied names and snapshot storage.
        pub fn deinit(self: *Snapshot) void {
            for (self.entries) |entry| {
                self.allocator.free(entry.name);
            }
            self.allocator.free(self.entries);
        }
    };

    /// Initialize an empty registry.
    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{
            .shards = @splat(.{}),
            .allocator = allocator,
        };
    }

    /// Deinitialize the registry and free stored names.
    ///
    /// Registered mailboxes are caller-owned and are not deinitialized.
    pub fn deinit(self: *Registry) void {
        for (&self.shards) |*shard| {
            shard.mutex.lock();
            defer shard.mutex.unlock();

            var it = shard.map.keyIterator();
            while (it.next()) |key| {
                self.allocator.free(key.*);
            }
            shard.map.deinit(self.allocator);
        }
    }

    /// Register a mailbox under a name.
    ///
    /// The name is copied. Returns `error.AlreadyRegistered` if the name is
    /// already in use. The mailbox must outlive any users that retrieve it.
    pub fn register(self: *Registry, name: []const u8, mailbox: *ProcessMailbox) !void {
        const shard = self.shardFor(name);
        shard.mutex.lock();
        defer shard.mutex.unlock();

        if (shard.map.contains(name)) return error.AlreadyRegistered;

        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);

        try shard.map.put(self.allocator, name_copy, mailbox);
    }

    /// Remove a name if present.
    pub fn unregister(self: *Registry, name: []const u8) void {
        const shard = self.shardFor(name);
        shard.mutex.lock();
        defer shard.mutex.unlock();

        if (shard.map.fetchRemove(name)) |entry| {
            self.allocator.free(entry.key);
        }
    }

    /// Look up a mailbox by name.
    pub fn whereis(self: *Registry, name: []const u8) ?*ProcessMailbox {
        const shard = self.shardFor(name);
        shard.mutex.lock();
        defer shard.mutex.unlock();
        return shard.map.get(name);
    }

    /// Return the number of registered names.
    pub fn count(self: *Registry) usize {
        var total: usize = 0;
        for (&self.shards) |*shard| {
            shard.mutex.lock();
            defer shard.mutex.unlock();
            total += shard.map.count();
        }
        return total;
    }

    /// Capture an owned snapshot of registered names and mailbox stats.
    ///
    /// Registered mailboxes must remain alive while this function runs.
    /// Shards are locked one at a time, so entries reflect a per-shard
    /// consistent view rather than one global instant.
    pub fn snapshot(self: *Registry, allocator: std.mem.Allocator) !Snapshot {
        var entries: std.ArrayListUnmanaged(RegisteredMailboxSnapshot) = .empty;
        errdefer {
            for (entries.items) |entry| {
                allocator.free(entry.name);
            }
            entries.deinit(allocator);
        }

        for (&self.shards) |*shard| {
            shard.mutex.lock();
            defer shard.mutex.unlock();

            try entries.ensureUnusedCapacity(allocator, shard.map.count());
            var it = shard.map.iterator();
            while (it.next()) |entry| {
                const name_copy = try allocator.dupe(u8, entry.key_ptr.*);
                const mailbox = entry.value_ptr.*;
                entries.appendAssumeCapacity(.{
                    .name = name_copy,
                    .queue_depth = mailbox.queuedCount(),
                    .capacity = mailbox.config.capacity,
                    .dead_letter_count = mailbox.deadLetterCount(),
                    .poison_count = mailbox.poisonCount(),
                    .stats = mailbox.getStats(),
                });
            }
        }

        return .{
            .allocator = allocator,
            .entries = try entries.toOwnedSlice(allocator),
        };
    }
};

test "Registry basic operations" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    // Create a dummy mailbox for testing
    var mailbox = ProcessMailbox.init(allocator, .{ .capacity = 10 });
    defer mailbox.deinit();

    // Test registration
    try registry.register("test_proc", &mailbox);

    // Test lookup
    const found = registry.whereis("test_proc");
    try std.testing.expect(found != null);
    try std.testing.expect(found.? == &mailbox);

    // Test duplicate registration
    try std.testing.expectError(error.AlreadyRegistered, registry.register("test_proc", &mailbox));

    // Test unregistration
    registry.unregister("test_proc");
    try std.testing.expect(registry.whereis("test_proc") == null);
}

test "Registry concurrent access" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    var mailbox = ProcessMailbox.init(allocator, .{ .capacity = 10 });
    defer mailbox.deinit();

    const ThreadContext = struct {
        registry: *Registry,
        mailbox: *ProcessMailbox,
    };

    const thread_fn = struct {
        fn run(ctx: ThreadContext) void {
            ctx.registry.register("concurrent_proc", ctx.mailbox) catch {};
            _ = ctx.registry.whereis("concurrent_proc");
        }
    }.run;

    const ctx = ThreadContext{
        .registry = &registry,
        .mailbox = &mailbox,
    };

    const t1 = try std.Thread.spawn(.{}, thread_fn, .{ctx});
    const t2 = try std.Thread.spawn(.{}, thread_fn, .{ctx});

    t1.join();
    t2.join();

    // One should have succeeded, one failed (caught), but final state should be registered
    try std.testing.expect(registry.whereis("concurrent_proc") != null);
}

test "Registry churn registers snapshots and unregisters many names" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    var mailbox = ProcessMailbox.init(allocator, .{ .capacity = 32 });
    defer mailbox.deinit();

    const iterations = 128;
    for (0..iterations) |i| {
        var name_buffer: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "churn.proc.{d}", .{i});
        try registry.register(name, &mailbox);
    }

    var snapshot = try registry.snapshot(allocator);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(usize, iterations), snapshot.entries.len);

    for (0..iterations) |i| {
        var name_buffer: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "churn.proc.{d}", .{i});
        registry.unregister(name);
    }

    try std.testing.expectEqual(@as(usize, 0), registry.count());
}

test "Registry shards names across independent locks" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    var mailbox = ProcessMailbox.init(allocator, .{ .capacity = 4 });
    defer mailbox.deinit();

    // Register enough names to populate multiple shards.
    for (0..64) |i| {
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "shard.proc.{d}", .{i});
        try registry.register(name, &mailbox);
    }
    try std.testing.expectEqual(@as(usize, 64), registry.count());

    var populated_shards: usize = 0;
    for (&registry.shards) |*shard| {
        if (shard.map.count() > 0) populated_shards += 1;
    }
    try std.testing.expect(populated_shards > 1);

    // Every name still resolves and snapshots cover all shards.
    var snapshot = try registry.snapshot(allocator);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 64), snapshot.entries.len);

    for (0..64) |i| {
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "shard.proc.{d}", .{i});
        try std.testing.expect(registry.whereis(name) == &mailbox);
        registry.unregister(name);
    }
    try std.testing.expectEqual(@as(usize, 0), registry.count());
}

test "Registry concurrent lookups across shards" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    var mailbox = ProcessMailbox.init(allocator, .{ .capacity = 4 });
    defer mailbox.deinit();

    for (0..32) |i| {
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "worker.{d}", .{i});
        try registry.register(name, &mailbox);
    }

    const Lookup = struct {
        fn run(target: *Registry) void {
            var name_buffer: [32]u8 = undefined;
            for (0..1_000) |i| {
                const name = std.fmt.bufPrint(&name_buffer, "worker.{d}", .{i % 32}) catch return;
                std.debug.assert(target.whereis(name) != null);
            }
        }
    };

    var threads: [4]std.Thread = undefined;
    for (&threads) |*slot| {
        slot.* = try std.Thread.spawn(.{}, Lookup.run, .{&registry});
    }
    for (threads) |thread| thread.join();
}
