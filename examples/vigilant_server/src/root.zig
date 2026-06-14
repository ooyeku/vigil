const std = @import("std");
const testing = std.testing;

test {
    std.testing.refAllDecls(@This());
}

pub const main = @import("main.zig");

test "vigilant server source uses owned v2 runtime APIs" {
    const source = @embedFile("main.zig");
    try testing.expect(std.mem.indexOf(u8, source, "vigil.telemetry." ++ "initGlobal") == null);
    try testing.expect(std.mem.indexOf(u8, source, "vigil.shutdown." ++ "initGlobal") == null);
    try testing.expect(std.mem.indexOf(u8, source, "vigil." ++ "onShutdown(") == null);
    try testing.expect(std.mem.indexOf(u8, source, "vigil." ++ "shutdownAll(") == null);
    try testing.expect(std.mem.indexOf(u8, source, "vigil.compat." ++ "timestamp(") == null);
    try testing.expect(std.mem.indexOf(u8, source, "vigil.compat." ++ "sleep(") == null);
}

test "vigilant server detaches handler threads" {
    const source = @embedFile("main.zig");
    try testing.expect(std.mem.indexOf(u8, source, "std.Thread.spawn") != null);
    try testing.expect(std.mem.indexOf(u8, source, ".detach()") != null);
}

test "vigilant server accounts connections before detached handler spawn" {
    const source = @embedFile("main.zig");
    const helper_at = std.mem.indexOf(u8, source, "fn spawnConnectionHandler") orelse return error.MissingSpawnHelper;
    const helper = source[helper_at..];

    const account_at = std.mem.indexOf(u8, helper, "state.metrics.connectionOpened();") orelse return error.MissingConnectionAccounting;
    const spawn_at = std.mem.indexOf(u8, helper, "std.Thread.spawn") orelse return error.MissingThreadSpawn;

    try testing.expect(account_at < spawn_at);
    try testing.expect(std.mem.indexOf(u8, helper, "errdefer state.metrics.connectionClosed();") != null);
}
