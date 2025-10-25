const std = @import("std");
const vigil = @import("vigil");
const net = std.net;
const posix = std.posix;

// Add at the top with other constants
const MAX_CONNECTIONS = 1000;
const RATE_LIMIT_WINDOW_MS: i64 = 60_000; // 1 minute window
const RATE_LIMIT_MAX_REQUESTS: usize = 10000000; // Max requests per window

const ServerMetrics = struct {
    total_connections: std.atomic.Value(usize),
    active_connections: std.atomic.Value(usize),
    peak_connections: std.atomic.Value(usize),
    total_bytes_received: std.atomic.Value(usize),
    total_bytes_sent: std.atomic.Value(usize),
    start_time: i64,

    pub fn init() ServerMetrics {
        return .{
            .total_connections = std.atomic.Value(usize).init(0),
            .active_connections = std.atomic.Value(usize).init(0),
            .peak_connections = std.atomic.Value(usize).init(0),
            .total_bytes_received = std.atomic.Value(usize).init(0),
            .total_bytes_sent = std.atomic.Value(usize).init(0),
            .start_time = std.time.timestamp(),
        };
    }

    pub fn incrementConnections(self: *ServerMetrics) void {
        _ = self.total_connections.fetchAdd(1, .monotonic);
        const active = self.active_connections.fetchAdd(1, .monotonic);

        var current_peak = self.peak_connections.load(.monotonic);
        while (active + 1 > current_peak) {
            // Use @cmpxchgWeak instead of compareAndSwap
            const swapped = @cmpxchgWeak(usize, &self.peak_connections.raw, current_peak, active + 1, .monotonic, .monotonic);
            if (swapped) |_| break;
            current_peak = self.peak_connections.load(.monotonic);
        }
    }

    pub fn decrementConnections(self: *ServerMetrics) void {
        _ = self.active_connections.fetchSub(1, .monotonic);
    }

    pub fn addBytesReceived(self: *ServerMetrics, bytes: usize) void {
        _ = self.total_bytes_received.fetchAdd(bytes, .monotonic);
    }

    pub fn addBytesSent(self: *ServerMetrics, bytes: usize) void {
        _ = self.total_bytes_sent.fetchAdd(bytes, .monotonic);
    }
};

// Server state to track connections and configuration
const ServerState = struct {
    port: u16,
    address: []const u8,
    pool: ConnectionPool,
    allocator: std.mem.Allocator,
    connections_mutex: std.Thread.Mutex,
    is_shutting_down: std.atomic.Value(bool),
    server: ?*net.Server,
    shutdown_trigger: std.Thread.ResetEvent,
    metrics: ServerMetrics,

    pub fn init(allocator: std.mem.Allocator, address: []const u8, port: u16) !ServerState {
        return ServerState{
            .port = port,
            .address = address,
            .pool = ConnectionPool.init(allocator, MAX_CONNECTIONS),
            .allocator = allocator,
            .connections_mutex = .{},
            .is_shutting_down = std.atomic.Value(bool).init(false),
            .server = null,
            .shutdown_trigger = .{},
            .metrics = ServerMetrics.init(),
        };
    }

    pub fn deinit(self: *ServerState) void {
        if (self.server) |s| {
            s.stream.close();
            self.allocator.destroy(s);
        }
        self.pool.deinit();
    }

    pub fn getActiveConnectionCount(self: *ServerState) usize {
        self.pool.mutex.lock();
        defer self.pool.mutex.unlock();
        return self.pool.connections.items.len - self.pool.idle_connections.items.len;
    }

    pub fn waitForActiveConnections(self: *ServerState) void {
        while (true) {
            const active_count = self.getActiveConnectionCount();
            if (active_count == 0) break;
            std.debug.print("Waiting for {d} active connections to finish...\n", .{active_count});
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
    }
};

// Connection handler
const Connection = struct {
    stream: ?net.Stream = null,
    address: net.Address,
    state: *ServerState,
    buffer: [1024]u8 = undefined,
    last_activity: i64,
    request_count: usize,
    window_start: i64,
    const TIMEOUT_MS: i64 = 30000; // 30 seconds timeout

    pub fn init(stream: net.Stream, address: net.Address, state: *ServerState) Connection {
        const current_time = std.time.timestamp();
        return .{
            .stream = stream,
            .address = address,
            .state = state,
            .buffer = undefined,
            .last_activity = current_time,
            .request_count = 0,
            .window_start = current_time,
        };
    }

    fn checkRateLimit(self: *Connection, stream: net.Stream) !void {
        const current_time = std.time.timestamp();
        const window_elapsed = current_time - self.window_start;

        if (window_elapsed >= RATE_LIMIT_WINDOW_MS / 1000) {
            self.window_start = current_time;
            self.request_count = 0;
        }

        if (self.request_count >= RATE_LIMIT_MAX_REQUESTS) {
            std.debug.print("WARNING: Rate limit exceeded for {any}\n", .{self.address});
            const response = "ERROR: Rate limit exceeded. Please try again later.\n";
            _ = try stream.write(response);
            self.state.metrics.addBytesSent(response.len);
            return error.RateLimitExceeded;
        }

        self.request_count += 1;
    }

    pub fn handle(self: *Connection) !void {
        std.debug.print("Waiting for data from {any}\n", .{self.address});
        const stream = self.stream orelse return error.NoStream;

        while (true) {
            // Check shutdown flag before accepting new requests
            if (self.state.is_shutting_down.load(.acquire)) {
                std.debug.print("Server is shutting down, no new requests accepted from {any}\n", .{self.address});
                return;
            }

            // Check for timeout using timestamp
            const current_time: i64 = std.time.timestamp();
            if (current_time - self.last_activity > TIMEOUT_MS / 1000) {
                std.debug.print("Connection timeout from {any}\n", .{self.address});
                return error.ConnectionTimeout;
            }

            const bytes_read = try stream.read(&self.buffer);
            if (bytes_read == 0) {
                std.debug.print("Zero bytes read, closing connection\n", .{});
                return;
            }

            // Check rate limit before processing request
            try self.checkRateLimit(stream);

            // Update last activity time on successful read
            self.last_activity = std.time.timestamp();

            const cmd = std.mem.trim(u8, self.buffer[0..bytes_read], "\r\n");
            if (std.mem.eql(u8, cmd, "STATUS")) {
                const count = self.state.getActiveConnectionCount();
                const response = try std.fmt.bufPrint(&self.buffer, "OK {d}\n", .{count});
                _ = try stream.write(response[0..response.len]);
                self.state.metrics.addBytesSent(response.len);
                std.debug.print("Sent status response\n", .{});
            } else if (std.mem.eql(u8, cmd, "HEALTHCHECK")) {
                const uptime = std.time.timestamp() - self.state.metrics.start_time;
                const response = try std.fmt.bufPrint(&self.buffer,
                    \\OK
                    \\uptime_seconds={d}
                    \\total_connections={d}
                    \\active_connections={d}
                    \\peak_connections={d}
                    \\bytes_received={d}
                    \\bytes_sent={d}
                    \\
                , .{
                    uptime,
                    self.state.metrics.total_connections.load(.monotonic),
                    self.state.metrics.active_connections.load(.monotonic),
                    self.state.metrics.peak_connections.load(.monotonic),
                    self.state.metrics.total_bytes_received.load(.monotonic),
                    self.state.metrics.total_bytes_sent.load(.monotonic),
                });
                _ = try stream.write(response);
                self.state.metrics.addBytesSent(response.len);
                std.debug.print("Healthcheck responded with metrics\n", .{});
            } else {
                std.debug.print("Received {} bytes: '{s}'\n", .{ bytes_read, cmd });
                _ = try stream.write(self.buffer[0..bytes_read]);
                self.state.metrics.addBytesSent(bytes_read);
                std.debug.print("Echoed {} bytes\n", .{bytes_read});
            }

            self.state.metrics.addBytesReceived(bytes_read);
        }
    }
};

const ConnectionPool = struct {
    connections: std.ArrayList(*Connection),
    idle_connections: std.ArrayList(*Connection),
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    max_pool_size: usize,

    pub fn init(allocator: std.mem.Allocator, max_size: usize) ConnectionPool {
        return .{
            .connections = std.ArrayList(*Connection){},
            .idle_connections = std.ArrayList(*Connection){},
            .allocator = allocator,
            .mutex = .{},
            .max_pool_size = max_size,
        };
    }

    pub fn deinit(self: *ConnectionPool) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.connections.items) |conn| {
            if (conn.stream) |s| {
                s.close();
            }
            self.allocator.destroy(conn);
        }
        self.connections.deinit(self.allocator);
        self.idle_connections.deinit(self.allocator);
    }

    pub fn acquire(self: *ConnectionPool, stream: net.Stream, address: net.Address, state: *ServerState) !*Connection {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Try to reuse an idle connection
        if (self.idle_connections.items.len > 0) {
            // Pop the connection safely
            if (self.idle_connections.pop()) |conn| {
                // Reinitialize the connection fields directly instead of using assignment
                conn.stream = stream;
                conn.address = address;
                conn.state = state;
                conn.buffer = undefined;
                conn.last_activity = std.time.timestamp();
                conn.request_count = 0;
                conn.window_start = std.time.timestamp();
                state.metrics.incrementConnections();
                return conn;
            }
        }

        // Create new connection if pool isn't full
        if (self.connections.items.len < self.max_pool_size) {
            const conn = try self.allocator.create(Connection);
            conn.* = Connection.init(stream, address, state);
            try self.connections.append(self.allocator, conn);
            state.metrics.incrementConnections();
            return conn;
        }

        return error.PoolExhausted;
    }

    pub fn release(self: *ConnectionPool, connection: *Connection) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Safely close the stream first
        if (connection.stream) |s| {
            s.close();
        }
        connection.stream = null;

        // Only reset fields that are safe to reset
        connection.buffer = undefined;

        // Add to idle pool
        // Reset connection state more thoroughly by setting fields directly
        connection.buffer = undefined;
        // Keep the state reference but reset other fields as needed

        try self.idle_connections.append(self.allocator, connection);
        connection.state.metrics.decrementConnections();
    }
};

const ServerConfig = struct {
    address: []const u8,
    port: u16,
};

// Move this to global scope (before main)
var sig_received = std.atomic.Value(bool).init(false);

/// Simple server runner using the high-level Vigil API
fn runServer(allocator: std.mem.Allocator, config: ServerConfig) !void {
    var state = try ServerState.init(allocator, config.address, config.port);
    defer state.deinit();

    // Create TCP server
    const address = try net.Address.parseIp(state.address, state.port);
    std.debug.print("Starting server on {s}:{d}\n", .{ state.address, state.port });

    // Initialize socket with proper flags
    const sock_flags = posix.SOCK.STREAM | posix.SOCK.CLOEXEC;
    const fd = try posix.socket(posix.AF.INET, sock_flags, posix.IPPROTO.TCP);
    errdefer posix.close(fd);

    // Enable address reuse to allow quick restarts
    try posix.setsockopt(
        fd,
        posix.SOL.SOCKET,
        posix.SO.REUSEADDR,
        &std.mem.toBytes(@as(c_int, 1)),
    );

    // Bind the socket
    try posix.bind(fd, &address.any, address.getOsSockLen());
    std.debug.print("Socket bound successfully\n", .{});

    // Start listening
    try posix.listen(fd, 128);
    std.debug.print("Listening for connections...\n", .{});

    // Create heap-allocated server that outlives this function
    const stream_server = try allocator.create(net.Server);
    stream_server.* = .{
        .stream = .{ .handle = fd },
        .listen_address = address,
    };
    errdefer allocator.destroy(stream_server);

    // Store server reference in state
    state.server = stream_server;

    // Accept connections in a separate thread
    const accept_thread = try std.Thread.spawn(.{}, struct {
        fn accept(l: *net.Server, s: *ServerState, alloc: std.mem.Allocator) void {
            defer {
                std.debug.print("Accept loop exiting...\n", .{});
                // Clean up the server struct (socket already closed by main thread)
                alloc.destroy(l);
            }

            while (!s.is_shutting_down.load(.acquire)) {
                const conn = l.accept() catch |err| switch (err) {
                    error.ProcessFdQuotaExceeded => {
                        std.debug.print("WARNING: FD limit reached, waiting...\n", .{});
                        std.Thread.sleep(100 * std.time.ns_per_ms);
                        continue;
                    },
                    error.SocketNotListening => {
                        // Socket was closed, exit gracefully
                        break;
                    },
                    else => {
                        if (s.is_shutting_down.load(.acquire)) break;
                        std.debug.print("Accept error: {}\n", .{err});
                        break;
                    },
                };

                const connection = s.pool.acquire(conn.stream, conn.address, s) catch |err| {
                    conn.stream.close();
                    if (err == error.PoolExhausted) {
                        std.debug.print("WARNING: Pool full, rejecting connection\n", .{});
                        // Add backpressure delay
                        std.Thread.sleep(10 * std.time.ns_per_ms);
                    }
                    continue;
                };

                _ = std.Thread.spawn(.{}, struct {
                    fn handler(c: *Connection, state_ref: *ServerState) void {
                        const addr = c.address;
                        defer {
                            state_ref.pool.release(c) catch {};
                            std.debug.print("Connection closed from {any}\n", .{addr});
                        }
                        c.handle() catch {};
                    }
                }.handler, .{ connection, s }) catch |err| {
                    std.debug.print("Failed to spawn handler thread: {}\n", .{err});
                    if (connection.stream) |stream| {
                        stream.close();
                    }
                };
            }
        }
    }.accept, .{ stream_server, &state, allocator });

    // Wait for shutdown signal
    while (!sig_received.load(.acquire)) {
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    // Graceful shutdown
    std.debug.print("Initiating graceful shutdown...\n", .{});
    state.is_shutting_down.store(true, .release);

    // Close the socket to interrupt accept() - this will be cleaned up by accept thread
    if (state.server) |s| {
        s.stream.close();
        state.server = null;
    }

    // Wait for accept thread to finish cleanup
    accept_thread.join();

    state.waitForActiveConnections();
    std.debug.print("All connections finished, cleaning up...\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = ServerConfig{
        .address = "127.0.0.1",
        .port = 9090,
    };

    const handler = struct {
        fn handle(sig: c_int) callconv(.c) void {
            _ = sig;
            sig_received.store(true, .release);
            std.debug.print("\nReceived interrupt signal (Ctrl-C)...\n", .{});
        }
    }.handle;

    // Create an empty sigset_t
    var empty_set: std.posix.sigset_t = undefined;
    // Initialize it to empty (all bits 0)
    @memset(@as([*]u8, @ptrCast(&empty_set))[0..@sizeOf(std.posix.sigset_t)], 0);

    // In Zig 0.15.1, sigaction returns void, not an error union
    std.posix.sigaction(
        std.posix.SIG.INT,
        &std.posix.Sigaction{
            .handler = .{ .handler = handler },
            .mask = empty_set,
            .flags = 0,
        },
        null,
    );

    std.debug.print("Server started at {s}:{d}\n", .{ config.address, config.port });
    std.debug.print("Press Ctrl+C to initiate graceful shutdown...\n", .{});

    try runServer(allocator, config);

    std.debug.print("Server process exiting\n", .{});
}

pub const AtomicOrder = enum {
    unordered,
    monotonic,
    acquire,
    release,
    acq_rel,
    seq_cst,
};
