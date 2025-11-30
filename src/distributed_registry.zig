//! Distributed registry for Vigil
//! Cross-process name resolution.

const std = @import("std");
const Registry = @import("registry.zig").Registry;
const ProcessMailbox = @import("messages.zig").ProcessMailbox;

/// Cluster node representation
pub const ClusterNode = struct {
    address: []const u8,
    port: u16,
    last_seen_ms: i64,
    is_alive: bool,
};

/// Distributed registry configuration
pub const DistributedRegistryConfig = struct {
    cluster_nodes: []const []const u8, // "host:port" format
    sync_interval_ms: u32 = 1000,
    heartbeat_timeout_ms: u32 = 5000,
};

/// Distributed registry extends local registry
pub const DistributedRegistry = struct {
    local_registry: Registry,
    allocator: std.mem.Allocator,
    config: DistributedRegistryConfig,
    nodes: std.ArrayListUnmanaged(ClusterNode),
    mutex: std.Thread.Mutex,
    sync_thread: ?std.Thread = null,
    should_sync: bool = false,

    /// Initialize distributed registry
    pub fn init(allocator: std.mem.Allocator, config: DistributedRegistryConfig) !DistributedRegistry {
        var nodes: std.ArrayListUnmanaged(ClusterNode) = .{};
        errdefer nodes.deinit(allocator);

        // Parse cluster nodes
        for (config.cluster_nodes) |node_str| {
            const colon_pos = std.mem.indexOfScalar(u8, node_str, ':') orelse return error.InvalidNodeFormat;
            const address = node_str[0..colon_pos];
            const port_str = node_str[colon_pos + 1 ..];
            const port = try std.fmt.parseInt(u16, port_str, 10);

            const address_copy = try allocator.dupe(u8, address);
            errdefer allocator.free(address_copy);

            try nodes.append(allocator, .{
                .address = address_copy,
                .port = port,
                .last_seen_ms = std.time.milliTimestamp(),
                .is_alive = true,
            });
        }

        return .{
            .local_registry = Registry.init(allocator),
            .allocator = allocator,
            .config = config,
            .nodes = nodes,
            .mutex = .{},
            .sync_thread = null,
            .should_sync = false,
        };
    }

    /// Cleanup resources
    pub fn deinit(self: *DistributedRegistry) void {
        self.should_sync = false;
        if (self.sync_thread) |thread| {
            thread.join();
        }

        for (self.nodes.items) |*node| {
            self.allocator.free(node.address);
        }
        self.nodes.deinit(self.allocator);
        self.local_registry.deinit();
    }

    /// Register a process with scope
    pub const RegistrationScope = enum {
        local, // Only visible on this node
        global, // Visible across cluster
    };

    pub fn register(
        self: *DistributedRegistry,
        name: []const u8,
        mailbox: *ProcessMailbox,
        scope: RegistrationScope,
    ) !void {
        // Always register locally
        try self.local_registry.register(name, mailbox);

        // If global, sync to cluster
        if (scope == .global) {
            try self.syncToCluster(name, mailbox);
        }
    }

    /// Lookup process (checks local first, then cluster)
    pub fn whereis(self: *DistributedRegistry, name: []const u8) ?*ProcessMailbox {
        // Check local first
        if (self.local_registry.whereis(name)) |mailbox| {
            return mailbox;
        }

        // Check cluster (simplified - would query remote nodes)
        return null;
    }

    /// Sync registration to cluster (simplified)
    fn syncToCluster(self: *DistributedRegistry, name: []const u8, mailbox: *ProcessMailbox) !void {
        _ = self;
        _ = name;
        _ = mailbox;
        // Would send registration message to all cluster nodes
    }

    /// Start synchronization thread
    pub fn startSync(self: *DistributedRegistry) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sync_thread != null) return error.AlreadySyncing;

        self.should_sync = true;
        self.sync_thread = try std.Thread.spawn(.{}, syncLoop, .{self});
    }

    /// Stop synchronization
    pub fn stopSync(self: *DistributedRegistry) void {
        self.mutex.lock();
        self.should_sync = false;
        const thread = self.sync_thread;
        self.sync_thread = null;
        self.mutex.unlock();

        if (thread) |t| {
            t.join();
        }
    }

    /// Synchronization loop
    fn syncLoop(self: *DistributedRegistry) void {
        while (true) {
            {
                self.mutex.lock();
                const should_continue = self.should_sync;
                self.mutex.unlock();

                if (!should_continue) break;
            }

            // Sync with cluster nodes
            self.mutex.lock();
            for (self.nodes.items) |*node| {
                const now_ms = std.time.milliTimestamp();
                if (now_ms - node.last_seen_ms > self.config.heartbeat_timeout_ms) {
                    node.is_alive = false;
                }
            }
            self.mutex.unlock();

            std.Thread.sleep(@as(u64, self.config.sync_interval_ms) * std.time.ns_per_ms);
        }
    }
};

pub const DistributedRegistryError = error{
    InvalidNodeFormat,
    AlreadySyncing,
};

test "DistributedRegistry basic operations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var registry = try DistributedRegistry.init(allocator, .{
        .cluster_nodes = &.{"node1:9001"},
    });
    defer registry.deinit();

    var mailbox = ProcessMailbox.init(allocator, .{ .capacity = 10 });
    defer mailbox.deinit();

    try registry.register("test_proc", &mailbox, .local);
    const found = registry.whereis("test_proc");
    try std.testing.expect(found != null);
}
