//! Distributed registry for Vigil
//! Cross-process name resolution with TCP-based cluster communication.

const std = @import("std");
const posix = std.posix;
const Registry = @import("registry.zig").Registry;
const ProcessMailbox = @import("messages.zig").ProcessMailbox;
const compat = @import("compat.zig");
const net = compat.net;

/// Cluster node representation
pub const ClusterNode = struct {
    address: []const u8,
    port: u16,
    last_seen_ms: i64,
    is_alive: bool,
};

/// Information about a process registered on a remote node
pub const RemoteProcessInfo = struct {
    name: []const u8,
    node_address: []const u8,
    node_port: u16,
};

/// Distributed registry configuration
pub const DistributedRegistryConfig = struct {
    cluster_nodes: []const []const u8, // "host:port" format
    sync_interval_ms: u32 = 1000,
    heartbeat_timeout_ms: u32 = 5000,
    listen_port: u16 = 9100,
};

/// Text-based protocol opcodes (newline-delimited)
/// REG <name>    -> OK | ERR <msg>
/// UNREG <name>  -> OK
/// WHERE <name>  -> FOUND | NOTFOUND
/// HEART         -> ALIVE
const Protocol = struct {
    fn sendFrame(stream: net.Stream, data: []const u8) void {
        _ = stream.write(data) catch {};
    }

    fn readLine(stream: net.Stream, buffer: []u8) ?[]const u8 {
        const n = stream.read(buffer) catch return null;
        if (n == 0) return null;
        return std.mem.trim(u8, buffer[0..n], "\r\n");
    }
};

/// Distributed registry extends local registry with TCP-based cluster communication.
pub const DistributedRegistry = struct {
    local_registry: Registry,
    allocator: std.mem.Allocator,
    config: DistributedRegistryConfig,
    nodes: std.ArrayListUnmanaged(ClusterNode),
    /// Names that were registered locally with global scope
    global_names: std.StringArrayHashMapUnmanaged(void),
    /// Cache of names known to exist on remote nodes
    remote_registrations: std.StringHashMap(RemoteProcessInfo),
    mutex: compat.Mutex,
    sync_thread: ?std.Thread = null,
    listener_thread: ?std.Thread = null,
    should_sync: std.atomic.Value(bool),
    /// Listening socket fd, stored so stopSync() can close it to unblock accept()
    listener_fd: ?posix.socket_t = null,

    /// Initialize distributed registry
    pub fn init(allocator: std.mem.Allocator, config: DistributedRegistryConfig) !DistributedRegistry {
        var nodes: std.ArrayListUnmanaged(ClusterNode) = .empty;
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
                .last_seen_ms = compat.milliTimestamp(),
                .is_alive = true,
            });
        }

        return .{
            .local_registry = Registry.init(allocator),
            .allocator = allocator,
            .config = config,
            .nodes = nodes,
            .global_names = .empty,
            .remote_registrations = std.StringHashMap(RemoteProcessInfo).init(allocator),
            .mutex = .{},
            .sync_thread = null,
            .listener_thread = null,
            .should_sync = std.atomic.Value(bool).init(false),
            .listener_fd = null,
        };
    }

    /// Cleanup resources
    pub fn deinit(self: *DistributedRegistry) void {
        self.stopSync();

        for (self.nodes.items) |*node| {
            self.allocator.free(node.address);
        }
        self.nodes.deinit(self.allocator);

        // Free global_names keys
        {
            var it = self.global_names.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            self.global_names.deinit(self.allocator);
        }

        // Free remote_registrations
        {
            var it = self.remote_registrations.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*.name);
                self.allocator.free(entry.value_ptr.*.node_address);
            }
            self.remote_registrations.deinit();
        }

        self.local_registry.deinit();
    }

    /// Registration scope
    pub const RegistrationScope = enum {
        local, // Only visible on this node
        global, // Visible across cluster
    };

    /// Register a process with scope
    pub fn register(
        self: *DistributedRegistry,
        name: []const u8,
        mailbox: *ProcessMailbox,
        scope: RegistrationScope,
    ) !void {
        // Always register locally
        try self.local_registry.register(name, mailbox);

        // If global, track the name for sync
        if (scope == .global) {
            self.mutex.lock();
            defer self.mutex.unlock();

            const name_copy = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(name_copy);
            try self.global_names.put(self.allocator, name_copy, {});
        }
    }

    /// Lookup process locally
    pub fn whereis(self: *DistributedRegistry, name: []const u8) ?*ProcessMailbox {
        return self.local_registry.whereis(name);
    }

    /// Lookup process across the cluster.
    /// Checks local registry first, then the remote registration cache.
    pub fn whereisGlobal(self: *DistributedRegistry, name: []const u8) ?RemoteProcessInfo {
        // Check local first
        if (self.local_registry.whereis(name) != null) {
            return RemoteProcessInfo{
                .name = name,
                .node_address = "local",
                .node_port = self.config.listen_port,
            };
        }

        // Check remote cache
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.remote_registrations.get(name);
    }

    /// Actively query all peer nodes for a name.
    /// Updates the remote registration cache on success.
    pub fn queryPeers(self: *DistributedRegistry, name: []const u8) ?RemoteProcessInfo {
        self.mutex.lock();
        const nodes_snapshot = self.allocator.dupe(ClusterNode, self.nodes.items) catch return null;
        self.mutex.unlock();
        defer self.allocator.free(nodes_snapshot);

        for (nodes_snapshot) |node| {
            if (!node.is_alive) continue;
            if (self.queryNode(node, name)) {
                const info = RemoteProcessInfo{
                    .name = name,
                    .node_address = node.address,
                    .node_port = node.port,
                };
                // Cache result
                self.cacheRemoteRegistration(name, info) catch {};
                return info;
            }
        }
        return null;
    }

    /// Query a single node for a name via TCP
    fn queryNode(self: *DistributedRegistry, node: ClusterNode, name: []const u8) bool {
        _ = self;
        const addr = net.parseIp4(node.address, node.port) catch return false;
        const fd = compat.sockets.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP) catch return false;
        defer compat.sockets.close(fd);

        // Set connect timeout via SO_SNDTIMEO
        const timeout = posix.timeval{ .sec = 1, .usec = 0 };
        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch {};
        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};

        compat.sockets.connect(fd, &addr.any, addr.getOsSockLen()) catch return false;
        const stream = net.Stream{ .handle = fd };

        var buf: [256]u8 = undefined;
        const cmd = std.fmt.bufPrint(&buf, "WHERE {s}\n", .{name}) catch return false;
        _ = stream.write(cmd) catch return false;

        var resp_buf: [256]u8 = undefined;
        const line = Protocol.readLine(stream, &resp_buf) orelse return false;
        return std.mem.eql(u8, line, "FOUND");
    }

    fn cacheRemoteRegistration(self: *DistributedRegistry, name: []const u8, info: RemoteProcessInfo) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Remove old entry if exists
        if (self.remote_registrations.fetchRemove(name)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value.name);
            self.allocator.free(old.value.node_address);
        }

        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        const info_name = try self.allocator.dupe(u8, info.name);
        errdefer self.allocator.free(info_name);
        const info_addr = try self.allocator.dupe(u8, info.node_address);
        errdefer self.allocator.free(info_addr);

        try self.remote_registrations.put(name_copy, .{
            .name = info_name,
            .node_address = info_addr,
            .node_port = info.node_port,
        });
    }

    /// Send heartbeat to a node and update liveness
    fn sendHeartbeat(_: *DistributedRegistry, node: *ClusterNode) void {
        const addr = net.parseIp4(node.address, node.port) catch {
            node.is_alive = false;
            return;
        };
        const fd = compat.sockets.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP) catch {
            node.is_alive = false;
            return;
        };
        defer compat.sockets.close(fd);

        const timeout = posix.timeval{ .sec = 1, .usec = 0 };
        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch {};
        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};

        compat.sockets.connect(fd, &addr.any, addr.getOsSockLen()) catch {
            node.is_alive = false;
            return;
        };
        const stream = net.Stream{ .handle = fd };

        _ = stream.write("HEART\n") catch {
            node.is_alive = false;
            return;
        };

        var buf: [64]u8 = undefined;
        if (Protocol.readLine(stream, &buf)) |line| {
            if (std.mem.eql(u8, line, "ALIVE")) {
                node.last_seen_ms = compat.milliTimestamp();
                node.is_alive = true;
                return;
            }
        }
        node.is_alive = false;
    }

    /// Sync a global registration to a single peer node
    fn syncRegistration(self: *DistributedRegistry, node: ClusterNode, name: []const u8) void {
        _ = self;
        const addr = net.parseIp4(node.address, node.port) catch return;
        const fd = compat.sockets.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP) catch return;
        defer compat.sockets.close(fd);

        const timeout = posix.timeval{ .sec = 1, .usec = 0 };
        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch {};

        compat.sockets.connect(fd, &addr.any, addr.getOsSockLen()) catch return;
        const stream = net.Stream{ .handle = fd };

        var buf: [256]u8 = undefined;
        const cmd = std.fmt.bufPrint(&buf, "REG {s}\n", .{name}) catch return;
        _ = stream.write(cmd) catch {};
    }

    /// Handle a single incoming connection on the listener
    fn handleIncoming(self: *DistributedRegistry, stream: net.Stream, peer_addr: net.Ip4Address) void {
        defer stream.close();

        var buffer: [1024]u8 = undefined;
        const line = Protocol.readLine(stream, &buffer) orelse return;

        if (std.mem.startsWith(u8, line, "WHERE ")) {
            const name = line["WHERE ".len..];
            if (self.local_registry.whereis(name) != null) {
                Protocol.sendFrame(stream, "FOUND\n");
            } else {
                Protocol.sendFrame(stream, "NOTFOUND\n");
            }
        } else if (std.mem.startsWith(u8, line, "REG ")) {
            const name = line["REG ".len..];
            const peer_ip_be = std.mem.bigToNative(u32, peer_addr.in.addr);
            const peer_port = std.mem.bigToNative(u16, peer_addr.in.port);
            var addr_buf: [64]u8 = undefined;
            const peer_ip = std.fmt.bufPrint(&addr_buf, "{d}.{d}.{d}.{d}", .{
                (peer_ip_be >> 24) & 0xff,
                (peer_ip_be >> 16) & 0xff,
                (peer_ip_be >> 8) & 0xff,
                peer_ip_be & 0xff,
            }) catch {
                Protocol.sendFrame(stream, "OK\n");
                return;
            };

            self.cacheRemoteRegistration(name, .{
                .name = name,
                .node_address = peer_ip,
                .node_port = peer_port,
            }) catch {};
            Protocol.sendFrame(stream, "OK\n");
        } else if (std.mem.eql(u8, line, "HEART")) {
            Protocol.sendFrame(stream, "ALIVE\n");
        } else {
            Protocol.sendFrame(stream, "ERR unknown command\n");
        }
    }

    /// Start listener and synchronization threads
    pub fn startSync(self: *DistributedRegistry) !void {
        if (self.should_sync.load(.acquire)) return error.AlreadySyncing;

        self.should_sync.store(true, .release);

        // Start listener thread
        self.listener_thread = try std.Thread.spawn(.{}, listenerLoop, .{self});

        // Start sync thread
        self.sync_thread = try std.Thread.spawn(.{}, syncLoop, .{self});
    }

    /// Stop synchronization and listener
    pub fn stopSync(self: *DistributedRegistry) void {
        if (!self.should_sync.load(.acquire)) return;

        self.should_sync.store(false, .release);

        // Close listener socket to unblock accept()
        if (self.listener_fd) |fd| {
            compat.sockets.close(fd);
            self.listener_fd = null;
        }

        if (self.listener_thread) |t| {
            t.join();
            self.listener_thread = null;
        }
        if (self.sync_thread) |t| {
            t.join();
            self.sync_thread = null;
        }
    }

    /// TCP listener loop - accepts incoming protocol connections
    fn listenerLoop(self: *DistributedRegistry) void {
        const addr = net.parseIp4("0.0.0.0", self.config.listen_port) catch return;
        const fd = compat.sockets.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP) catch return;

        self.listener_fd = fd;

        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1))) catch {};
        compat.sockets.bind(fd, &addr.any, addr.getOsSockLen()) catch return;
        compat.sockets.listen(fd, 32) catch return;

        var server = net.Server{
            .stream = .{ .handle = fd },
            .listen_address = addr,
        };

        while (self.should_sync.load(.acquire)) {
            const conn = server.accept() catch |err| switch (err) {
                error.SocketNotListening => break,
                else => {
                    if (!self.should_sync.load(.acquire)) break;
                    continue;
                },
            };
            self.handleIncoming(conn.stream, conn.address);
        }
    }

    /// Synchronization loop - heartbeats and registration sync
    fn syncLoop(self: *DistributedRegistry) void {
        while (self.should_sync.load(.acquire)) {
            // Heartbeat all nodes
            self.mutex.lock();
            for (self.nodes.items) |*node| {
                self.sendHeartbeat(node);

                // Mark dead if heartbeat timeout exceeded
                const now_ms = compat.milliTimestamp();
                if (now_ms - node.last_seen_ms > self.config.heartbeat_timeout_ms) {
                    node.is_alive = false;
                }
            }
            self.mutex.unlock();

            // Sync global registrations to live peers
            self.mutex.lock();
            var name_it = self.global_names.iterator();
            while (name_it.next()) |entry| {
                for (self.nodes.items) |node| {
                    if (node.is_alive) {
                        self.syncRegistration(node, entry.key_ptr.*);
                    }
                }
            }
            self.mutex.unlock();

            compat.sleep(@as(u64, self.config.sync_interval_ms) * std.time.ns_per_ms);
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

test "DistributedRegistry global scope tracks names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var registry = try DistributedRegistry.init(allocator, .{
        .cluster_nodes = &.{},
    });
    defer registry.deinit();

    var mailbox = ProcessMailbox.init(allocator, .{ .capacity = 10 });
    defer mailbox.deinit();

    try registry.register("global_proc", &mailbox, .global);

    // Should be findable locally
    const found = registry.whereis("global_proc");
    try std.testing.expect(found != null);

    // Should be tracked as a global name
    try std.testing.expect(registry.global_names.contains("global_proc"));
}

test "DistributedRegistry whereisGlobal returns local" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var registry = try DistributedRegistry.init(allocator, .{
        .cluster_nodes = &.{},
        .listen_port = 9199,
    });
    defer registry.deinit();

    var mailbox = ProcessMailbox.init(allocator, .{ .capacity = 10 });
    defer mailbox.deinit();

    try registry.register("my_service", &mailbox, .local);

    const info = registry.whereisGlobal("my_service");
    try std.testing.expect(info != null);
    try std.testing.expectEqualSlices(u8, "local", info.?.node_address);
    try std.testing.expectEqual(@as(u16, 9199), info.?.node_port);
}

test "DistributedRegistry whereisGlobal returns null for unknown" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var registry = try DistributedRegistry.init(allocator, .{
        .cluster_nodes = &.{},
    });
    defer registry.deinit();

    const info = registry.whereisGlobal("nonexistent");
    try std.testing.expect(info == null);
}
