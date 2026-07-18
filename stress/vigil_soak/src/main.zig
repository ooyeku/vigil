//! Soak and chaos harness for Vigil.
//!
//! Runs high-concurrency churn scenarios for a configurable wall-clock
//! duration, checking invariants as it goes. Unlike the unit suite this is
//! meant to run for minutes to hours; unlike the benchmarks it cares about
//! survival, not speed.
//!
//!   zig build run -Doptimize=ReleaseSafe -- --seconds 60
//!
//! Scenarios:
//! - inbox churn: producers, consumers, and repeated create/close cycles
//! - supervisor churn: children crashing and restarting continuously
//! - fanout churn: pub/sub and process-group delivery under contention
//! - timer churn: schedule/cancel storms against one TimerService
//! - registry churn: concurrent register/lookup/unregister across shards
//!
//! Exit code 0 means every invariant held for the whole run.

const std = @import("std");
const vigil = @import("vigil");

var failures = std.atomic.Value(u32).init(0);

fn fail(comptime what: []const u8) void {
    _ = failures.fetchAdd(1, .monotonic);
    std.debug.print("INVARIANT FAILED: {s}\n", .{what});
}

const Deadline = struct {
    end_ms: i64,

    fn init(seconds: u64) Deadline {
        return .{ .end_ms = vigil.compat.monotonicMilliTimestamp() +| @as(i64, @intCast(seconds * 1000)) };
    }

    fn expired(self: Deadline) bool {
        return vigil.compat.monotonicMilliTimestamp() >= self.end_ms;
    }
};

// --- inbox churn -----------------------------------------------------------

const InboxChurn = struct {
    inbox: *vigil.Inbox,
    deadline: Deadline,
    produced: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    consumed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    fn producer(self: *InboxChurn) void {
        while (!self.deadline.expired()) {
            self.inbox.send("soak-payload") catch |err| switch (err) {
                error.MailboxFull, error.DeadLetterFull => continue,
                error.InboxClosed => return,
                else => {
                    fail("inbox producer unexpected error");
                    return;
                },
            };
            _ = self.produced.fetchAdd(1, .monotonic);
        }
    }

    fn consumer(self: *InboxChurn) void {
        while (true) {
            const msg = self.inbox.recvTimeout(20) catch return orelse {
                if (self.deadline.expired()) return;
                continue;
            };
            msg.deinit();
            _ = self.consumed.fetchAdd(1, .monotonic);
        }
    }
};

fn runInboxChurn(allocator: std.mem.Allocator, seconds: u64) !void {
    var rt = try vigil.runtime(allocator, .{});
    defer rt.deinit();

    const deadline = Deadline.init(seconds);
    var cycle: u64 = 0;
    var total_produced: u64 = 0;
    var total_consumed: u64 = 0;

    // Repeated create/use/close cycles catch shutdown races and leaks.
    while (!deadline.expired()) : (cycle += 1) {
        var churn = InboxChurn{
            .inbox = try rt.inbox(.{ .capacity = 256, .dead_letter = false, .default_ttl_ms = null }),
            .deadline = Deadline.init(1),
        };

        var threads: [6]std.Thread = undefined;
        for (threads[0..3]) |*t| t.* = try std.Thread.spawn(.{}, InboxChurn.producer, .{&churn});
        for (threads[3..6]) |*t| t.* = try std.Thread.spawn(.{}, InboxChurn.consumer, .{&churn});
        for (threads) |t| t.join();

        // Drain what the consumers left behind, then close.
        var buffer: [64]vigil.Message = undefined;
        while (true) {
            const got = churn.inbox.recvBatch(&buffer) catch break;
            if (got == 0) break;
            for (buffer[0..got]) |m| m.deinit();
            _ = churn.consumed.fetchAdd(got, .monotonic);
        }

        const produced = churn.produced.load(.monotonic);
        const consumed = churn.consumed.load(.monotonic);
        if (consumed > produced) fail("inbox consumed more than produced");
        total_produced += produced;
        total_consumed += consumed;
        churn.inbox.close();
    }

    std.debug.print("inbox churn: {d} cycles, {d} produced, {d} consumed\n", .{ cycle, total_produced, total_consumed });
}

// --- supervisor churn ------------------------------------------------------

var crashy_iterations = std.atomic.Value(u64).init(0);

fn crashyWorker() void {
    _ = crashy_iterations.fetchAdd(1, .monotonic);
    vigil.compat.sleep(2 * std.time.ns_per_ms);
}

fn runSupervisorChurn(allocator: std.mem.Allocator, seconds: u64) !void {
    const deadline = Deadline.init(seconds);
    var restarts_seen: u64 = 0;
    var cycles: u64 = 0;

    while (!deadline.expired()) : (cycles += 1) {
        var sup = vigil.Supervisor.init(allocator, .{
            .strategy = .one_for_one,
            .max_restarts = 1_000_000,
            .max_seconds = 3600,
        });

        try sup.addChild(.{
            .id = "crashy",
            .start_fn = crashyWorker,
            .restart_type = .permanent,
            .shutdown_timeout_ms = 200,
        });
        try sup.start();
        try sup.startMonitoring();

        // Fault injection: force the child into the failed state repeatedly
        // so the restart machinery runs under churn.
        for (0..3) |_| {
            if (sup.findChild("crashy")) |child| {
                child.mutex.lock();
                child.state = .failed;
                child.mutex.unlock();
            }
            vigil.compat.sleep(150 * std.time.ns_per_ms);
        }

        var snap = try sup.snapshot(allocator);
        restarts_seen += snap.total_restarts;
        if (snap.child_count != 1) fail("supervisor lost a child");
        if (snap.total_restarts == 0) fail("supervisor performed no restarts under fault injection");
        snap.deinit();

        sup.stopMonitoring();
        sup.deinit();
    }

    std.debug.print("supervisor churn: {d} cycles, {d} restarts observed\n", .{ cycles, restarts_seen });
}

// --- fanout churn ----------------------------------------------------------

fn runFanoutChurn(allocator: std.mem.Allocator, seconds: u64) !void {
    const subscriber_count = 8;
    var rt = try vigil.runtime(allocator, .{});
    defer rt.deinit();

    var broker = vigil.PubSubBroker.init(allocator);
    defer broker.deinit();
    broker.setTelemetryEmitter(&rt.telemetry_emitter);

    var inboxes: [subscriber_count]*vigil.Inbox = undefined;
    var subscribers: [subscriber_count]vigil.Subscriber = undefined;
    for (&inboxes, &subscribers) |*slot, *sub| {
        slot.* = try rt.inbox(.{ .capacity = 4096, .default_ttl_ms = null });
        sub.* = vigil.Subscriber.init(allocator, slot.*);
        try sub.subscribe(&.{"soak.#"});
        try broker.subscribe(sub);
    }
    defer for (&subscribers) |*sub| sub.deinit();
    defer for (inboxes) |ib| ib.close();

    const Publisher = struct {
        broker: *vigil.PubSubBroker,
        deadline: Deadline,
        published: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

        fn run(self: *@This()) void {
            while (!self.deadline.expired()) {
                _ = self.broker.publish("soak.event", "payload") catch {
                    fail("publish failed");
                    return;
                };
                _ = self.published.fetchAdd(1, .monotonic);
            }
        }
    };
    const Drainer = struct {
        inbox: *vigil.Inbox,
        deadline: Deadline,

        fn run(self: *@This()) void {
            var buffer: [64]vigil.Message = undefined;
            while (!self.deadline.expired()) {
                const got = self.inbox.recvBatch(&buffer) catch return;
                if (got == 0) {
                    vigil.compat.sleep(1 * std.time.ns_per_ms);
                    continue;
                }
                for (buffer[0..got]) |m| m.deinit();
            }
        }
    };

    const deadline = Deadline.init(seconds);
    var publishers: [2]Publisher = .{
        .{ .broker = &broker, .deadline = deadline },
        .{ .broker = &broker, .deadline = deadline },
    };
    var drainers: [subscriber_count]Drainer = undefined;
    for (&drainers, inboxes) |*d, ib| d.* = .{ .inbox = ib, .deadline = deadline };

    var threads: [2 + subscriber_count]std.Thread = undefined;
    threads[0] = try std.Thread.spawn(.{}, Publisher.run, .{&publishers[0]});
    threads[1] = try std.Thread.spawn(.{}, Publisher.run, .{&publishers[1]});
    for (threads[2..], &drainers) |*t, *d| t.* = try std.Thread.spawn(.{}, Drainer.run, .{d});
    for (threads) |t| t.join();

    var snap = try broker.snapshot(allocator);
    defer snap.deinit();
    const published = publishers[0].published.load(.monotonic) + publishers[1].published.load(.monotonic);
    if (snap.total_delivered + snap.total_failed < published) fail("fanout lost deliveries");
    std.debug.print("fanout churn: {d} published, {d} delivered, {d} failed\n", .{
        published,
        snap.total_delivered,
        snap.total_failed,
    });
}

// --- timer churn -----------------------------------------------------------

var timer_fires = std.atomic.Value(u64).init(0);

fn timerTick() void {
    _ = timer_fires.fetchAdd(1, .monotonic);
}

fn runTimerChurn(allocator: std.mem.Allocator, seconds: u64) !void {
    var rt = try vigil.runtime(allocator, .{});
    defer rt.deinit();
    const service = try rt.timers();

    const deadline = Deadline.init(seconds);
    var scheduled: u64 = 0;
    var cancelled: u64 = 0;
    var prng = std.Random.DefaultPrng.init(0x50a4);
    const random = prng.random();

    while (!deadline.expired()) {
        const id = try service.setTimeout(random.intRangeAtMost(u32, 1, 20), timerTick);
        scheduled += 1;
        if (random.boolean()) {
            if (service.cancel(id)) cancelled += 1;
        }
        if (scheduled % 64 == 0) vigil.compat.sleep(1 * std.time.ns_per_ms);
    }
    // Let stragglers fire.
    vigil.compat.sleep(50 * std.time.ns_per_ms);

    const fired = timer_fires.load(.monotonic);
    if (fired + cancelled > scheduled) fail("timers fired more than scheduled");
    std.debug.print("timer churn: {d} scheduled, {d} cancelled, {d} fired\n", .{ scheduled, cancelled, fired });
}

// --- registry churn --------------------------------------------------------

fn runRegistryChurn(allocator: std.mem.Allocator, seconds: u64) !void {
    var registry = vigil.Registry.init(allocator);
    defer registry.deinit();
    var mailbox = vigil.ProcessMailbox.init(allocator, .{ .capacity = 1 });
    defer mailbox.deinit();

    const Worker = struct {
        registry: *vigil.Registry,
        mailbox: *vigil.ProcessMailbox,
        deadline: Deadline,
        seed: u64,

        fn run(self: *@This()) void {
            var prng = std.Random.DefaultPrng.init(self.seed);
            const random = prng.random();
            var name_buf: [32]u8 = undefined;
            while (!self.deadline.expired()) {
                const name = std.fmt.bufPrint(&name_buf, "soak.{d}", .{random.intRangeAtMost(u32, 0, 511)}) catch return;
                switch (random.intRangeAtMost(u8, 0, 2)) {
                    0 => self.registry.register(name, self.mailbox) catch {},
                    1 => _ = self.registry.whereis(name),
                    else => self.registry.unregister(name),
                }
            }
        }
    };

    const deadline = Deadline.init(seconds);
    var workers: [8]Worker = undefined;
    var threads: [8]std.Thread = undefined;
    for (&workers, &threads, 0..) |*w, *t, i| {
        w.* = .{ .registry = &registry, .mailbox = &mailbox, .deadline = deadline, .seed = i + 1 };
        t.* = try std.Thread.spawn(.{}, Worker.run, .{w});
    }
    for (threads) |t| t.join();

    if (registry.count() > 512) fail("registry grew beyond the name space");
    std.debug.print("registry churn: final count {d}\n", .{registry.count()});
}

// --- distributed chaos ------------------------------------------------------

fn runDistributedChaos(allocator: std.mem.Allocator, seconds: u64) !void {
    var node_a = try vigil.DistributedRegistry.init(allocator, .{
        .cluster_nodes = &.{},
        .listen_port = 39431,
        .sync_interval_ms = 10,
    });
    defer node_a.deinit();
    var mailbox = vigil.ProcessMailbox.init(allocator, .{ .capacity = 1 });
    defer mailbox.deinit();
    try node_a.register("chaos_service", &mailbox, .global);

    var node_b = try vigil.DistributedRegistry.init(allocator, .{
        .cluster_nodes = &.{"127.0.0.1:39431"},
        .listen_port = 39432,
        .sync_interval_ms = 10,
    });
    defer node_b.deinit();

    const deadline = Deadline.init(seconds);
    var cycles: u64 = 0;
    var heals: u64 = 0;

    // Repeated partition/heal cycles: resolution must succeed while the
    // listener is up and fail closed while it is down.
    while (!deadline.expired()) : (cycles += 1) {
        try node_a.startSync();
        var resolved: ?vigil.RemoteProcessInfo = null;
        var waited_ms: u32 = 0;
        while (resolved == null and waited_ms < 3_000) : (waited_ms += 20) {
            vigil.compat.sleep(20 * std.time.ns_per_ms);
            resolved = node_b.queryPeers("chaos_service");
        }
        if (resolved == null) {
            fail("distributed resolution never healed");
            node_a.stopSync();
            break;
        }
        heals += 1;

        node_a.stopSync();
        var lost = node_b.queryPeers("chaos_service");
        var retries: u32 = 0;
        while (lost != null and retries < 50) : (retries += 1) {
            vigil.compat.sleep(10 * std.time.ns_per_ms);
            lost = node_b.queryPeers("chaos_service");
        }
        if (lost != null) fail("distributed resolution survived a partition");
    }

    var state = try node_b.snapshot(allocator);
    defer state.deinit();
    std.debug.print("distributed chaos: {d} cycles, {d} heals, {d} reconnects, {d} queries\n", .{
        cycles,
        heals,
        state.peers[0].reconnects,
        state.peer_queries,
    });
}

// --- main ------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        if (gpa.deinit() == .leak) {
            std.debug.print("INVARIANT FAILED: memory leaked\n", .{});
            std.process.exit(1);
        }
    }
    const allocator = gpa.allocator();

    var seconds: u64 = 30;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--seconds") and i + 1 < args.len) {
            seconds = try std.fmt.parseInt(u64, args[i + 1], 10);
            i += 1;
        }
    }

    const per_scenario = @max(seconds / 6, 1);
    std.debug.print("vigil soak: {d}s total, {d}s per scenario\n\n", .{ seconds, per_scenario });

    try runInboxChurn(allocator, per_scenario);
    try runSupervisorChurn(allocator, per_scenario);
    try runFanoutChurn(allocator, per_scenario);
    try runTimerChurn(allocator, per_scenario);
    try runRegistryChurn(allocator, per_scenario);
    try runDistributedChaos(allocator, per_scenario);

    const failed = failures.load(.monotonic);
    if (failed > 0) {
        std.debug.print("\nsoak FAILED: {d} invariant violations\n", .{failed});
        std.process.exit(1);
    }
    std.debug.print("\nsoak passed: all invariants held\n", .{});
}
