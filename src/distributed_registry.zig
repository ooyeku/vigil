//! Distributed registry for Vigil.
//!
//! Cross-process name resolution with TCP-based cluster communication.

const std = @import("std");
const posix = std.posix;
const Registry = @import("registry.zig").Registry;
const ProcessMailbox = @import("messages.zig").ProcessMailbox;
const compat = @import("compat.zig");
const net = compat.net;
const protocol = @import("distributed_protocol.zig");

/// Peer node tracked by a distributed registry.
pub const ClusterNode = struct {
    /// IPv4 address or host string used for TCP connections.
    address: []const u8,
    /// Peer listen port.
    port: u16,
    /// Last heartbeat or successful contact time in milliseconds.
    last_seen_ms: i64,
    /// Whether the node is currently considered reachable.
    is_alive: bool,
};

/// Information about a process registered on a remote node.
pub const RemoteProcessInfo = struct {
    /// Registered process name.
    name: []const u8,
    /// Node address, or `"local"` when resolved locally.
    node_address: []const u8,
    /// Node listen port.
    node_port: u16,
};

/// Configuration for a distributed registry node.
pub const DistributedRegistryConfig = struct {
    /// Peer nodes in `"host:port"` format.
    cluster_nodes: []const []const u8,
    /// Interval between background sync/heartbeat attempts.
    sync_interval_ms: u32 = 1000,
    /// Time after which a peer without heartbeat is considered stale.
    heartbeat_timeout_ms: u32 = 5000,
    /// Local TCP listen port for registry protocol requests.
    listen_port: u16 = 9100,
};

/// Text-based v2 protocol opcodes (newline-delimited)
/// VIGIL/2 REG <name>    -> OK | ERR <msg>
/// VIGIL/2 UNREG <name>  -> OK
/// VIGIL/2 WHERE <name>  -> FOUND | NOTFOUND
/// VIGIL/2 HEART         -> ALIVE
const Protocol = struct {
    fn sendFrame(stream: net.Stream, data: []const u8) void {
        _ = stream.write(data) catch {};
    }

    fn readLine(stream: net.Stream, buffer: []u8) ?[]const u8 {
        var used: usize = 0;
        while (used < buffer.len) {
            const n = stream.read(buffer[used..]) catch return null;
            if (n == 0) return null;

            const chunk = buffer[used .. used + n];
            if (std.mem.indexOfScalar(u8, chunk, '\n')) |relative_end| {
                var line_end = used + relative_end;
                if (line_end > 0 and buffer[line_end - 1] == '\r') line_end -= 1;
                return buffer[0..line_end];
            }
            used += n;
        }

        // Frames must be newline terminated and fit in the supplied buffer.
        return null;
    }
};

/// Local registry extended with cluster name resolution.
///
/// The registry owns copied node addresses, global registration names, and
/// remote cache entries. Registered local mailboxes remain caller-owned and
/// must outlive their registrations.
pub const DistributedRegistry = struct {
    /// Local name to mailbox registry.
    local_registry: Registry,
    /// Allocator for registry-owned storage.
    allocator: std.mem.Allocator,
    /// Static cluster configuration.
    config: DistributedRegistryConfig,
    /// Known peer nodes.
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

    /// Initialize a distributed registry from `config`.
    ///
    /// Each `cluster_nodes` entry must be in `host:port` format.
    pub fn init(allocator: std.mem.Allocator, config: DistributedRegistryConfig) !DistributedRegistry {
        if (config.sync_interval_ms == 0 or config.heartbeat_timeout_ms == 0) {
            return error.InvalidConfiguration;
        }

        var nodes: std.ArrayListUnmanaged(ClusterNode) = .empty;
        errdefer {
            for (nodes.items) |node| allocator.free(node.address);
            nodes.deinit(allocator);
        }

        // Parse cluster nodes
        for (config.cluster_nodes) |node_str| {
            const colon_pos = std.mem.indexOfScalar(u8, node_str, ':') orelse return error.InvalidNodeFormat;
            const address = node_str[0..colon_pos];
            const port_str = node_str[colon_pos + 1 ..];
            if (address.len == 0 or port_str.len == 0) return error.InvalidNodeFormat;
            const port = try std.fmt.parseInt(u16, port_str, 10);
            if (port == 0) return error.InvalidNodeFormat;

            const address_copy = try allocator.dupe(u8, address);
            errdefer allocator.free(address_copy);

            try nodes.append(allocator, .{
                .address = address_copy,
                .port = port,
                .last_seen_ms = compat.monotonicMilliTimestamp(),
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

    /// Stop background sync and release registry-owned storage.
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

    /// Scope for a registration.
    pub const RegistrationScope = enum {
        /// Only visible on this node.
        local,
        /// Advertised to peers during sync.
        global,
    };

    /// Register a local mailbox with a visibility scope.
    ///
    /// The local name is copied by the underlying registry. Global names are
    /// also tracked for sync. The mailbox pointer is not owned.
    pub fn register(
        self: *DistributedRegistry,
        name: []const u8,
        mailbox: *ProcessMailbox,
        scope: RegistrationScope,
    ) !void {
        if (scope == .global and !protocol.isValidName(name)) return error.InvalidName;

        // Always register locally
        try self.local_registry.register(name, mailbox);
        errdefer self.local_registry.unregister(name);

        // If global, track the name for sync
        if (scope == .global) {
            self.mutex.lock();
            defer self.mutex.unlock();

            const name_copy = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(name_copy);
            try self.global_names.put(self.allocator, name_copy, {});
        }
    }

    /// Look up a local mailbox by name.
    pub fn whereis(self: *DistributedRegistry, name: []const u8) ?*ProcessMailbox {
        return self.local_registry.whereis(name);
    }

    /// Lookup process across the cluster.
    ///
    /// Checks local registry first, then the remote registration cache.
    /// Returned remote info contains borrowed slices owned by the registry or
    /// by the caller when the result is local.
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
    ///
    /// Updates the remote registration cache on success.
    pub fn queryPeers(self: *DistributedRegistry, name: []const u8) ?RemoteProcessInfo {
        if (!protocol.isValidName(name)) return null;

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
        const cmd = protocol.writeFrame(&buf, "WHERE {s}", .{name}) catch return false;
        _ = stream.write(cmd) catch return false;

        var resp_buf: [256]u8 = undefined;
        const line = Protocol.readLine(stream, &resp_buf) orelse return false;
        return std.mem.eql(u8, line, "FOUND");
    }

    fn cacheRemoteRegistration(self: *DistributedRegistry, name: []const u8, info: RemoteProcessInfo) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Reserve before removing the old entry so allocation failure cannot
        // erase a previously valid cache record.
        try self.remote_registrations.ensureUnusedCapacity(1);

        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        const info_name = try self.allocator.dupe(u8, info.name);
        errdefer self.allocator.free(info_name);
        const info_addr = try self.allocator.dupe(u8, info.node_address);
        errdefer self.allocator.free(info_addr);

        if (self.remote_registrations.fetchRemove(name)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value.name);
            self.allocator.free(old.value.node_address);
        }

        self.remote_registrations.putAssumeCapacityNoClobber(name_copy, .{
            .name = info_name,
            .node_address = info_addr,
            .node_port = info.node_port,
        });
    }

    fn uncacheRemoteRegistration(self: *DistributedRegistry, name: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.remote_registrations.fetchRemove(name)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value.name);
            self.allocator.free(entry.value.node_address);
        }
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

        var frame_buf: [128]u8 = undefined;
        const frame = protocol.writeFrame(&frame_buf, "HEART", .{}) catch {
            node.is_alive = false;
            return;
        };
        _ = stream.write(frame) catch {
            node.is_alive = false;
            return;
        };

        var buf: [64]u8 = undefined;
        if (Protocol.readLine(stream, &buf)) |line| {
            if (std.mem.eql(u8, line, "ALIVE")) {
                node.last_seen_ms = compat.monotonicMilliTimestamp();
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
        const cmd = protocol.writeFrame(&buf, "REG {s}", .{name}) catch return;
        _ = stream.write(cmd) catch {};
    }

    /// Handle a single incoming connection on the listener
    fn handleIncoming(self: *DistributedRegistry, stream: net.Stream, peer_addr: net.Ip4Address) void {
        defer stream.close();

        var buffer: [1024]u8 = undefined;
        const line = Protocol.readLine(stream, &buffer) orelse return;

        const command = protocol.parse(line) catch {
            Protocol.sendFrame(stream, "ERR unsupported protocol\n");
            return;
        };

        switch (command) {
            .where => |name| {
                if (self.local_registry.whereis(name) != null) {
                    Protocol.sendFrame(stream, "FOUND\n");
                } else {
                    Protocol.sendFrame(stream, "NOTFOUND\n");
                }
            },
            .reg => |name| {
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
            },
            .unreg => |name| {
                self.uncacheRemoteRegistration(name);
                Protocol.sendFrame(stream, "OK\n");
            },
            .heart => {
                Protocol.sendFrame(stream, "ALIVE\n");
            },
            .hello => {
                Protocol.sendFrame(stream, "OK\n");
            },
        }
    }

    /// Start the listener and background synchronization threads.
    ///
    /// Call `stopSync()` before deinitializing, or rely on `deinit()` which
    /// calls it for you. Returns `error.AlreadySyncing` if sync is already
    /// active.
    pub fn startSync(self: *DistributedRegistry) !void {
        self.mutex.lock();
        if (self.should_sync.load(.acquire) or self.listener_thread != null or self.sync_thread != null) {
            self.mutex.unlock();
            return error.AlreadySyncing;
        }

        self.should_sync.store(true, .release);

        // Start listener thread
        self.listener_thread = std.Thread.spawn(.{}, listenerLoop, .{self}) catch |err| {
            self.should_sync.store(false, .release);
            self.mutex.unlock();
            return err;
        };

        // Start sync thread
        self.sync_thread = std.Thread.spawn(.{}, syncLoop, .{self}) catch |err| {
            self.should_sync.store(false, .release);
            const listener = self.listener_thread;
            self.listener_thread = null;
            self.mutex.unlock();
            if (listener) |thread| thread.join();
            return err;
        };
        self.mutex.unlock();
    }

    /// Stop synchronization and listener threads.
    ///
    /// This closes the listener socket to unblock `accept()` and then joins the
    /// background threads. It is safe to call when sync is not active.
    pub fn stopSync(self: *DistributedRegistry) void {
        self.should_sync.store(false, .release);

        self.mutex.lock();
        const listener_fd = self.listener_fd;
        self.listener_fd = null;
        const listener_thread = self.listener_thread;
        self.listener_thread = null;
        const sync_thread = self.sync_thread;
        self.sync_thread = null;
        self.mutex.unlock();

        // Close listener socket to unblock accept().
        if (listener_fd) |fd| compat.sockets.close(fd);

        if (listener_thread) |thread| thread.join();
        if (sync_thread) |thread| thread.join();
    }

    /// TCP listener loop - accepts incoming protocol connections
    fn listenerLoop(self: *DistributedRegistry) void {
        const addr = net.parseIp4("0.0.0.0", self.config.listen_port) catch {
            self.should_sync.store(false, .release);
            return;
        };
        const fd = compat.sockets.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP) catch {
            self.should_sync.store(false, .release);
            return;
        };

        self.mutex.lock();
        self.listener_fd = fd;
        self.mutex.unlock();
        defer {
            self.mutex.lock();
            const still_owned = self.listener_fd != null and self.listener_fd.? == fd;
            if (still_owned) self.listener_fd = null;
            self.mutex.unlock();
            if (still_owned) compat.sockets.close(fd);
        }

        if (!self.should_sync.load(.acquire)) return;

        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1))) catch {};
        compat.sockets.bind(fd, &addr.any, addr.getOsSockLen()) catch {
            self.should_sync.store(false, .release);
            return;
        };
        compat.sockets.listen(fd, 32) catch {
            self.should_sync.store(false, .release);
            return;
        };

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
                const now_ms = compat.monotonicMilliTimestamp();
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

test "DistributedRegistry init cleans up partially copied nodes" {
    const Case = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var registry = try DistributedRegistry.init(allocator, .{
                .cluster_nodes = &.{ "127.0.0.1:9001", "127.0.0.2:9002", "127.0.0.3:9003" },
            });
            defer registry.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}

test "DistributedRegistry global registration rolls back local state on OOM" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var registry = try DistributedRegistry.init(failing.allocator(), .{ .cluster_nodes = &.{} });
    defer registry.deinit();
    var mailbox = ProcessMailbox.init(std.testing.allocator, .{ .capacity = 1 });
    defer mailbox.deinit();

    // Pre-size the local registry so the target operation allocates its copied
    // local name and then its copied global name.
    try registry.register("seed", &mailbox, .local);
    registry.local_registry.unregister("seed");
    failing.fail_index = failing.alloc_index + 1;

    try std.testing.expectError(error.OutOfMemory, registry.register("target", &mailbox, .global));
    try std.testing.expect(registry.whereis("target") == null);
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

test "DistributedRegistry rejects names that cannot be encoded in one frame" {
    const allocator = std.testing.allocator;
    var registry = try DistributedRegistry.init(allocator, .{ .cluster_nodes = &.{} });
    defer registry.deinit();
    var mailbox = ProcessMailbox.init(allocator, .{ .capacity = 1 });
    defer mailbox.deinit();

    try std.testing.expectError(error.InvalidName, registry.register("two words", &mailbox, .global));
    try std.testing.expect(registry.whereis("two words") == null);
    try std.testing.expect(registry.queryPeers("line\nbreak") == null);
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

test "DistributedRegistry rejects invalid timing and node configuration" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidConfiguration, DistributedRegistry.init(allocator, .{
        .cluster_nodes = &.{},
        .sync_interval_ms = 0,
    }));
    try std.testing.expectError(error.InvalidConfiguration, DistributedRegistry.init(allocator, .{
        .cluster_nodes = &.{},
        .heartbeat_timeout_ms = 0,
    }));
    try std.testing.expectError(error.InvalidNodeFormat, DistributedRegistry.init(allocator, .{
        .cluster_nodes = &.{":9001"},
    }));
    try std.testing.expectError(error.InvalidNodeFormat, DistributedRegistry.init(allocator, .{
        .cluster_nodes = &.{"127.0.0.1:0"},
    }));
}

test "DistributedRegistry repeatedly starts and stops background threads" {
    const allocator = std.testing.allocator;
    var registry = try DistributedRegistry.init(allocator, .{
        .cluster_nodes = &.{},
        .sync_interval_ms = 1,
        .listen_port = 0,
    });
    defer registry.deinit();

    for (0..4) |_| {
        try registry.startSync();
        registry.stopSync();
        try std.testing.expect(!registry.should_sync.load(.acquire));
        try std.testing.expect(registry.listener_thread == null);
        try std.testing.expect(registry.sync_thread == null);
        try std.testing.expect(registry.listener_fd == null);
    }
}
