//! Distributed registry for Vigil.
//!
//! Cross-process name resolution with TCP-based cluster communication.
//! Peer communication uses one persistent connection per peer with
//! exponential reconnect backoff; registration sync is batched into single
//! writes, and the listener serves each incoming connection on its own
//! thread so persistent peers do not block one another.

const std = @import("std");
const posix = std.posix;
const Registry = @import("registry.zig").Registry;
const ProcessMailbox = @import("messages.zig").ProcessMailbox;
const compat = @import("compat.zig");
const net = compat.net;
const protocol = @import("distributed_protocol.zig");

/// Peer node tracked by a distributed registry.
///
/// Connection state is owned by the registry: one persistent socket per
/// peer, serialized by `io_mutex`, reconnected with exponential backoff
/// after failures.
pub const ClusterNode = struct {
    /// IPv4 address or host string used for TCP connections.
    address: []const u8,
    /// Peer listen port.
    port: u16,
    /// Last heartbeat or successful contact time in milliseconds.
    last_seen_ms: i64,
    /// Whether the node is currently considered reachable.
    is_alive: bool,
    /// Serializes request/response exchanges on the persistent connection
    /// and guards the connection fields below.
    io_mutex: compat.Mutex = .{},
    /// Open persistent connection, when one exists.
    conn_fd: ?posix.socket_t = null,
    /// Consecutive failed exchanges since the last success.
    consecutive_failures: u32 = 0,
    /// Monotonic time before which reconnect attempts are skipped.
    next_attempt_ms: i64 = 0,
    /// Lifetime count of connections established to this peer.
    reconnects: u64 = 0,
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

/// Snapshot of one peer's health and connection state.
pub const PeerSnapshot = struct {
    /// Copied peer address.
    address: []const u8,
    /// Peer listen port.
    port: u16,
    /// Whether the peer is currently considered reachable.
    is_alive: bool,
    /// Last successful contact time in milliseconds.
    last_seen_ms: i64,
    /// Consecutive failed exchanges since the last success.
    consecutive_failures: u32,
    /// Lifetime count of connections established.
    reconnects: u64,
};

/// Owned snapshot of distributed registry health and counters.
pub const DistributedRegistrySnapshot = struct {
    allocator: std.mem.Allocator,
    /// Per-peer health with copied addresses.
    peers: []PeerSnapshot,
    /// Names registered locally.
    local_names: usize,
    /// Names cached from remote peers.
    cached_remote_names: usize,
    /// `whereisGlobal` answers served from local or cached state.
    cache_hits: u64,
    /// `whereisGlobal` misses that found nothing cached.
    cache_misses: u64,
    /// WHERE queries sent to peers.
    peer_queries: u64,
    /// Heartbeats sent to peers.
    heartbeats: u64,
    /// Registration frames synced to peers.
    sync_frames: u64,

    /// Release copied addresses and snapshot storage.
    pub fn deinit(self: *DistributedRegistrySnapshot) void {
        for (self.peers) |peer| {
            self.allocator.free(peer.address);
        }
        self.allocator.free(self.peers);
    }
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

    /// Consume `expected` newline-terminated replies, discarding content.
    fn drainReplies(stream: net.Stream, expected: usize) bool {
        var buffer: [512]u8 = undefined;
        var seen: usize = 0;
        while (seen < expected) {
            const n = stream.read(&buffer) catch return false;
            if (n == 0) return false;
            seen += std.mem.count(u8, buffer[0..n], "\n");
        }
        return true;
    }
};

/// Reconnect backoff bounds for failed peers.
const initial_backoff_ms: i64 = 250;
const max_backoff_ms: i64 = 30_000;

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
    /// Known peer nodes at stable addresses.
    nodes: std.ArrayListUnmanaged(*ClusterNode),
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
    /// Per-connection handler threads spawned by the listener.
    conn_threads: std.ArrayListUnmanaged(std.Thread),
    /// Fds currently owned by connection handlers.
    conn_fds: std.ArrayListUnmanaged(posix.socket_t),
    /// Lifetime counters for metrics snapshots.
    cache_hits: std.atomic.Value(u64),
    cache_misses: std.atomic.Value(u64),
    peer_queries: std.atomic.Value(u64),
    heartbeats: std.atomic.Value(u64),
    sync_frames: std.atomic.Value(u64),

    /// Initialize a distributed registry from `config`.
    ///
    /// Each `cluster_nodes` entry must be in `host:port` format.
    pub fn init(allocator: std.mem.Allocator, config: DistributedRegistryConfig) !DistributedRegistry {
        if (config.sync_interval_ms == 0 or config.heartbeat_timeout_ms == 0) {
            return error.InvalidConfiguration;
        }

        var nodes: std.ArrayListUnmanaged(*ClusterNode) = .empty;
        errdefer {
            for (nodes.items) |node| {
                allocator.free(node.address);
                allocator.destroy(node);
            }
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

            const node = try allocator.create(ClusterNode);
            errdefer allocator.destroy(node);

            const address_copy = try allocator.dupe(u8, address);
            errdefer allocator.free(address_copy);

            node.* = .{
                .address = address_copy,
                .port = port,
                .last_seen_ms = compat.monotonicMilliTimestamp(),
                .is_alive = true,
            };
            try nodes.append(allocator, node);
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
            .conn_threads = .empty,
            .conn_fds = .empty,
            .cache_hits = std.atomic.Value(u64).init(0),
            .cache_misses = std.atomic.Value(u64).init(0),
            .peer_queries = std.atomic.Value(u64).init(0),
            .heartbeats = std.atomic.Value(u64).init(0),
            .sync_frames = std.atomic.Value(u64).init(0),
        };
    }

    /// Stop background sync and release registry-owned storage.
    pub fn deinit(self: *DistributedRegistry) void {
        self.stopSync();

        for (self.nodes.items) |node| {
            if (node.conn_fd) |fd| compat.sockets.close(fd);
            self.allocator.free(node.address);
            self.allocator.destroy(node);
        }
        self.nodes.deinit(self.allocator);
        self.conn_threads.deinit(self.allocator);
        self.conn_fds.deinit(self.allocator);

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
            _ = self.cache_hits.fetchAdd(1, .monotonic);
            return RemoteProcessInfo{
                .name = name,
                .node_address = "local",
                .node_port = self.config.listen_port,
            };
        }

        // Check remote cache
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.remote_registrations.get(name)) |info| {
            _ = self.cache_hits.fetchAdd(1, .monotonic);
            return info;
        }
        _ = self.cache_misses.fetchAdd(1, .monotonic);
        return null;
    }

    /// Actively query all peer nodes for a name.
    ///
    /// Updates the remote registration cache on success. Queries reuse each
    /// peer's persistent connection; unreachable peers are skipped while
    /// their reconnect backoff is pending.
    pub fn queryPeers(self: *DistributedRegistry, name: []const u8) ?RemoteProcessInfo {
        if (!protocol.isValidName(name)) return null;

        const peers = self.snapshotPeers() orelse return null;
        defer self.allocator.free(peers);

        for (peers) |node| {
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

    /// Capture an owned snapshot of peer health and lifetime counters.
    ///
    /// The caller owns the returned snapshot and must call `deinit()`.
    pub fn snapshot(self: *DistributedRegistry, allocator: std.mem.Allocator) !DistributedRegistrySnapshot {
        self.mutex.lock();
        const node_count = self.nodes.items.len;
        const cached_remote = self.remote_registrations.count();

        const peers = allocator.alloc(PeerSnapshot, node_count) catch |err| {
            self.mutex.unlock();
            return err;
        };
        var written: usize = 0;
        errdefer {
            for (peers[0..written]) |peer| allocator.free(peer.address);
            allocator.free(peers);
        }

        for (self.nodes.items) |node| {
            const address_copy = allocator.dupe(u8, node.address) catch |err| {
                self.mutex.unlock();
                return err;
            };
            node.io_mutex.lock();
            peers[written] = .{
                .address = address_copy,
                .port = node.port,
                .is_alive = node.is_alive,
                .last_seen_ms = node.last_seen_ms,
                .consecutive_failures = node.consecutive_failures,
                .reconnects = node.reconnects,
            };
            node.io_mutex.unlock();
            written += 1;
        }
        self.mutex.unlock();

        return .{
            .allocator = allocator,
            .peers = peers,
            .local_names = self.local_registry.count(),
            .cached_remote_names = cached_remote,
            .cache_hits = self.cache_hits.load(.monotonic),
            .cache_misses = self.cache_misses.load(.monotonic),
            .peer_queries = self.peer_queries.load(.monotonic),
            .heartbeats = self.heartbeats.load(.monotonic),
            .sync_frames = self.sync_frames.load(.monotonic),
        };
    }

    /// Copy the stable peer pointers so network work happens without the
    /// registry mutex held.
    fn snapshotPeers(self: *DistributedRegistry) ?[]*ClusterNode {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.allocator.dupe(*ClusterNode, self.nodes.items) catch null;
    }

    fn openPeerSocket(node: *ClusterNode) ?posix.socket_t {
        const addr = net.parseIp4(node.address, node.port) catch return null;
        const fd = compat.sockets.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP) catch return null;

        const timeout = posix.timeval{ .sec = 1, .usec = 0 };
        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch {};
        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};

        compat.sockets.connect(fd, &addr.any, addr.getOsSockLen()) catch {
            compat.sockets.close(fd);
            return null;
        };
        return fd;
    }

    fn recordPeerFailureLocked(node: *ClusterNode) void {
        if (node.conn_fd) |fd| {
            compat.sockets.close(fd);
            node.conn_fd = null;
        }
        node.consecutive_failures +|= 1;
        node.is_alive = false;

        const shift: u6 = @intCast(@min(node.consecutive_failures - 1, 7));
        const backoff = @min(initial_backoff_ms << shift, max_backoff_ms);
        node.next_attempt_ms = compat.monotonicMilliTimestamp() +| backoff;
    }

    const Exchange = struct {
        request: []const u8,
        /// Number of newline-terminated replies to consume. When
        /// `reply_buffer` is set, the first reply line is returned instead.
        expected_replies: usize,
        reply_buffer: ?[]u8 = null,
    };

    /// Perform one request/response exchange on the peer's persistent
    /// connection, reconnecting once when the connection has gone stale.
    ///
    /// Returns the first reply line when a reply buffer is provided, an
    /// empty slice for successful reply-draining exchanges, or null on
    /// failure (which records reconnect backoff on the peer).
    fn peerExchange(node: *ClusterNode, exchange: Exchange) ?[]const u8 {
        node.io_mutex.lock();
        defer node.io_mutex.unlock();

        const now_ms = compat.monotonicMilliTimestamp();
        if (node.conn_fd == null and now_ms < node.next_attempt_ms) return null;

        var attempt: u2 = 0;
        while (attempt < 2) : (attempt += 1) {
            const fd = node.conn_fd orelse blk: {
                const new_fd = openPeerSocket(node) orelse break;
                node.conn_fd = new_fd;
                node.reconnects +|= 1;
                break :blk new_fd;
            };
            const stream = net.Stream{ .handle = fd };

            const wrote = stream.write(exchange.request) catch 0;
            if (wrote == exchange.request.len) {
                if (exchange.reply_buffer) |buffer| {
                    if (Protocol.readLine(stream, buffer)) |line| {
                        node.consecutive_failures = 0;
                        return line;
                    }
                } else if (Protocol.drainReplies(stream, exchange.expected_replies)) {
                    node.consecutive_failures = 0;
                    return "";
                }
            }

            // Stale or broken connection: drop it and retry once with a
            // fresh connect before declaring the peer unreachable.
            compat.sockets.close(fd);
            node.conn_fd = null;
        }

        recordPeerFailureLocked(node);
        return null;
    }

    /// Query a single node for a name over its persistent connection.
    fn queryNode(self: *DistributedRegistry, node: *ClusterNode, name: []const u8) bool {
        var frame_buf: [256]u8 = undefined;
        const frame = protocol.writeFrame(&frame_buf, "WHERE {s}", .{name}) catch return false;

        _ = self.peer_queries.fetchAdd(1, .monotonic);
        var reply_buf: [256]u8 = undefined;
        const reply = peerExchange(node, .{
            .request = frame,
            .expected_replies = 1,
            .reply_buffer = &reply_buf,
        }) orelse return false;
        return std.mem.eql(u8, reply, "FOUND");
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

    /// Send heartbeat to a node over its persistent connection.
    fn sendHeartbeat(self: *DistributedRegistry, node: *ClusterNode) void {
        var frame_buf: [128]u8 = undefined;
        const frame = protocol.writeFrame(&frame_buf, "HEART", .{}) catch return;

        _ = self.heartbeats.fetchAdd(1, .monotonic);
        var reply_buf: [64]u8 = undefined;
        const reply = peerExchange(node, .{
            .request = frame,
            .expected_replies = 1,
            .reply_buffer = &reply_buf,
        }) orelse return;

        if (std.mem.eql(u8, reply, "ALIVE")) {
            node.io_mutex.lock();
            node.last_seen_ms = compat.monotonicMilliTimestamp();
            node.is_alive = true;
            node.io_mutex.unlock();
        }
    }

    /// Sync all global registrations to one peer as a single batched write.
    fn syncRegistrations(self: *DistributedRegistry, node: *ClusterNode, names: []const []const u8) void {
        if (names.len == 0) return;

        var batch: std.ArrayListUnmanaged(u8) = .empty;
        defer batch.deinit(self.allocator);

        var frame_buf: [256]u8 = undefined;
        var frames: usize = 0;
        for (names) |name| {
            const frame = protocol.writeFrame(&frame_buf, "REG {s}", .{name}) catch continue;
            batch.appendSlice(self.allocator, frame) catch return;
            frames += 1;
        }
        if (frames == 0) return;

        _ = self.sync_frames.fetchAdd(frames, .monotonic);
        _ = peerExchange(node, .{
            .request = batch.items,
            .expected_replies = frames,
        });
    }

    /// Handle one incoming connection until it closes or sync stops.
    ///
    /// Lines are processed as they arrive, so a peer may pipeline several
    /// frames in one write (batched REG sync does exactly that).
    fn handleConnection(self: *DistributedRegistry, fd: posix.socket_t, peer_addr: net.Ip4Address) void {
        const stream = net.Stream{ .handle = fd };
        const timeout = posix.timeval{ .sec = 1, .usec = 0 };
        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};

        var buffer: [2048]u8 = undefined;
        var used: usize = 0;

        while (self.should_sync.load(.acquire)) {
            const n = stream.read(buffer[used..]) catch |err| switch (err) {
                error.TimedOut => continue, // idle persistent connection
                else => break,
            };
            if (n == 0) break;
            used += n;

            // Process every complete line in the buffer.
            var consumed: usize = 0;
            while (std.mem.indexOfScalarPos(u8, buffer[0..used], consumed, '\n')) |line_end| {
                var end = line_end;
                if (end > consumed and buffer[end - 1] == '\r') end -= 1;
                self.handleFrame(stream, buffer[consumed..end], peer_addr);
                consumed = line_end + 1;
            }

            // Keep any partial trailing line for the next read.
            if (consumed > 0) {
                std.mem.copyForwards(u8, buffer[0 .. used - consumed], buffer[consumed..used]);
                used -= consumed;
            } else if (used == buffer.len) {
                break; // oversized frame without a newline
            }
        }
        compat.sockets.close(fd);
    }

    fn handleFrame(self: *DistributedRegistry, stream: net.Stream, line: []const u8, peer_addr: net.Ip4Address) void {
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
    /// This closes the listener socket to unblock `accept()`, joins the
    /// background and per-connection threads, and drops persistent peer
    /// connections. It is safe to call when sync is not active.
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

        // Join per-connection handlers. Each handler observes should_sync
        // within its 1s receive timeout, closes its own fd, and exits.
        self.mutex.lock();
        var threads = self.conn_threads;
        self.conn_threads = .empty;
        self.conn_fds.clearRetainingCapacity();
        self.mutex.unlock();
        for (threads.items) |thread| thread.join();
        threads.deinit(self.allocator);

        // Drop persistent peer connections.
        for (self.nodes.items) |node| {
            node.io_mutex.lock();
            if (node.conn_fd) |fd| {
                compat.sockets.close(fd);
                node.conn_fd = null;
            }
            node.io_mutex.unlock();
        }
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

            // Serve each connection on its own thread so a persistent peer
            // cannot block other peers' requests.
            self.mutex.lock();
            const spawned = blk: {
                const thread = std.Thread.spawn(.{}, handleConnection, .{ self, conn.stream.handle, conn.address }) catch break :blk false;
                self.conn_threads.append(self.allocator, thread) catch {
                    // Track failure: the handler owns the fd and exits once
                    // should_sync clears, but we cannot join it later.
                    thread.detach();
                    break :blk true;
                };
                break :blk true;
            };
            self.mutex.unlock();

            if (!spawned) {
                // Could not spawn a handler: serve the connection inline so
                // the peer still gets an answer.
                self.handleConnection(conn.stream.handle, conn.address);
            }
        }
    }

    /// Synchronization loop - heartbeats and batched registration sync
    fn syncLoop(self: *DistributedRegistry) void {
        while (self.should_sync.load(.acquire)) {
            const peers = self.snapshotPeers() orelse {
                compat.sleep(@as(u64, self.config.sync_interval_ms) * std.time.ns_per_ms);
                continue;
            };
            defer self.allocator.free(peers);

            // Copy global names so network writes happen without the mutex.
            var names: std.ArrayListUnmanaged([]const u8) = .empty;
            defer {
                for (names.items) |name| self.allocator.free(name);
                names.deinit(self.allocator);
            }
            self.mutex.lock();
            var name_it = self.global_names.iterator();
            while (name_it.next()) |entry| {
                const copy = self.allocator.dupe(u8, entry.key_ptr.*) catch break;
                names.append(self.allocator, copy) catch {
                    self.allocator.free(copy);
                    break;
                };
            }
            self.mutex.unlock();

            const now_ms = compat.monotonicMilliTimestamp();
            for (peers) |node| {
                self.sendHeartbeat(node);

                node.io_mutex.lock();
                if (now_ms - node.last_seen_ms > self.config.heartbeat_timeout_ms) {
                    node.is_alive = false;
                }
                const alive = node.is_alive;
                node.io_mutex.unlock();

                if (alive) {
                    self.syncRegistrations(node, names.items);
                }
            }

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

test "DistributedRegistry snapshot reports peer health and counters" {
    const allocator = std.testing.allocator;
    var registry = try DistributedRegistry.init(allocator, .{
        .cluster_nodes = &.{"10.0.0.9:9450"},
    });
    defer registry.deinit();

    var mailbox = ProcessMailbox.init(allocator, .{ .capacity = 1 });
    defer mailbox.deinit();
    try registry.register("local_only", &mailbox, .local);
    _ = registry.whereisGlobal("local_only"); // hit
    _ = registry.whereisGlobal("missing"); // miss

    var state = try registry.snapshot(allocator);
    defer state.deinit();

    try std.testing.expectEqual(@as(usize, 1), state.peers.len);
    try std.testing.expectEqualStrings("10.0.0.9", state.peers[0].address);
    try std.testing.expectEqual(@as(u16, 9450), state.peers[0].port);
    try std.testing.expectEqual(@as(usize, 1), state.local_names);
    try std.testing.expectEqual(@as(u64, 1), state.cache_hits);
    try std.testing.expectEqual(@as(u64, 1), state.cache_misses);
    try std.testing.expectEqual(@as(u64, 0), state.peer_queries);
}

test "DistributedRegistry resolves peers over persistent connections" {
    const allocator = std.testing.allocator;

    // Node A: listens and owns the target name.
    var node_a = try DistributedRegistry.init(allocator, .{
        .cluster_nodes = &.{},
        .listen_port = 39417,
        .sync_interval_ms = 10,
    });
    defer node_a.deinit();
    var mailbox = ProcessMailbox.init(allocator, .{ .capacity = 1 });
    defer mailbox.deinit();
    try node_a.register("billing_service", &mailbox, .global);
    try node_a.startSync();
    defer node_a.stopSync();

    // Node B: knows A as a peer; queries actively without its own listener.
    var node_b = try DistributedRegistry.init(allocator, .{
        .cluster_nodes = &.{"127.0.0.1:39417"},
        .listen_port = 39418,
        .sync_interval_ms = 10,
    });
    defer node_b.deinit();

    // A's listener needs a moment to bind; poll until the query resolves.
    var found: ?RemoteProcessInfo = null;
    var waited_ms: u32 = 0;
    while (found == null and waited_ms < 3_000) : (waited_ms += 20) {
        found = node_b.queryPeers("billing_service");
        if (found == null) compat.sleep(20 * std.time.ns_per_ms);
    }
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("127.0.0.1", found.?.node_address);

    // Repeat queries reuse the same persistent connection.
    try std.testing.expect(node_b.queryPeers("billing_service") != null);
    try std.testing.expect(node_b.queryPeers("unknown_service") == null);

    var state = try node_b.snapshot(allocator);
    defer state.deinit();
    try std.testing.expect(state.peer_queries >= 3);
    try std.testing.expectEqual(@as(u64, 1), state.peers[0].reconnects);
    try std.testing.expectEqual(@as(u32, 0), state.peers[0].consecutive_failures);

    // The resolved name is cached for whereisGlobal.
    try std.testing.expect(node_b.whereisGlobal("billing_service") != null);

    // Partition: stop A; B's queries fail and the peer records failures
    // with reconnect backoff.
    node_a.stopSync();
    var failed = node_b.queryPeers("billing_service_2");
    var retries: u32 = 0;
    while (failed != null and retries < 10) : (retries += 1) {
        compat.sleep(10 * std.time.ns_per_ms);
        failed = node_b.queryPeers("billing_service_2");
    }
    try std.testing.expect(failed == null);

    var partitioned = try node_b.snapshot(allocator);
    defer partitioned.deinit();
    try std.testing.expect(partitioned.peers[0].consecutive_failures >= 1);
    try std.testing.expect(!partitioned.peers[0].is_alive);
}

test "DistributedRegistry heals after a partition and reconnects" {
    const allocator = std.testing.allocator;

    var node_a = try DistributedRegistry.init(allocator, .{
        .cluster_nodes = &.{},
        .listen_port = 39421,
        .sync_interval_ms = 10,
    });
    defer node_a.deinit();
    var mailbox = ProcessMailbox.init(allocator, .{ .capacity = 1 });
    defer mailbox.deinit();
    try node_a.register("healing_service", &mailbox, .global);
    try node_a.startSync();
    defer node_a.stopSync();

    var node_b = try DistributedRegistry.init(allocator, .{
        .cluster_nodes = &.{"127.0.0.1:39421"},
        .listen_port = 39422,
        .sync_interval_ms = 10,
    });
    defer node_b.deinit();

    // Resolve once so a persistent connection exists.
    var found: ?RemoteProcessInfo = null;
    var waited_ms: u32 = 0;
    while (found == null and waited_ms < 3_000) : (waited_ms += 20) {
        found = node_b.queryPeers("healing_service");
        if (found == null) compat.sleep(20 * std.time.ns_per_ms);
    }
    try std.testing.expect(found != null);

    // Partition: stop A entirely; B's queries fail and the peer goes dead.
    node_a.stopSync();
    var lost = node_b.queryPeers("healing_service");
    var retries: u32 = 0;
    while (lost != null and retries < 20) : (retries += 1) {
        compat.sleep(10 * std.time.ns_per_ms);
        lost = node_b.queryPeers("healing_service");
    }
    try std.testing.expect(lost == null);

    // Heal: restart A's listener; B reconnects once its backoff expires.
    try node_a.startSync();
    var healed: ?RemoteProcessInfo = null;
    waited_ms = 0;
    while (healed == null and waited_ms < 5_000) : (waited_ms += 50) {
        compat.sleep(50 * std.time.ns_per_ms);
        healed = node_b.queryPeers("healing_service");
    }
    try std.testing.expect(healed != null);

    var state = try node_b.snapshot(allocator);
    defer state.deinit();
    try std.testing.expectEqual(@as(u32, 0), state.peers[0].consecutive_failures);
    try std.testing.expect(state.peers[0].reconnects >= 2);
}

test "DistributedRegistry syncs global names to peers in the background" {
    const allocator = std.testing.allocator;

    // A listens and receives sync; B pushes its global registrations to A.
    var node_a = try DistributedRegistry.init(allocator, .{
        .cluster_nodes = &.{},
        .listen_port = 39423,
        .sync_interval_ms = 10,
    });
    defer node_a.deinit();
    try node_a.startSync();
    defer node_a.stopSync();

    var node_b = try DistributedRegistry.init(allocator, .{
        .cluster_nodes = &.{"127.0.0.1:39423"},
        .listen_port = 39424,
        .sync_interval_ms = 10,
    });
    defer node_b.deinit();
    var mailbox = ProcessMailbox.init(allocator, .{ .capacity = 1 });
    defer mailbox.deinit();
    try node_b.register("synced_service", &mailbox, .global);
    try node_b.startSync();
    defer node_b.stopSync();

    // B's sync loop batches REG frames to A; A caches the remote name and
    // can then resolve it without an active query.
    var resolved: ?RemoteProcessInfo = null;
    var waited_ms: u32 = 0;
    while (resolved == null and waited_ms < 5_000) : (waited_ms += 50) {
        compat.sleep(50 * std.time.ns_per_ms);
        resolved = node_a.whereisGlobal("synced_service");
    }
    try std.testing.expect(resolved != null);

    var state = try node_b.snapshot(allocator);
    defer state.deinit();
    try std.testing.expect(state.sync_frames >= 1);
    try std.testing.expect(state.heartbeats >= 1);
}
