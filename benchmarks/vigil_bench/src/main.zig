const std = @import("std");
const vigil = @import("vigil");

const default_iterations: usize = 10_000;

pub const BenchmarkResult = struct {
    name: []const u8,
    operations: usize,
    elapsed_ns: u64,

    pub fn opsPerSecond(self: BenchmarkResult) f64 {
        return throughputPerSecond(self.operations, self.elapsed_ns);
    }
};

pub fn throughputPerSecond(operations: usize, elapsed_ns: u64) f64 {
    if (elapsed_ns == 0) return 0;
    const ops = @as(f64, @floatFromInt(operations));
    const seconds = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));
    return ops / seconds;
}

fn nowNs() u64 {
    return @intCast(vigil.compat.nanoTimestamp());
}

fn elapsedSince(start_ns: u64) u64 {
    const end_ns = nowNs();
    if (end_ns <= start_ns) return 1;
    return end_ns - start_ns;
}

fn parseIterations(args: []const [:0]const u8) !usize {
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--iterations") and i + 1 < args.len) {
            return std.fmt.parseInt(usize, args[i + 1], 10);
        }
        if (std.mem.startsWith(u8, args[i], "--iterations=")) {
            return std.fmt.parseInt(usize, args[i]["--iterations=".len..], 10);
        }
    }

    return default_iterations;
}

fn printResult(result: BenchmarkResult) void {
    const ops_per_second: u64 = @intFromFloat(result.opsPerSecond());
    std.debug.print("{s:<24} ops={d:<10} elapsed={d:>8}us throughput={d}/s\n", .{
        result.name,
        result.operations,
        result.elapsed_ns / std.time.ns_per_us,
        ops_per_second,
    });
}

fn benchInbox(allocator: std.mem.Allocator, iterations: usize) !BenchmarkResult {
    var inbox = try vigil.inboxBuilder(allocator)
        .capacity(iterations + 1)
        .build();
    defer inbox.close();

    const start = nowNs();
    for (0..iterations) |_| {
        try inbox.send("payload");
    }
    for (0..iterations) |_| {
        var msg = try inbox.recv();
        defer msg.deinit();
    }

    return .{
        .name = "inbox send+recv",
        .operations = iterations * 2,
        .elapsed_ns = elapsedSince(start),
    };
}

fn benchRegistry(allocator: std.mem.Allocator, iterations: usize) !BenchmarkResult {
    var registry = vigil.Registry.init(allocator);
    defer registry.deinit();

    var mailbox = vigil.ProcessMailbox.init(allocator, .{ .capacity = 1 });
    defer mailbox.deinit();

    try registry.register("bench.worker", &mailbox);

    const start = nowNs();
    for (0..iterations) |_| {
        if (registry.whereis("bench.worker") == null) return error.RegistryMiss;
    }

    return .{
        .name = "registry lookup",
        .operations = iterations,
        .elapsed_ns = elapsedSince(start),
    };
}

fn noopTelemetry(_: vigil.telemetry.Event) void {}

fn noopTimerCallback() void {}

fn benchTelemetry(allocator: std.mem.Allocator, iterations: usize) !BenchmarkResult {
    var emitter = vigil.telemetry.TelemetryEmitter.init(allocator);
    defer emitter.deinit();
    try emitter.on(.message_sent, noopTelemetry);

    const start = nowNs();
    for (0..iterations) |_| {
        emitter.emit(.{
            .event_type = .message_sent,
            .timestamp_ms = 0,
            .metadata = "bench",
        });
    }

    return .{
        .name = "telemetry emit",
        .operations = iterations,
        .elapsed_ns = elapsedSince(start),
    };
}

fn benchTimerScheduling(allocator: std.mem.Allocator, iterations: usize) !BenchmarkResult {
    const start = nowNs();
    for (0..iterations) |_| {
        var timer = vigil.Timer.init(allocator);
        try timer.setTimeout(0, noopTimerCallback);
        timer.deinit();
    }

    return .{
        .name = "timer schedule+join",
        .operations = iterations,
        .elapsed_ns = elapsedSince(start),
    };
}

fn benchProcessGroup(allocator: std.mem.Allocator, iterations: usize) !BenchmarkResult {
    const member_count = 4;
    var group = try vigil.ProcessGroup.init(allocator, "bench.group");
    defer group.deinit();

    var inboxes: [member_count]*vigil.Inbox = undefined;
    for (&inboxes, 0..) |*slot, i| {
        slot.* = try vigil.inboxBuilder(allocator)
            .capacity(iterations + 1)
            .build();
        const name = try std.fmt.allocPrint(allocator, "worker-{d}", .{i});
        defer allocator.free(name);
        try group.add(name, slot.*);
    }
    defer for (inboxes) |inbox| {
        inbox.close();
    };

    const start = nowNs();
    for (0..iterations) |_| {
        try group.roundRobin("payload");
    }
    const elapsed = elapsedSince(start);

    for (inboxes) |inbox| {
        while (try inbox.recvTimeout(0)) |msg| {
            var owned = msg;
            owned.deinit();
        }
    }

    return .{
        .name = "process group route",
        .operations = iterations,
        .elapsed_ns = elapsed,
    };
}

fn benchPubSub(allocator: std.mem.Allocator, iterations: usize) !BenchmarkResult {
    const subscriber_count = 4;
    var broker = vigil.pubsub.PubSubBroker.init(allocator);
    defer broker.deinit();

    var inboxes: [subscriber_count]*vigil.Inbox = undefined;
    var subscribers: [subscriber_count]vigil.Subscriber = undefined;

    for (&inboxes, &subscribers) |*inbox_slot, *subscriber_slot| {
        inbox_slot.* = try vigil.inboxBuilder(allocator)
            .capacity(iterations + 1)
            .build();
        subscriber_slot.* = vigil.Subscriber.init(allocator, inbox_slot.*);
        try subscriber_slot.subscribe(&[_][]const u8{"bench.#"});
        try broker.subscribe(subscriber_slot);
    }
    defer for (&subscribers) |*subscriber| {
        subscriber.deinit();
    };
    defer for (inboxes) |inbox| {
        inbox.close();
    };

    var delivered: usize = 0;
    const start = nowNs();
    for (0..iterations) |_| {
        const result = try broker.publish("bench.event", "payload");
        delivered += result.delivered;
    }
    const elapsed = elapsedSince(start);

    for (inboxes) |inbox| {
        while (try inbox.recvTimeout(0)) |msg| {
            var owned = msg;
            owned.deinit();
        }
    }

    return .{
        .name = "pubsub fanout",
        .operations = delivered,
        .elapsed_ns = elapsed,
    };
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const iterations = try parseIterations(args);

    std.debug.print("Vigil benchmark harness\n", .{});
    std.debug.print("iterations={d}\n\n", .{iterations});

    printResult(try benchInbox(allocator, iterations));
    printResult(try benchRegistry(allocator, iterations));
    printResult(try benchTelemetry(allocator, iterations));
    printResult(try benchTimerScheduling(allocator, iterations));
    printResult(try benchProcessGroup(allocator, iterations));
    printResult(try benchPubSub(allocator, iterations));
}
