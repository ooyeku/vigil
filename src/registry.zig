const std = @import("std");
const Mutex = std.Thread.Mutex;
const ProcessMailbox = @import("messages.zig").ProcessMailbox;

/// Global process registry for mapping names to process mailboxes.
/// Thread-safe implementation using a mutex-protected hash map.
pub const Registry = struct {
    mutex: Mutex,
    map: std.StringHashMap(*ProcessMailbox),
    allocator: std.mem.Allocator,

    /// Initialize a new registry
    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{
            .mutex = Mutex{},
            .map = std.StringHashMap(*ProcessMailbox).init(allocator),
            .allocator = allocator,
        };
    }

    /// Deinitialize the registry and free all stored keys
    pub fn deinit(self: *Registry) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.map.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.map.deinit();
    }

    /// Register a mailbox with a name
    /// Returns error.AlreadyRegistered if the name is already in use
    pub fn register(self: *Registry, name: []const u8, mailbox: *ProcessMailbox) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.map.contains(name)) return error.AlreadyRegistered;

        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);

        try self.map.put(name_copy, mailbox);
    }

    /// Unregister a name
    pub fn unregister(self: *Registry, name: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.map.fetchRemove(name)) |entry| {
            self.allocator.free(entry.key);
        }
    }

    /// Look up a mailbox by name
    pub fn whereis(self: *Registry, name: []const u8) ?*ProcessMailbox {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.map.get(name);
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
