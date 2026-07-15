//! Text protocol helpers for Vigil distributed registry nodes.
//!
//! Frames are ASCII lines prefixed with `VIGIL/2 `. Parsing is allocation-free:
//! returned slices point into the input line and are only valid while that line
//! remains alive.

const std = @import("std");

/// Errors returned while parsing distributed protocol frames.
pub const ProtocolError = error{ InvalidFrame, UnsupportedVersion };

/// Parsed distributed protocol command.
pub const Command = union(enum) {
    /// Node handshake carrying identity and listen port.
    hello: NodeIdentity,
    /// Heartbeat frame.
    heart,
    /// Lookup a process name.
    where: []const u8,
    /// Register a process name.
    reg: []const u8,
    /// Unregister a process name.
    unreg: []const u8,
};

/// Identity sent by a node during handshake.
pub const NodeIdentity = struct {
    /// Stable node id.
    node_id: []const u8,
    /// Node listen port.
    port: u16,
};

/// Required frame prefix for the v2 protocol.
pub const version_prefix = "VIGIL/2 ";

/// Parse a single protocol frame.
///
/// The returned command borrows slices from `line`. Keep the input buffer alive
/// for as long as the command is used.
pub fn parse(line: []const u8) ProtocolError!Command {
    if (!std.mem.startsWith(u8, line, version_prefix)) return error.UnsupportedVersion;
    const body = line[version_prefix.len..];

    if (std.mem.eql(u8, body, "HEART")) return .heart;
    if (std.mem.startsWith(u8, body, "WHERE ")) return .{ .where = try parseName(body["WHERE ".len..]) };
    if (std.mem.startsWith(u8, body, "REG ")) return .{ .reg = try parseName(body["REG ".len..]) };
    if (std.mem.startsWith(u8, body, "UNREG ")) return .{ .unreg = try parseName(body["UNREG ".len..]) };
    if (std.mem.startsWith(u8, body, "HELLO ")) {
        var parts = std.mem.splitScalar(u8, body["HELLO ".len..], ' ');
        const node_id = parts.next() orelse return error.InvalidFrame;
        const port_text = parts.next() orelse return error.InvalidFrame;
        if (!isValidName(node_id) or port_text.len == 0 or parts.next() != null) return error.InvalidFrame;
        const port = std.fmt.parseInt(u16, port_text, 10) catch return error.InvalidFrame;
        if (port == 0) return error.InvalidFrame;
        return .{ .hello = .{ .node_id = node_id, .port = port } };
    }
    return error.InvalidFrame;
}

fn parseName(name: []const u8) ProtocolError![]const u8 {
    if (!isValidName(name)) return error.InvalidFrame;
    return name;
}

/// Return whether a name is safe as one whitespace-delimited protocol token.
pub fn isValidName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        if (byte <= ' ' or byte == 0x7f) return false;
    }
    return true;
}

/// Write a v2 protocol frame into `buffer`.
///
/// The returned slice points into `buffer` and includes the trailing newline.
pub fn writeFrame(buffer: []u8, comptime fmt: []const u8, args: anytype) ![]const u8 {
    return try std.fmt.bufPrint(buffer, "VIGIL/2 " ++ fmt ++ "\n", args);
}

test "distributed protocol parses v2 frames" {
    try std.testing.expectEqual(Command.heart, try parse("VIGIL/2 HEART"));

    const where_cmd = try parse("VIGIL/2 WHERE service_a");
    try std.testing.expectEqualStrings("service_a", where_cmd.where);

    const unreg_cmd = try parse("VIGIL/2 UNREG service_a");
    try std.testing.expectEqualStrings("service_a", unreg_cmd.unreg);

    const hello_cmd = try parse("VIGIL/2 HELLO node_a 9100");
    try std.testing.expectEqualStrings("node_a", hello_cmd.hello.node_id);
    try std.testing.expectEqual(@as(u16, 9100), hello_cmd.hello.port);
}

test "distributed protocol writes v2 frames" {
    var buffer: [128]u8 = undefined;
    const frame = try writeFrame(&buffer, "WHERE {s}", .{"service_a"});
    try std.testing.expectEqualStrings("VIGIL/2 WHERE service_a\n", frame);
}

test "distributed protocol rejects invalid frames" {
    try std.testing.expectError(error.UnsupportedVersion, parse("HEART"));
    try std.testing.expectError(error.InvalidFrame, parse("VIGIL/2 UNKNOWN"));
    try std.testing.expectError(error.InvalidFrame, parse("VIGIL/2 WHERE "));
    try std.testing.expectError(error.InvalidFrame, parse("VIGIL/2 REG "));
    try std.testing.expectError(error.InvalidFrame, parse("VIGIL/2 UNREG "));
    try std.testing.expectError(error.InvalidFrame, parse("VIGIL/2 HELLO node_a nope"));
    try std.testing.expectError(error.InvalidFrame, parse("VIGIL/2 HELLO node_a 9100 extra"));
    try std.testing.expectError(error.InvalidFrame, parse("VIGIL/2 HELLO node_a 0"));
    try std.testing.expectError(error.InvalidFrame, parse("VIGIL/2 WHERE service name"));
    try std.testing.expectError(error.InvalidFrame, parse("VIGIL/2 REG service\tname"));
}

test "distributed protocol reports short write buffers" {
    var buffer: [8]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, writeFrame(&buffer, "WHERE {s}", .{"service_a"}));
}

test "distributed protocol fuzz: parse never crashes on arbitrary input" {
    var prng = std.Random.DefaultPrng.init(0x7657_11f2);
    const random = prng.random();

    var buffer: [96]u8 = undefined;
    for (0..2_000) |_| {
        const len = random.uintLessThan(usize, buffer.len);
        const line = buffer[0..len];
        random.bytes(line);

        // Bias some inputs toward the interesting prefix space.
        if (len >= version_prefix.len and random.boolean()) {
            @memcpy(line[0..version_prefix.len], version_prefix);
        }

        // Any input must either parse into a valid command or return a
        // protocol error; it must never crash.
        const command = parse(line) catch continue;
        switch (command) {
            .heart => {},
            .where, .reg, .unreg => |name| try std.testing.expect(isValidName(name)),
            .hello => |identity| {
                try std.testing.expect(isValidName(identity.node_id));
                try std.testing.expect(identity.port != 0);
            },
        }
    }
}

test "distributed protocol property: valid names round-trip through frames" {
    var prng = std.Random.DefaultPrng.init(0xdead_beef);
    const random = prng.random();

    const name_alphabet = "abcdefghijklmnopqrstuvwxyz0123456789_.-";
    var name_buffer: [48]u8 = undefined;
    var frame_buffer: [96]u8 = undefined;

    for (0..500) |_| {
        const name_len = 1 + random.uintLessThan(usize, name_buffer.len - 1);
        const name = name_buffer[0..name_len];
        for (name) |*byte| {
            byte.* = name_alphabet[random.uintLessThan(usize, name_alphabet.len)];
        }
        try std.testing.expect(isValidName(name));

        const where_frame = try writeFrame(&frame_buffer, "WHERE {s}", .{name});
        const parsed = try parse(std.mem.trimEnd(u8, where_frame, "\n"));
        try std.testing.expectEqualStrings(name, parsed.where);

        const port = 1 + random.uintLessThan(u16, std.math.maxInt(u16));
        const hello_frame = try writeFrame(&frame_buffer, "HELLO {s} {d}", .{ name, port });
        const hello = try parse(std.mem.trimEnd(u8, hello_frame, "\n"));
        try std.testing.expectEqualStrings(name, hello.hello.node_id);
        try std.testing.expectEqual(port, hello.hello.port);
    }
}
