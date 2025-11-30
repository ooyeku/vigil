const std = @import("std");
const vigil = @import("vigil");
const net = std.net;
const posix = std.posix;

// Configuration
const MAX_CONNECTIONS = 1000;
const SERVER_PORT = 9090;
const SERVER_ADDRESS = "127.0.0.1";

// Global shutdown signal
var sig_received = std.atomic.Value(bool).init(false);

// Server metrics using Vigil's telemetry
const ServerMetrics = struct {
    total_connections: std.atomic.Value(usize),
    active_connections: std.atomic.Value(usize),
    requests_handled: std.atomic.Value(usize),
    start_time: i64,

    pub fn init() ServerMetrics {
        return .{
            .total_connections = std.atomic.Value(usize).init(0),
            .active_connections = std.atomic.Value(usize).init(0),
            .requests_handled = std.atomic.Value(usize).init(0),
            .start_time = std.time.timestamp(),
        };
    }

    pub fn connectionOpened(self: *ServerMetrics) void {
        _ = self.total_connections.fetchAdd(1, .monotonic);
        _ = self.active_connections.fetchAdd(1, .monotonic);
    }

    pub fn connectionClosed(self: *ServerMetrics) void {
        _ = self.active_connections.fetchSub(1, .monotonic);
    }

    pub fn requestHandled(self: *ServerMetrics) void {
        _ = self.requests_handled.fetchAdd(1, .monotonic);
    }

    pub fn getUptime(self: *ServerMetrics) i64 {
        return std.time.timestamp() - self.start_time;
    }
};

// Server state
const ServerState = struct {
    allocator: std.mem.Allocator,
    metrics: ServerMetrics,
    rate_limiter: vigil.RateLimiter,
    circuit_breaker: vigil.CircuitBreaker,
    is_shutting_down: std.atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator) !ServerState {
        return .{
            .allocator = allocator,
            .metrics = ServerMetrics.init(),
            .rate_limiter = vigil.RateLimiter.init(1000), // 1000 requests/sec
            .circuit_breaker = try vigil.CircuitBreaker.init(allocator, "server", .{
                .failure_threshold = 10,
                .reset_timeout_ms = 5000,
            }),
            .is_shutting_down = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *ServerState) void {
        self.circuit_breaker.deinit();
    }
};

// Connection handler using Vigil's messaging
fn handleConnection(stream: net.Stream, state: *ServerState) void {
    defer {
        stream.close();
        state.metrics.connectionClosed();
    }

    state.metrics.connectionOpened();
    var buffer: [1024]u8 = undefined;

    while (!state.is_shutting_down.load(.acquire)) {
        // Check rate limit
        if (!state.rate_limiter.allow()) {
            const response = "ERROR: Rate limited\n";
            _ = stream.write(response) catch break;
            continue;
        }

        // Check circuit breaker
        if (state.circuit_breaker.getState() == .open) {
            const response = "ERROR: Service temporarily unavailable\n";
            _ = stream.write(response) catch break;
            std.Thread.sleep(100 * std.time.ns_per_ms);
            continue;
        }

        const bytes_read = stream.read(&buffer) catch break;
        if (bytes_read == 0) break;

        const cmd = std.mem.trim(u8, buffer[0..bytes_read], "\r\n");

        // Handle commands
        if (std.mem.eql(u8, cmd, "STATUS")) {
            const response = std.fmt.bufPrint(&buffer, "OK active={d} total={d}\n", .{
                state.metrics.active_connections.load(.monotonic),
                state.metrics.total_connections.load(.monotonic),
            }) catch break;
            _ = stream.write(response) catch break;
        } else if (std.mem.eql(u8, cmd, "HEALTH")) {
            const response = std.fmt.bufPrint(&buffer,
                \\OK
                \\uptime={d}
                \\requests={d}
                \\circuit={s}
                \\
            , .{
                state.metrics.getUptime(),
                state.metrics.requests_handled.load(.monotonic),
                @tagName(state.circuit_breaker.getState()),
            }) catch break;
            _ = stream.write(response) catch break;
        } else if (std.mem.eql(u8, cmd, "METRICS")) {
            const response = std.fmt.bufPrint(&buffer,
                \\active_connections={d}
                \\total_connections={d}
                \\requests_handled={d}
                \\uptime_seconds={d}
                \\
            , .{
                state.metrics.active_connections.load(.monotonic),
                state.metrics.total_connections.load(.monotonic),
                state.metrics.requests_handled.load(.monotonic),
                state.metrics.getUptime(),
            }) catch break;
            _ = stream.write(response) catch break;
        } else {
            // Echo back
            _ = stream.write(buffer[0..bytes_read]) catch break;
        }

        state.metrics.requestHandled();
    }
}

fn runServer(allocator: std.mem.Allocator) !void {
    var state = try ServerState.init(allocator);
    defer state.deinit();

    // Initialize Vigil telemetry
    try vigil.telemetry.initGlobal(allocator);
    if (vigil.telemetry.getGlobal()) |emitter| {
        try emitter.on(.process_started, struct {
            fn handler(event: vigil.telemetry.Event) void {
                std.debug.print("[Telemetry] {s}\n", .{@tagName(event.event_type)});
            }
        }.handler);
    }

    // Initialize shutdown manager
    try vigil.shutdown.initGlobal(allocator);
    try vigil.onShutdown(struct {
        fn cleanup() void {
            std.debug.print("[Shutdown] Server cleanup complete\n", .{});
        }
    }.cleanup);

    // Create TCP server
    const address = try net.Address.parseIp(SERVER_ADDRESS, SERVER_PORT);
    std.debug.print("Starting Vigilant Server on {s}:{d}\n", .{ SERVER_ADDRESS, SERVER_PORT });

    const sock_flags = posix.SOCK.STREAM | posix.SOCK.CLOEXEC;
    const fd = try posix.socket(posix.AF.INET, sock_flags, posix.IPPROTO.TCP);
    errdefer posix.close(fd);

    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try posix.bind(fd, &address.any, address.getOsSockLen());
    try posix.listen(fd, 128);

    var server = net.Server{
        .stream = .{ .handle = fd },
        .listen_address = address,
    };

    std.debug.print("Server ready - Commands: STATUS, HEALTH, METRICS\n", .{});
    std.debug.print("Press Ctrl+C to shutdown\n\n", .{});

    // Accept loop
    while (!sig_received.load(.acquire)) {
        const conn = server.accept() catch |err| switch (err) {
            error.SocketNotListening => break,
            else => {
                if (sig_received.load(.acquire)) break;
                std.debug.print("Accept error: {}\n", .{err});
                continue;
            },
        };

        if (state.metrics.active_connections.load(.monotonic) >= MAX_CONNECTIONS) {
            std.debug.print("Max connections reached, rejecting\n", .{});
            conn.stream.close();
            continue;
        }

        _ = std.Thread.spawn(.{}, handleConnection, .{ conn.stream, &state }) catch |err| {
            std.debug.print("Failed to spawn handler: {}\n", .{err});
            conn.stream.close();
            continue;
        };
    }

    // Graceful shutdown
    std.debug.print("\nInitiating graceful shutdown...\n", .{});
    state.is_shutting_down.store(true, .release);
    posix.close(fd);

    // Wait for active connections
    while (state.metrics.active_connections.load(.monotonic) > 0) {
        std.debug.print("Waiting for {d} connections...\n", .{
            state.metrics.active_connections.load(.monotonic),
        });
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    // Run shutdown hooks
    vigil.shutdownAll(.{});

    std.debug.print("Server shutdown complete\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Setup signal handler
    const handler = struct {
        fn handle(_: c_int) callconv(.c) void {
            sig_received.store(true, .release);
            std.debug.print("\nReceived shutdown signal...\n", .{});
        }
    }.handle;

    var empty_set: std.posix.sigset_t = undefined;
    @memset(@as([*]u8, @ptrCast(&empty_set))[0..@sizeOf(std.posix.sigset_t)], 0);

    std.posix.sigaction(std.posix.SIG.INT, &std.posix.Sigaction{
        .handler = .{ .handler = handler },
        .mask = empty_set,
        .flags = 0,
    }, null);

    try runServer(allocator);
}
