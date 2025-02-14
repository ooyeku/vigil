const std = @import("std");
const vigil = @import("vigil");
const net = std.net;
const posix = std.posix;

// Add at the top with other constants
const MAX_CONNECTIONS = 1000;

// Server state to track connections and configuration
const ServerState = struct {
    port: u16,
    address: []const u8,
    connections: std.ArrayList(*Connection),
    allocator: std.mem.Allocator,
    // Add a mutex to protect concurrent access to connections list
    connections_mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, address: []const u8, port: u16) !ServerState {
        return ServerState{
            .port = port,
            .address = address,
            .connections = std.ArrayList(*Connection).init(allocator),
            .allocator = allocator,
            .connections_mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *ServerState) void {
        self.connections_mutex.lock();
        defer self.connections_mutex.unlock();

        for (self.connections.items) |conn| {
            conn.stream.close();
            self.allocator.destroy(conn);
        }
        self.connections.deinit();
    }
};

// Connection handler
const Connection = struct {
    stream: net.Stream,
    address: net.Address,
    state: *ServerState,
    buffer: [1024]u8 = undefined,

    pub fn handle(self: *Connection) !void {
        // Store these values before we potentially free self
        const addr = self.address;
        var state = self.state;

        defer {
            // Lock the mutex while removing from connections list
            state.connections_mutex.lock();
            defer state.connections_mutex.unlock();

            // First close the stream
            self.stream.close();

            // Then remove from connections list
            for (state.connections.items, 0..) |conn, i| {
                if (conn == self) {
                    _ = state.connections.orderedRemove(i);
                    // Destroy self after removing from list
                    state.allocator.destroy(self);
                    break;
                }
            }
            std.debug.print("🚪 Connection closed from {}\n", .{addr});
        }

        std.debug.print("👂 Waiting for data from {}\n", .{self.address});
        while (true) {
            const bytes_read = try self.stream.read(&self.buffer);
            if (bytes_read == 0) {
                std.debug.print("📭 Zero bytes read, closing connection\n", .{});
                return;
            }

            const cmd = std.mem.trim(u8, self.buffer[0..bytes_read], "\r\n");
            if (std.mem.eql(u8, cmd, "STATUS")) {
                // Lock mutex while reading connection count
                state.connections_mutex.lock();
                const count = state.connections.items.len;
                state.connections_mutex.unlock();

                const response = try std.fmt.bufPrint(&self.buffer, "OK {d}\n", .{count});
                _ = try self.stream.write(response[0..response.len]);
                std.debug.print("📤 Sent status response\n", .{});
            } else if (std.mem.eql(u8, cmd, "HEALTHCHECK")) {
                const response = "OK\n";
                _ = try self.stream.write(response);
                std.debug.print("🩺 Healthcheck responded\n", .{});
            } else {
                std.debug.print("📥 Received {} bytes: '{s}'\n", .{ bytes_read, cmd });
                _ = try self.stream.write(self.buffer[0..bytes_read]);
                std.debug.print("📤 Echoed {} bytes\n", .{bytes_read});
            }
        }
    }
};

// Network server using GenServer
pub fn NetworkServer(comptime Config: type) type {
    return struct {
        server: *vigil.GenServer(ServerState),
        config: Config,

        pub fn init(allocator: std.mem.Allocator, config: Config) !@This() {
            const state = try ServerState.init(allocator, config.address, config.port);

            const server = try vigil.GenServer(ServerState).init(
                allocator,
                handleMessage,
                startServer,
                stopServer,
                state,
            );

            return .{
                .server = server,
                .config = config,
            };
        }

        fn startServer(server: *vigil.GenServer(ServerState)) !void {
            const state = &server.state;

            // Create TCP server using correct 0.13.0 API
            const address = try net.Address.parseIp(state.address, state.port);
            std.debug.print("🚀 Starting server on {s}:{d}\n", .{ state.address, state.port });

            // Initialize socket with proper flags
            const sock_flags = posix.SOCK.STREAM | posix.SOCK.CLOEXEC;
            const fd = try posix.socket(posix.AF.INET, sock_flags, posix.IPPROTO.TCP);
            errdefer posix.close(fd);

            // Enable address reuse
            try posix.setsockopt(
                fd,
                posix.SOL.SOCKET,
                posix.SO.REUSEADDR,
                &std.mem.toBytes(@as(c_int, 1)),
            );

            // Bind the socket
            try posix.bind(fd, &address.any, address.getOsSockLen());
            std.debug.print("🔒 Socket bound successfully\n", .{});

            // Start listening
            try posix.listen(fd, 128);
            std.debug.print("👂 Listening for connections...\n", .{});

            // Create heap-allocated server that outlives this function
            const stream_server = try state.allocator.create(net.Server);
            stream_server.* = .{
                .stream = .{ .handle = fd },
                .listen_address = address,
            };
            errdefer state.allocator.destroy(stream_server);

            // Accept connections in a separate thread
            _ = try std.Thread.spawn(.{}, struct {
                fn accept(l: *net.Server, s: *ServerState) !void {
                    defer {
                        std.debug.print("🛑 Stopping server on {s}:{d}\n", .{ s.address, s.port });
                        s.allocator.destroy(l);
                    }

                    std.debug.print("✅ Server ready on {s}:{d}\n", .{ s.address, s.port });

                    while (true) {
                        const conn = try l.accept();
                        std.debug.print("🔌 New connection from {}\n", .{conn.address});

                        // Lock the mutex while checking and modifying connections
                        s.connections_mutex.lock();
                        defer s.connections_mutex.unlock();

                        // Check if we've hit the connection limit
                        if (s.connections.items.len >= MAX_CONNECTIONS) {
                            std.debug.print("⚠️ Connection limit reached, rejecting connection from {}\n", .{conn.address});
                            conn.stream.close();
                            continue;
                        }

                        const connection = try s.allocator.create(Connection);
                        connection.* = .{
                            .stream = conn.stream,
                            .address = conn.address,
                            .state = s,
                        };
                        try s.connections.append(connection);

                        _ = try std.Thread.spawn(.{}, struct {
                            fn handle(c: *Connection) !void {
                                try c.handle();
                            }
                        }.handle, .{connection});
                    }
                }
            }.accept, .{ stream_server, state });
        }

        fn stopServer(server: *vigil.GenServer(ServerState)) void {
            server.state.deinit();
        }

        fn handleMessage(server: *vigil.GenServer(ServerState), msg: vigil.Message) !void {
            if (msg.payload) |payload| {
                if (std.mem.eql(u8, payload, "status")) {
                    // Lock mutex while reading connection count
                    server.state.connections_mutex.lock();
                    const count = server.state.connections.items.len;
                    server.state.connections_mutex.unlock();

                    const status = try std.fmt.allocPrint(server.state.allocator, "Active connections: {d}", .{count});
                    defer server.state.allocator.free(status);

                    const response = try vigil.Message.init(
                        server.state.allocator,
                        "status_response",
                        msg.metadata.reply_to orelse "",
                        status,
                        .info,
                        .normal,
                        5000,
                    );
                    try server.cast(response);
                }
            }
        }
    };
}

const ServerConfig = struct {
    address: []const u8,
    port: u16,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = ServerConfig{
        .address = "127.0.0.1",
        .port = 8080,
    };

    const server = try NetworkServer(ServerConfig).init(allocator, config);
    try server.server.start();
    defer server.server.terminate_fn(server.server);

    std.debug.print("🏁 Server started at {s}:{d}\n", .{ config.address, config.port });
    std.debug.print("⏳ Press Ctrl+C to exit...\n", .{});

    // Keep main thread alive
    while (true) {
        std.time.sleep(std.time.ns_per_s);
    }
}
