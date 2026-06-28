const std = @import("std");
const vigil = @import("vigil");
const net = vigil.compat.net;
const sockets = vigil.compat.sockets;
const posix = std.posix;

// Configuration
const MAX_CONNECTIONS = 1000;
const SERVER_PORT = 9090;
const SERVER_ADDRESS = "127.0.0.1";

// Global shutdown signal
var sig_received = std.atomic.Value(bool).init(false);

fn handleInterrupt(_: std.c.SIG) callconv(.c) void {
    sig_received.store(true, .release);
    std.debug.print("\nReceived shutdown signal...\n", .{});
}

fn installSignalHandlers() void {
    const empty_set = std.posix.sigemptyset();

    std.posix.sigaction(std.posix.SIG.INT, &std.posix.Sigaction{
        .handler = .{ .handler = handleInterrupt },
        .mask = empty_set,
        .flags = 0,
    }, null);

    std.posix.sigaction(std.posix.SIG.PIPE, &std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = empty_set,
        .flags = 0,
    }, null);
}

fn nowSeconds() i64 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.REALTIME, &ts);
    return @intCast(ts.sec);
}

fn sleepFor(nanoseconds: u64) void {
    const ns_per_s = std.time.ns_per_s;
    var req: std.posix.timespec = .{
        .sec = @intCast(nanoseconds / ns_per_s),
        .nsec = @intCast(nanoseconds % ns_per_s),
    };
    var rem: std.posix.timespec = undefined;
    while (std.c.nanosleep(&req, &rem) != 0) {
        req = rem;
    }
}

fn isControlCommand(cmd: []const u8) bool {
    return std.mem.eql(u8, cmd, "STATUS") or
        std.mem.eql(u8, cmd, "HEALTH") or
        std.mem.eql(u8, cmd, "METRICS");
}

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
            .start_time = nowSeconds(),
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
        return nowSeconds() - self.start_time;
    }
};

// Server state
const ServerState = struct {
    allocator: std.mem.Allocator,
    runtime: *vigil.Runtime,
    metrics: ServerMetrics,
    rate_limiter: vigil.RateLimiter,
    circuit_breaker: vigil.CircuitBreaker,
    control_inbox: *vigil.Inbox,
    is_shutting_down: std.atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator, runtime: *vigil.Runtime) !ServerState {
        var circuit_breaker = try vigil.CircuitBreaker.init(allocator, "server", .{
            .failure_threshold = 10,
            .reset_timeout_ms = 5000,
        });
        errdefer circuit_breaker.deinit();

        const control_inbox = try runtime.inbox(.{ .capacity = MAX_CONNECTIONS });
        errdefer control_inbox.close();
        try runtime.register("vigilant.server.control", control_inbox.mailbox);

        return .{
            .allocator = allocator,
            .runtime = runtime,
            .metrics = ServerMetrics.init(),
            .rate_limiter = vigil.RateLimiter.init(1000), // 1000 requests/sec
            .circuit_breaker = circuit_breaker,
            .control_inbox = control_inbox,
            .is_shutting_down = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *ServerState) void {
        self.control_inbox.close();
        self.circuit_breaker.deinit();
    }
};

fn formatStatusResponse(buffer: []u8, state: *ServerState) ![]const u8 {
    const health = try state.runtime.healthWithCircuitBreakers(
        state.allocator,
        &[_]*vigil.CircuitBreaker{&state.circuit_breaker},
    );

    return std.fmt.bufPrint(buffer,
        \\OK active={d} total={d} runtime_status={s} runtime_ready={} registered={d} overloaded={d} unhealthy_circuits={d}
        \\
    , .{
        state.metrics.active_connections.load(.monotonic),
        state.metrics.total_connections.load(.monotonic),
        @tagName(health.status),
        health.ready,
        health.registered_count,
        health.overloaded_inboxes,
        health.unhealthy_circuit_breakers,
    });
}

fn formatHealthResponse(buffer: []u8, state: *ServerState) ![]const u8 {
    const health = try state.runtime.healthWithCircuitBreakers(
        state.allocator,
        &[_]*vigil.CircuitBreaker{&state.circuit_breaker},
    );

    return std.fmt.bufPrint(buffer,
        \\OK
        \\runtime_status={s}
        \\runtime_ready={}
        \\registered={d}
        \\overloaded_inboxes={d}
        \\unhealthy_circuits={d}
        \\uptime={d}
        \\requests={d}
        \\circuit={s}
        \\
    , .{
        @tagName(health.status),
        health.ready,
        health.registered_count,
        health.overloaded_inboxes,
        health.unhealthy_circuit_breakers,
        state.metrics.getUptime(),
        state.metrics.requests_handled.load(.monotonic),
        @tagName(state.circuit_breaker.getState()),
    });
}

// Connection handler using Vigil's messaging
fn handleConnection(stream: net.Stream, state: *ServerState) void {
    defer {
        stream.close();
        state.metrics.connectionClosed();
    }

    var buffer: [1024]u8 = undefined;

    while (!state.is_shutting_down.load(.acquire)) {
        const bytes_read = stream.read(&buffer) catch break;
        if (bytes_read == 0) break;

        const cmd = std.mem.trim(u8, buffer[0..bytes_read], "\r\n");

        if (!isControlCommand(cmd)) {
            if (!state.rate_limiter.allow()) {
                const response = "ERROR: Rate limited\n";
                _ = stream.write(response) catch break;
                state.metrics.requestHandled();
                continue;
            }

            if (state.circuit_breaker.getState() == .open) {
                const response = "ERROR: Service temporarily unavailable\n";
                _ = stream.write(response) catch break;
                state.metrics.requestHandled();
                sleepFor(100 * std.time.ns_per_ms);
                continue;
            }
        }

        // Handle commands
        if (std.mem.eql(u8, cmd, "STATUS")) {
            const response = formatStatusResponse(&buffer, state) catch break;
            _ = stream.write(response) catch break;
        } else if (std.mem.eql(u8, cmd, "HEALTH")) {
            const response = formatHealthResponse(&buffer, state) catch break;
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

fn spawnConnectionHandler(stream: net.Stream, state: *ServerState) !void {
    state.metrics.connectionOpened();
    errdefer state.metrics.connectionClosed();

    const handler_thread = try std.Thread.spawn(.{}, handleConnection, .{ stream, state });
    handler_thread.detach();
}

fn runServer(allocator: std.mem.Allocator) !void {
    var runtime = try vigil.runtime(allocator, .{});
    defer runtime.deinit();

    var state = try ServerState.init(allocator, &runtime);
    defer state.deinit();

    try state.runtime.telemetry_emitter.on(.process_started, struct {
        fn handler(event: vigil.telemetry.Event) void {
            std.debug.print("[Telemetry] {s}\n", .{@tagName(event.event_type)});
        }
    }.handler);

    try state.runtime.onShutdown(struct {
        fn cleanup() void {
            std.debug.print("[Shutdown] Server cleanup complete\n", .{});
        }
    }.cleanup);

    // Create TCP server
    const address = try net.parseIp4(SERVER_ADDRESS, SERVER_PORT);
    std.debug.print("Starting Vigilant Server on {s}:{d}\n", .{ SERVER_ADDRESS, SERVER_PORT });

    const sock_flags = posix.SOCK.STREAM;
    const fd = try sockets.socket(posix.AF.INET, sock_flags, posix.IPPROTO.TCP);
    errdefer sockets.close(fd);

    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try sockets.bind(fd, &address.any, address.getOsSockLen());
    try sockets.listen(fd, 128);

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

        spawnConnectionHandler(conn.stream, &state) catch |err| {
            std.debug.print("Failed to spawn handler: {}\n", .{err});
            conn.stream.close();
            continue;
        };
    }

    // Graceful shutdown
    std.debug.print("\nInitiating graceful shutdown...\n", .{});
    state.is_shutting_down.store(true, .release);
    sockets.close(fd);

    // Wait for active connections
    while (state.metrics.active_connections.load(.monotonic) > 0) {
        std.debug.print("Waiting for {d} connections...\n", .{
            state.metrics.active_connections.load(.monotonic),
        });
        sleepFor(100 * std.time.ns_per_ms);
    }

    state.runtime.shutdown();

    std.debug.print("Server shutdown complete\n", .{});
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    installSignalHandlers();
    try runServer(allocator);
}

test "vigilant server state is wired to a v2 runtime" {
    const fields = std.meta.fields(ServerState);
    comptime {
        var found_runtime = false;
        for (fields) |field| {
            if (std.mem.eql(u8, field.name, "runtime")) {
                found_runtime = field.type == *vigil.Runtime;
            }
        }
        if (!found_runtime) {
            @compileError("ServerState must carry an owned v2 vigil.Runtime");
        }
    }
}

test "vigilant server example excludes removed root compatibility helpers" {
    comptime {
        const removed_root_helpers = .{
            "global_" ++ "registry",
            "create" ++ "Mailbox",
            "create" ++ "Supervisor",
            "create" ++ "SupervisionTree",
            "create" ++ "Response",
            "add" ++ "WorkerGroup",
            "broad" ++ "cast",
        };

        for (removed_root_helpers) |decl| {
            if (@hasDecl(vigil, decl)) {
                @compileError("example depends on a removed v2 root helper");
            }
        }
    }
}

test "vigilant server ignores SIGPIPE from disconnected clients" {
    var previous: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.PIPE, null, &previous);
    defer std.posix.sigaction(std.posix.SIG.PIPE, &previous, null);

    installSignalHandlers();

    var current: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.PIPE, null, &current);
    try std.testing.expect(current.handler.handler == std.posix.SIG.IGN);
}

test "vigilant server treats observability commands as control traffic" {
    try std.testing.expect(isControlCommand("STATUS"));
    try std.testing.expect(isControlCommand("HEALTH"));
    try std.testing.expect(isControlCommand("METRICS"));
    try std.testing.expect(!isControlCommand("hello"));
}

test "vigilant server health response uses runtime readiness" {
    const allocator = std.testing.allocator;

    var runtime = try vigil.runtime(allocator, .{});
    defer runtime.deinit();

    var state = try ServerState.init(allocator, &runtime);
    defer state.deinit();

    var buffer: [1024]u8 = undefined;
    const healthy = try formatHealthResponse(&buffer, &state);
    try std.testing.expect(std.mem.indexOf(u8, healthy, "runtime_status=healthy") != null);
    try std.testing.expect(std.mem.indexOf(u8, healthy, "runtime_ready=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, healthy, "registered=1") != null);

    state.circuit_breaker.forceOpen();
    const degraded = try formatHealthResponse(&buffer, &state);
    try std.testing.expect(std.mem.indexOf(u8, degraded, "runtime_status=degraded") != null);
    try std.testing.expect(std.mem.indexOf(u8, degraded, "runtime_ready=false") != null);
    try std.testing.expect(std.mem.indexOf(u8, degraded, "unhealthy_circuits=1") != null);
}

test "vigilant server status response includes runtime snapshot state" {
    const allocator = std.testing.allocator;

    var runtime = try vigil.runtime(allocator, .{});
    defer runtime.deinit();

    var state = try ServerState.init(allocator, &runtime);
    defer state.deinit();

    var buffer: [512]u8 = undefined;
    const status = try formatStatusResponse(&buffer, &state);

    try std.testing.expect(std.mem.indexOf(u8, status, "runtime_status=healthy") != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "registered=1") != null);
}
