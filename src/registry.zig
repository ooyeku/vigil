const std = @import("std");
const compat = @import("compat.zig");
const Mutex = compat.Mutex;
const ProcessMailbox = @import("messages.zig").ProcessMailbox;

/// Local process registry for mapping names to process mailboxes.
///
/// Thread-safe implementation using a mutex-protected hash map.
/// `Registry` owns copied names, but it does not own mailbox pointers.
pub const Registry = struct {
    /// Protects the registry map.
    mutex: Mutex,
    /// Name to mailbox pointer mapping.
    map: std.StringHashMap(*ProcessMailbox),
    /// Allocator for copied names and map storage.
    allocator: std.mem.Allocator,

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
            .mutex = Mutex{},
            .map = std.StringHashMap(*ProcessMailbox).init(allocator),
            .allocator = allocator,
        };
    }

    /// Deinitialize the registry and free stored names.
    ///
    /// Registered mailboxes are caller-owned and are not deinitialized.
    pub fn deinit(self: *Registry) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.map.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.map.deinit();
    }

    /// Register a mailbox under a name.
    ///
    /// The name is copied. Returns `error.AlreadyRegistered` if the name is
    /// already in use. The mailbox must outlive any users that retrieve it.
    pub fn register(self: *Registry, name: []const u8, mailbox: *ProcessMailbox) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.map.contains(name)) return error.AlreadyRegistered;

        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);

        try self.map.put(name_copy, mailbox);
    }

    /// Remove a name if present.
    pub fn unregister(self: *Registry, name: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.map.fetchRemove(name)) |entry| {
            self.allocator.free(entry.key);
        }
    }

    /// Look up a mailbox by name.
    pub fn whereis(self: *Registry, name: []const u8) ?*ProcessMailbox {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.map.get(name);
    }

    /// Return the number of registered names.
    pub fn count(self: *Registry) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.map.count();
    }

    /// Capture an owned snapshot of registered names and mailbox stats.
    ///
    /// Registered mailboxes must remain alive while this function runs.
    pub fn snapshot(self: *Registry, allocator: std.mem.Allocator) !Snapshot {
        self.mutex.lock();
        defer self.mutex.unlock();

        const entries = try allocator.alloc(RegisteredMailboxSnapshot, self.map.count());
        errdefer allocator.free(entries);

        var written: usize = 0;
        errdefer {
            for (entries[0..written]) |entry| {
                allocator.free(entry.name);
            }
        }

        var it = self.map.iterator();
        while (it.next()) |entry| {
            const name_copy = try allocator.dupe(u8, entry.key_ptr.*);
            const mailbox = entry.value_ptr.*;
            entries[written] = .{
                .name = name_copy,
                .queue_depth = mailbox.queuedCount(),
                .capacity = mailbox.config.capacity,
                .dead_letter_count = mailbox.deadLetterCount(),
                .poison_count = mailbox.poisonCount(),
                .stats = mailbox.getStats(),
            };
            written += 1;
        }

        return .{
            .allocator = allocator,
            .entries = entries,
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
