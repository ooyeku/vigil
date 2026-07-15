const std = @import("std");
const vigil = @import("vigil");

const default_iterations: usize = 10_000;

pub const CountingAllocator = struct {
    child: std.mem.Allocator,
    allocations: std.atomic.Value(usize),
    frees: std.atomic.Value(usize),
    bytes_allocated: std.atomic.Value(usize),
    bytes_freed: std.atomic.Value(usize),

    pub fn init(child: std.mem.Allocator) CountingAllocator {
        return .{
            .child = child,
            .allocations = std.atomic.Value(usize).init(0),
            .frees = std.atomic.Value(usize).init(0),
            .bytes_allocated = std.atomic.Value(usize).init(0),
            .bytes_freed = std.atomic.Value(usize).init(0),
        };
    }

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    pub fn allocationCount(self: *const CountingAllocator) usize {
        return self.allocations.load(.monotonic);
    }

    pub fn freeCount(self: *const CountingAllocator) usize {
        return self.frees.load(.monotonic);
    }

    pub fn bytesAllocated(self: *const CountingAllocator) usize {
        return self.bytes_allocated.load(.monotonic);
    }

    pub fn bytesFreed(self: *const CountingAllocator) usize {
        return self.bytes_freed.load(.monotonic);
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn fromContext(ctx: *anyopaque) *CountingAllocator {
        return @ptrCast(@alignCast(ctx));
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self = fromContext(ctx);
        const ptr = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        _ = self.allocations.fetchAdd(1, .monotonic);
        _ = self.bytes_allocated.fetchAdd(len, .monotonic);
        return ptr;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self = fromContext(ctx);
        if (!self.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        if (new_len > memory.len) {
            _ = self.bytes_allocated.fetchAdd(new_len - memory.len, .monotonic);
        } else {
            _ = self.bytes_freed.fetchAdd(memory.len - new_len, .monotonic);
        }
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self = fromContext(ctx);
        const ptr = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        if (new_len > memory.len) {
            _ = self.bytes_allocated.fetchAdd(new_len - memory.len, .monotonic);
        } else {
            _ = self.bytes_freed.fetchAdd(memory.len - new_len, .monotonic);
        }
        return ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self = fromContext(ctx);
        _ = self.frees.fetchAdd(1, .monotonic);
        _ = self.bytes_freed.fetchAdd(memory.len, .monotonic);
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

pub const BenchmarkResult = struct {
    name: []const u8,
    operations: usize,
    elapsed_ns: u64,
    allocations: usize = 0,
    frees: usize = 0,
    bytes_allocated: usize = 0,
    bytes_freed: usize = 0,

    pub fn opsPerSecond(self: BenchmarkResult) f64 {
        return throughputPerSecond(self.operations, self.elapsed_ns);
    }

    pub fn averageLatencyNs(self: BenchmarkResult) u64 {
        if (self.operations == 0) return 0;
        return self.elapsed_ns / self.operations;
    }

    pub fn allocationsPerOperation(self: BenchmarkResult) f64 {
        if (self.operations == 0) return 0;
        return @as(f64, @floatFromInt(self.allocations)) / @as(f64, @floatFromInt(self.operations));
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
    std.debug.print("{s:<28} ops={d:<10} elapsed={d:>8}us avg={d:>6}ns throughput={d}/s allocs/op={d:.3}\n", .{
        result.name,
        result.operations,
        result.elapsed_ns / std.time.ns_per_us,
        result.averageLatencyNs(),
        ops_per_second,
        result.allocationsPerOperation(),
    });
}

const BenchmarkFn = *const fn (std.mem.Allocator, usize) anyerror!BenchmarkResult;

fn runBenchmark(bench_fn: BenchmarkFn, iterations: usize) !BenchmarkResult {
    var counter = CountingAllocator.init(std.heap.smp_allocator);
    var result = try bench_fn(counter.allocator(), iterations);
    result.allocations = counter.allocationCount();
    result.frees = counter.freeCount();
    result.bytes_allocated = counter.bytesAllocated();
    result.bytes_freed = counter.bytesFreed();
    return result;
}

pub fn benchInbox(allocator: std.mem.Allocator, iterations: usize) !BenchmarkResult {
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

pub fn benchRegistryLookup(allocator: std.mem.Allocator, iterations: usize) !BenchmarkResult {
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

pub fn benchRegistryRegister(allocator: std.mem.Allocator, iterations: usize) !BenchmarkResult {
    var registry = vigil.Registry.init(allocator);
    defer registry.deinit();

    var mailbox = vigil.ProcessMailbox.init(allocator, .{ .capacity = 1 });
    defer mailbox.deinit();

    const start = nowNs();
    for (0..iterations) |i| {
        var name_buffer: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "bench.worker.{d}", .{i});
        try registry.register(name, &mailbox);
    }

    return .{
        .name = "registry register",
        .operations = iterations,
        .elapsed_ns = elapsedSince(start),
    };
}

fn noopTelemetry(_: vigil.telemetry.Event) void {}

fn noopTimerCallback() void {}

pub fn benchTelemetry(allocator: std.mem.Allocator, iterations: usize) !BenchmarkResult {
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

const RegistryLookupContext = struct {
    registry: *vigil.Registry,
    iterations: usize,
    name_index_offset: usize,
};

fn registryLookupThread(ctx: *RegistryLookupContext) void {
    var name_buffer: [32]u8 = undefined;
    for (0..ctx.iterations) |i| {
        const name = std.fmt.bufPrint(&name_buffer, "svc-{d}", .{(i + ctx.name_index_offset) % 64}) catch return;
        _ = ctx.registry.whereis(name);
    }
}

pub fn benchRegistryContention(allocator: std.mem.Allocator, iterations: usize) !BenchmarkResult {
    var registry = vigil.Registry.init(allocator);
    defer registry.deinit();

    var mailbox = vigil.ProcessMailbox.init(allocator, .{ .capacity = 1 });
    defer mailbox.deinit();

    var name_buffer: [32]u8 = undefined;
    for (0..64) |i| {
        const name = try std.fmt.bufPrint(&name_buffer, "svc-{d}", .{i});
        try registry.register(name, &mailbox);
    }

    const thread_count = 8;
    var contexts: [thread_count]RegistryLookupContext = undefined;
    for (&contexts, 0..) |*ctx, i| {
        ctx.* = .{
            .registry = &registry,
            .iterations = iterations,
            .name_index_offset = i * 8,
        };
    }

    const start = nowNs();
    var threads: [thread_count]std.Thread = undefined;
    for (&threads, &contexts) |*thread, *ctx| {
        thread.* = try std.Thread.spawn(.{}, registryLookupThread, .{ctx});
    }
    for (threads) |thread| thread.join();

    return .{
        .name = "registry contention",
        .operations = iterations * thread_count,
        .elapsed_ns = elapsedSince(start),
    };
}

pub fn benchTimerScheduling(allocator: std.mem.Allocator, iterations: usize) !BenchmarkResult {
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

pub fn benchTimerService(allocator: std.mem.Allocator, iterations: usize) !BenchmarkResult {
    var service = vigil.TimerService.init(allocator);
    defer service.deinit();
    try service.start();

    const start = nowNs();
    for (0..iterations) |_| {
        _ = try service.setTimeout(0, noopTimerCallback);
    }
    while (service.pendingCount() != 0) {
        std.Thread.yield() catch {};
    }

    return .{
        .name = "timer service schedule",
        .operations = iterations,
        .elapsed_ns = elapsedSince(start),
    };
}

pub fn benchProcessGroupRoute(allocator: std.mem.Allocator, iterations: usize) !BenchmarkResult {
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

pub fn benchProcessGroupBroadcast(allocator: std.mem.Allocator, iterations: usize) !BenchmarkResult {
    const member_count = 4;
    var group = try vigil.ProcessGroup.init(allocator, "bench.broadcast");
    defer group.deinit();

    var inboxes: [member_count]*vigil.Inbox = undefined;
    for (&inboxes, 0..) |*slot, i| {
        slot.* = try vigil.inboxBuilder(allocator)
            .capacity(iterations + 1)
            .build();
        const name = try std.fmt.allocPrint(allocator, "broadcast-worker-{d}", .{i});
        defer allocator.free(name);
        try group.add(name, slot.*);
    }
    defer for (inboxes) |inbox| {
        inbox.close();
    };

    var delivered: usize = 0;
    const start = nowNs();
    for (0..iterations) |_| {
        const result = try group.broadcast("payload");
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
        .name = "process group broadcast",
        .operations = delivered,
        .elapsed_ns = elapsed,
    };
}

pub fn benchPubSub(allocator: std.mem.Allocator, iterations: usize) !BenchmarkResult {
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

pub fn benchReplyCorrelation(allocator: std.mem.Allocator, iterations: usize) !BenchmarkResult {
    var inbox = try vigil.inboxBuilder(allocator)
        .capacity(iterations + 1)
        .build();
    defer inbox.close();

    var reply_mailbox = vigil.ReplyMailbox.init(allocator, inbox);
    defer reply_mailbox.deinit();

    const start = nowNs();
    for (0..iterations) |_| {
        var request_msg = try vigil.Message.init(allocator, "bench-request", "client", "request", null, .normal, null);
        defer request_msg.deinit();
        try request_msg.setCorrelationId("bench-correlation");

        const response = try vigil.reply(request_msg, "response", allocator);
        try inbox.mailbox.send(response);

        var received = try reply_mailbox.waitForReply("bench-correlation", 1000);
        received.deinit();
    }

    return .{
        .name = "request/reply correlate",
        .operations = iterations,
        .elapsed_ns = elapsedSince(start),
    };
}

const ProducerContext = struct {
    inbox: *vigil.Inbox,
    messages: usize,
};

const ConsumerContext = struct {
    inbox: *vigil.Inbox,
    target: usize,
    consumed: *std.atomic.Value(usize),
};

fn producerThread(ctx: *ProducerContext) void {
    for (0..ctx.messages) |_| {
        ctx.inbox.send("payload") catch return;
    }
}

fn consumerThread(ctx: *ConsumerContext) void {
    while (true) {
        const index = ctx.consumed.fetchAdd(1, .acq_rel);
        if (index >= ctx.target) return;

        var msg = ctx.inbox.recv() catch return;
        msg.deinit();
    }
}

pub fn benchInboxContention(allocator: std.mem.Allocator, iterations: usize) !BenchmarkResult {
    var inbox = try vigil.inboxBuilder(allocator)
        .capacity(iterations + 4)
        .build();
    defer inbox.close();

    const producer_count = 2;
    const consumer_count = 2;
    const first_producer_messages = iterations / 2;
    const second_producer_messages = iterations - first_producer_messages;

    var producers = [_]ProducerContext{
        .{ .inbox = inbox, .messages = first_producer_messages },
        .{ .inbox = inbox, .messages = second_producer_messages },
    };
    var consumed = std.atomic.Value(usize).init(0);
    var consumers = [_]ConsumerContext{
        .{ .inbox = inbox, .target = iterations, .consumed = &consumed },
        .{ .inbox = inbox, .target = iterations, .consumed = &consumed },
    };

    const start = nowNs();
    var producer_threads: [producer_count]std.Thread = undefined;
    var consumer_threads: [consumer_count]std.Thread = undefined;

    for (&consumer_threads, &consumers) |*thread, *ctx| {
        thread.* = try std.Thread.spawn(.{}, consumerThread, .{ctx});
    }
    for (&producer_threads, &producers) |*thread, *ctx| {
        thread.* = try std.Thread.spawn(.{}, producerThread, .{ctx});
    }
    for (producer_threads) |thread| thread.join();
    for (consumer_threads) |thread| thread.join();

    return .{
        .name = "inbox contention",
        .operations = iterations * 2,
        .elapsed_ns = elapsedSince(start),
    };
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const iterations = try parseIterations(args);

    std.debug.print("Vigil benchmark harness\n", .{});
    std.debug.print("iterations={d}\n\n", .{iterations});

    printResult(try runBenchmark(benchInbox, iterations));
    printResult(try runBenchmark(benchRegistryLookup, iterations));
    printResult(try runBenchmark(benchRegistryRegister, iterations));
    printResult(try runBenchmark(benchRegistryContention, iterations));
    printResult(try runBenchmark(benchTelemetry, iterations));
    printResult(try runBenchmark(benchTimerScheduling, iterations));
    printResult(try runBenchmark(benchTimerService, iterations));
    printResult(try runBenchmark(benchProcessGroupRoute, iterations));
    printResult(try runBenchmark(benchProcessGroupBroadcast, iterations));
    printResult(try runBenchmark(benchPubSub, iterations));
    printResult(try runBenchmark(benchReplyCorrelation, iterations));
    printResult(try runBenchmark(benchInboxContention, iterations));
}
