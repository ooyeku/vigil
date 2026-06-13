const std = @import("std");

pub const ProtocolError = error{ InvalidFrame, UnsupportedVersion };

pub const Command = union(enum) {
    hello: NodeIdentity,
    heart,
    where: []const u8,
    reg: []const u8,
    unreg: []const u8,
};

pub const NodeIdentity = struct {
    node_id: []const u8,
    port: u16,
};

pub const version_prefix = "VIGIL/2 ";

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
        if (node_id.len == 0 or port_text.len == 0) return error.InvalidFrame;
        const port = std.fmt.parseInt(u16, port_text, 10) catch return error.InvalidFrame;
        return .{ .hello = .{ .node_id = node_id, .port = port } };
    }
    return error.InvalidFrame;
}

fn parseName(name: []const u8) ProtocolError![]const u8 {
    if (name.len == 0) return error.InvalidFrame;
    return name;
}

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
}

test "distributed protocol reports short write buffers" {
    var buffer: [8]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, writeFrame(&buffer, "WHERE {s}", .{"service_a"}));
}
