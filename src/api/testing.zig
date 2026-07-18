//! Testing utilities for Vigil.
//!
//! Provides mocking, assertions, deterministic time and timers, fault
//! injection, and failure-mode simulation for testing Vigil applications.

const std = @import("std");
const Message = @import("../messages.zig").Message;
const MessagePriority = @import("../messages.zig").MessagePriority;
const Signal = @import("../messages.zig").Signal;
const MessageError = @import("../messages.zig").MessageError;
const ProcessMailbox = @import("../messages.zig").ProcessMailbox;
const Inbox = @import("./inbox.zig").Inbox;
const Supervisor = @import("../supervisor.zig").Supervisor;
const Registry = @import("../registry.zig").Registry;
const RemoteProcessInfo = @import("../distributed_registry.zig").RemoteProcessInfo;
const compat = @import("../compat.zig");

/// Test context that owns mock inboxes, mock supervisors, and simulated time.
///
/// Call `deinit()` at the end of the test to release all mocks created through
/// this context.
pub const TestContext = struct {
    /// Allocator used for mocks and captured data.
    allocator: std.mem.Allocator,
    /// Simulated time in milliseconds.
    current_time_ms: i64,
    /// Mock inboxes owned by this context.
    mock_inboxes: std.ArrayListUnmanaged(*MockInbox),
    /// Mock supervisors owned by this context.
    mock_supervisors: std.ArrayListUnmanaged(*MockSupervisor),

    /// Initialize an empty test context.
    pub fn init(allocator: std.mem.Allocator) TestContext {
        return .{
            .allocator = allocator,
            .current_time_ms = 0,
            .mock_inboxes = .empty,
            .mock_supervisors = .empty,
        };
    }

    /// Release every mock created through this context.
    pub fn deinit(self: *TestContext) void {
        for (self.mock_inboxes.items) |mock| {
            mock.deinit();
            self.allocator.destroy(mock);
        }
        self.mock_inboxes.deinit(self.allocator);

        for (self.mock_supervisors.items) |mock| {
            mock.deinit();
            self.allocator.destroy(mock);
        }
        self.mock_supervisors.deinit(self.allocator);
    }

    /// Advance simulated time by `ms` milliseconds.
    pub fn advanceTime(self: *TestContext, ms: i64) void {
        self.current_time_ms +|= ms;
    }

    /// Return current simulated time in milliseconds.
    pub fn now(self: *TestContext) i64 {
        return self.current_time_ms;
    }

    /// Create a mock inbox that captures messages.
    ///
    /// The returned pointer is owned by the context and is destroyed by
    /// `TestContext.deinit()`.
    pub fn mockInbox(self: *TestContext) !*MockInbox {
        const mock = try self.allocator.create(MockInbox);
        errdefer self.allocator.destroy(mock);

        mock.* = MockInbox.init(self.allocator);
        try self.mock_inboxes.append(self.allocator, mock);
        return mock;
    }

    /// Create a mock supervisor owned by the context.
    pub fn mockSupervisor(self: *TestContext) !*MockSupervisor {
        const mock = try self.allocator.create(MockSupervisor);
        errdefer self.allocator.destroy(mock);

        mock.* = MockSupervisor.init(self.allocator);
        try self.mock_supervisors.append(self.allocator, mock);
        return mock;
    }
};

/// Mock inbox that captures owned copies of messages.
///
/// `send()` duplicates the input message. `recv()` transfers ownership of a
/// captured message to the caller, who must call `deinit()`.
pub const MockInbox = struct {
    /// Allocator for captured messages.
    allocator: std.mem.Allocator,
    /// Captured message queue.
    messages: std.ArrayListUnmanaged(Message),
    /// Protects captured message storage.
    mutex: compat.Mutex,

    fn init(allocator: std.mem.Allocator) MockInbox {
        return .{
            .allocator = allocator,
            .messages = .empty,
            .mutex = .{},
        };
    }

    fn deinit(self: *MockInbox) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.messages.items) |*msg| {
            msg.deinit();
        }
        self.messages.deinit(self.allocator);
    }

    /// Capture a duplicate of `msg`.
    pub fn send(self: *MockInbox, msg: Message) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const msg_copy = try msg.dupe();
        errdefer msg_copy.deinit();
        try self.messages.append(self.allocator, msg_copy);
    }

    /// Remove and return the oldest captured message.
    ///
    /// The caller owns the returned message and must call `deinit()`.
    pub fn recv(self: *MockInbox) ?Message {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.messages.items.len == 0) return null;
        return self.messages.orderedRemove(0);
    }

    /// Return the number of captured messages.
    pub fn count(self: *MockInbox) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.messages.items.len;
    }

    /// Return a borrowed copy of the captured message value at `index`.
    ///
    /// The message remains owned by the mock inbox; do not deinitialize the
    /// value returned from `peek()`.
    pub fn peek(self: *MockInbox, index: usize) ?Message {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (index >= self.messages.items.len) return null;
        return self.messages.items[index];
    }

    /// Deinitialize and remove all captured messages.
    pub fn clear(self: *MockInbox) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.messages.items) |*msg| {
            msg.deinit();
        }
        self.messages.clearRetainingCapacity();
    }
};

/// Mock supervisor for deterministic tests without spawning worker threads.
pub const MockSupervisor = struct {
    /// Allocator for copied child ids.
    allocator: std.mem.Allocator,
    /// Tracked child records.
    children: std.ArrayListUnmanaged(ChildInfo),
    /// Protects child state.
    mutex: compat.Mutex,
    /// Total simulated restart count.
    restart_count: u32,
    /// Supervisor state.
    state: SupervisorState,

    const SupervisorState = enum {
        initial,
        running,
        stopped,
    };

    const ChildInfo = struct {
        id: []const u8,
        start_fn: *const fn () void,
        state: ProcessState,
        restart_count: u32,
    };

    const ProcessState = enum {
        initial,
        running,
        stopped,
        failed,
    };

    fn init(allocator: std.mem.Allocator) MockSupervisor {
        return .{
            .allocator = allocator,
            .children = .empty,
            .mutex = .{},
            .restart_count = 0,
            .state = .initial,
        };
    }

    fn deinit(self: *MockSupervisor) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.children.items) |*child| {
            self.allocator.free(child.id);
        }
        self.children.deinit(self.allocator);
    }

    /// Add a child record without starting a real thread.
    pub fn addChild(self: *MockSupervisor, id: []const u8, start_fn: *const fn () void) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.children.items) |child| {
            if (std.mem.eql(u8, child.id, id)) return error.AlreadyExists;
        }

        const id_copy = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(id_copy);

        try self.children.append(self.allocator, .{
            .id = id_copy,
            .start_fn = start_fn,
            .state = .initial,
            .restart_count = 0,
        });
    }

    /// Mark all children as running.
    pub fn start(self: *MockSupervisor) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.state != .initial) return error.AlreadyRunning;

        for (self.children.items) |*child| {
            child.state = .running;
        }
        self.state = .running;
    }

    /// Mark all children as stopped.
    pub fn stop(self: *MockSupervisor) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.children.items) |*child| {
            child.state = .stopped;
        }
        self.state = .stopped;
    }

    /// Simulate a child failure and increment restart counters.
    pub fn failChild(self: *MockSupervisor, id: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.children.items) |*child| {
            if (std.mem.eql(u8, child.id, id)) {
                child.state = .failed;
                child.restart_count +|= 1;
                self.restart_count +|= 1;
                return;
            }
        }
        return error.ChildNotFound;
    }

    /// Return the number of mock children.
    pub fn childCount(self: *MockSupervisor) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.children.items.len;
    }

    /// Return the total simulated restart count.
    pub fn getRestartCount(self: *MockSupervisor) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.restart_count;
    }
};

/// Expected message fields used by `expectMessage`.
///
/// Null fields are ignored.
pub const MessageAssertion = struct {
    /// Expected payload, if any.
    payload: ?[]const u8 = null,
    /// Expected sender, if any.
    sender: ?[]const u8 = null,
    /// Expected priority, if any.
    priority: ?MessagePriority = null,
    /// Expected signal, if any.
    signal: ?Signal = null,
    /// Expected correlation id, if any.
    correlation_id: ?[]const u8 = null,
};

/// Consume the next mock message and assert selected fields.
pub fn expectMessage(
    _: anytype,
    mock_inbox: *MockInbox,
    assertion: MessageAssertion,
) !void {
    const msg = mock_inbox.recv() orelse {
        return error.ExpectedMessage;
    };
    defer msg.deinit();

    if (assertion.payload) |expected| {
        if (msg.payload) |actual| {
            try std.testing.expectEqualSlices(u8, expected, actual);
        } else {
            return error.ExpectedPayload;
        }
    }

    if (assertion.sender) |expected| {
        try std.testing.expectEqualSlices(u8, expected, msg.sender);
    }

    if (assertion.priority) |expected| {
        try std.testing.expectEqual(expected, msg.priority);
    }

    if (assertion.signal) |expected| {
        if (msg.signal) |actual| {
            try std.testing.expectEqual(expected, actual);
        } else {
            return error.ExpectedSignal;
        }
    }

    if (assertion.correlation_id) |expected| {
        if (msg.metadata.correlation_id) |actual| {
            try std.testing.expectEqualSlices(u8, expected, actual);
        } else {
            return error.ExpectedCorrelationId;
        }
    }
}

/// Consume the next mock message and assert its signal.
pub fn expectSignal(
    _: anytype,
    mock_inbox: *MockInbox,
    expected_signal: Signal,
) !void {
    const msg = mock_inbox.recv() orelse {
        return error.ExpectedSignal;
    };
    defer msg.deinit();

    if (msg.signal) |actual| {
        try std.testing.expectEqual(expected_signal, actual);
    } else {
        return error.ExpectedSignal;
    }
}

test "TestContext basic operations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = TestContext.init(allocator);
    defer ctx.deinit();

    try std.testing.expect(ctx.now() == 0);
    ctx.advanceTime(1000);
    try std.testing.expect(ctx.now() == 1000);

    ctx.current_time_ms = std.math.maxInt(i64) - 1;
    ctx.advanceTime(10);
    try std.testing.expectEqual(std.math.maxInt(i64), ctx.now());
    ctx.current_time_ms = std.math.minInt(i64) + 1;
    ctx.advanceTime(-10);
    try std.testing.expectEqual(std.math.minInt(i64), ctx.now());
}

test "MockInbox capture and retrieve" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = TestContext.init(allocator);
    defer ctx.deinit();

    var mock = try ctx.mockInbox();

    var msg = try Message.init(allocator, "test_id", "sender", "payload", .info, .normal, null);
    defer msg.deinit();

    try mock.send(msg);
    try std.testing.expect(mock.count() == 1);

    const received = mock.recv();
    try std.testing.expect(received != null);
    defer received.?.deinit();

    try std.testing.expectEqualSlices(u8, "payload", received.?.payload.?);
    try std.testing.expect(mock.count() == 0);
}

test "MockInbox frees a duplicated message when queue growth fails" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var mock = MockInbox.init(failing.allocator());
    defer mock.deinit();

    var message = try Message.init(std.testing.allocator, "id", "sender", "payload", null, .normal, null);
    defer message.deinit();
    try std.testing.expectError(error.OutOfMemory, mock.send(message));
    try std.testing.expectEqual(@as(usize, 0), mock.count());
}

test "MockSupervisor lifecycle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = TestContext.init(allocator);
    defer ctx.deinit();

    var mock = try ctx.mockSupervisor();

    const dummyWorker = struct {
        fn worker() void {}
    }.worker;

    try mock.addChild("worker1", dummyWorker);
    try std.testing.expectError(error.AlreadyExists, mock.addChild("worker1", dummyWorker));
    try std.testing.expect(mock.childCount() == 1);

    try mock.start();
    try std.testing.expect(mock.getRestartCount() == 0);

    try mock.failChild("worker1");
    try std.testing.expect(mock.getRestartCount() == 1);
}

test "expectMessage assertion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = TestContext.init(allocator);
    defer ctx.deinit();

    var mock = try ctx.mockInbox();

    var msg = try Message.init(allocator, "test", "sender", "payload", .alert, .high, null);
    defer msg.deinit();

    try mock.send(msg);

    try expectMessage(std.testing, mock, .{
        .payload = "payload",
        .sender = "sender",
        .priority = .high,
        .signal = .alert,
    });
}

/// Deterministic, thread-safe clock for tests and simulated runtimes.
///
/// A simulated clock only moves when the test advances it, which makes
/// timeout and backoff behavior reproducible. Its `now`/`sleep` semantics are
/// designed to slot into `PolicyOptions.clock` and `PolicyOptions.sleeper`
/// hooks through small context wrappers.
pub const SimulatedClock = struct {
    /// Current simulated time in milliseconds.
    now_ms: i64,
    /// Protects clock state.
    mutex: compat.Mutex,

    /// Initialize a clock at `start_ms`.
    pub fn init(start_ms: i64) SimulatedClock {
        return .{ .now_ms = start_ms, .mutex = .{} };
    }

    /// Return the current simulated time in milliseconds.
    pub fn now(self: *SimulatedClock) i64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.now_ms;
    }

    /// Advance the clock by `ms` milliseconds, saturating on overflow.
    pub fn advance(self: *SimulatedClock, ms: i64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.now_ms +|= ms;
    }

    /// Set the clock to an absolute time.
    pub fn set(self: *SimulatedClock, ms: i64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.now_ms = ms;
    }

    /// Consume a sleep request by advancing simulated time.
    ///
    /// Sub-millisecond sleeps advance the clock by one millisecond so retry
    /// loops always make progress.
    pub fn sleep(self: *SimulatedClock, nanoseconds: u64) void {
        const ms_u64 = if (nanoseconds == 0)
            0
        else
            ((nanoseconds - 1) / std.time.ns_per_ms) + 1;
        const ms: i64 = @intCast(@min(ms_u64, std.math.maxInt(i64)));
        self.advance(ms);
    }
};

/// Deterministic timer service driven by a `SimulatedClock`.
///
/// Unlike `vigil.TimerService`, no threads are spawned: callbacks fire synchronously
/// inside `advance()`, in deadline order, on the calling thread.
pub const SimulatedTimerService = struct {
    /// Allocator for timer storage.
    allocator: std.mem.Allocator,
    /// Clock that defines "now" for deadlines.
    clock: *SimulatedClock,
    /// Pending timers.
    timers: std.ArrayListUnmanaged(SimulatedTimer),
    /// Id assigned to the next scheduled timer.
    next_id: u64,
    /// Protects timer storage.
    mutex: compat.Mutex,

    const SimulatedTimer = struct {
        id: u64,
        deadline_ms: i64,
        interval_ms: ?u32,
        callback: *const fn () void,
    };

    /// Initialize an empty timer service against `clock`.
    pub fn init(allocator: std.mem.Allocator, clock: *SimulatedClock) SimulatedTimerService {
        return .{
            .allocator = allocator,
            .clock = clock,
            .timers = .empty,
            .next_id = 1,
            .mutex = .{},
        };
    }

    /// Release timer storage. Pending callbacks never fire.
    pub fn deinit(self: *SimulatedTimerService) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.timers.deinit(self.allocator);
    }

    /// Schedule `callback` to fire once after `delay_ms` of simulated time.
    ///
    /// Returns an id usable with `cancel()`.
    pub fn setTimeout(self: *SimulatedTimerService, delay_ms: u32, callback: *const fn () void) !u64 {
        return try self.schedule(delay_ms, null, callback);
    }

    /// Schedule `callback` to fire every `interval_ms` of simulated time.
    ///
    /// Returns an id usable with `cancel()`. Zero-length intervals are
    /// rejected to match `vigil.TimerService.setInterval`.
    pub fn setInterval(self: *SimulatedTimerService, interval_ms: u32, callback: *const fn () void) !u64 {
        if (interval_ms == 0) return error.InvalidInterval;
        return try self.schedule(interval_ms, interval_ms, callback);
    }

    fn schedule(self: *SimulatedTimerService, delay_ms: u32, interval_ms: ?u32, callback: *const fn () void) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const id = self.next_id;
        try self.timers.append(self.allocator, .{
            .id = id,
            .deadline_ms = self.clock.now() +| @as(i64, delay_ms),
            .interval_ms = interval_ms,
            .callback = callback,
        });
        self.next_id += 1;
        return id;
    }

    /// Cancel a pending timer. Returns false when the id is not pending.
    pub fn cancel(self: *SimulatedTimerService, id: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.timers.items, 0..) |timer, i| {
            if (timer.id == id) {
                _ = self.timers.swapRemove(i);
                return true;
            }
        }
        return false;
    }

    /// Return the number of pending timers.
    pub fn pendingCount(self: *SimulatedTimerService) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.timers.items.len;
    }

    /// Advance simulated time by `ms` and fire due timers in deadline order.
    ///
    /// Intervals re-arm and may fire several times within one advance.
    /// Callbacks run synchronously on the calling thread, outside the service
    /// lock, so they may schedule or cancel timers. Returns the number of
    /// callbacks fired.
    pub fn advance(self: *SimulatedTimerService, ms: i64) usize {
        const target_ms = self.clock.now() +| ms;
        var fired: usize = 0;

        while (true) {
            self.mutex.lock();
            var due_index: ?usize = null;
            for (self.timers.items, 0..) |timer, i| {
                if (timer.deadline_ms > target_ms) continue;
                if (due_index) |current| {
                    const current_timer = self.timers.items[current];
                    if (timer.deadline_ms < current_timer.deadline_ms or
                        (timer.deadline_ms == current_timer.deadline_ms and timer.id < current_timer.id))
                    {
                        due_index = i;
                    }
                } else {
                    due_index = i;
                }
            }

            const index = due_index orelse {
                self.mutex.unlock();
                break;
            };

            var timer = self.timers.items[index];
            if (timer.interval_ms) |interval| {
                self.timers.items[index].deadline_ms = timer.deadline_ms +| @as(i64, interval);
            } else {
                _ = self.timers.swapRemove(index);
            }
            self.mutex.unlock();

            if (self.clock.now() < timer.deadline_ms) {
                self.clock.set(timer.deadline_ms);
            }
            timer.callback();
            fired += 1;
        }

        self.clock.set(target_ms);
        return fired;
    }
};

/// Scripted failure schedule for `FaultInjector`.
pub const FaultPlan = struct {
    /// Fail the first N calls.
    fail_first: u32 = 0,
    /// Additionally fail every Nth call (1-based) when set.
    fail_every: ?u32 = null,
    /// Error returned for injected failures.
    error_value: anyerror = error.InjectedFault,
};

/// Deterministic fault injection for dependency and policy tests.
///
/// A fault injector decides per call whether to fail, following its plan.
/// Combine with `vigil.executePolicy` to test retry, fallback, and
/// circuit-breaker behavior without real failing dependencies.
pub const FaultInjector = struct {
    /// Failure schedule.
    plan: FaultPlan,
    /// Total calls observed.
    calls: u32,
    /// Total failures injected.
    injected: u32,
    /// Protects counters.
    mutex: compat.Mutex,

    /// Initialize an injector with a failure plan.
    pub fn init(plan: FaultPlan) FaultInjector {
        return .{
            .plan = plan,
            .calls = 0,
            .injected = 0,
            .mutex = .{},
        };
    }

    /// Record one call and return the injected error when the plan says so.
    pub fn checkFailure(self: *FaultInjector) ?anyerror {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.calls +|= 1;
        var should_fail = self.calls <= self.plan.fail_first;
        if (!should_fail) {
            if (self.plan.fail_every) |every| {
                should_fail = every > 0 and self.calls % every == 0;
            }
        }

        if (should_fail) {
            self.injected +|= 1;
            return self.plan.error_value;
        }
        return null;
    }

    /// Record one call and fail with the plan's error when injection is due.
    pub fn call(self: *FaultInjector) anyerror!void {
        if (self.checkFailure()) |err| return err;
    }

    /// Return the total observed call count.
    pub fn callCount(self: *FaultInjector) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.calls;
    }

    /// Return the total injected failure count.
    pub fn injectedCount(self: *FaultInjector) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.injected;
    }

    /// Reset call and injection counters.
    pub fn reset(self: *FaultInjector) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.calls = 0;
        self.injected = 0;
    }
};

/// In-memory fake of `DistributedRegistry` for deterministic cluster tests.
///
/// No sockets or threads are involved: peers are plain records whose names and
/// liveness the test controls directly. Use `disconnectPeer()` to simulate a
/// network partition and `reconnectPeer()` to heal it.
pub const FakeDistributedRegistry = struct {
    /// Allocator for peer records and copied names.
    allocator: std.mem.Allocator,
    /// Local name registry.
    local_registry: Registry,
    /// Simulated peer nodes.
    peers: std.ArrayListUnmanaged(FakePeer),
    /// Total peer queries answered, including misses.
    query_count: u64,
    /// Local listen port reported for local resolutions.
    listen_port: u16,
    /// Protects peers and counters.
    mutex: compat.Mutex,

    const FakePeer = struct {
        node_id: []const u8,
        address: []const u8,
        port: u16,
        alive: bool,
        names: std.ArrayListUnmanaged([]const u8),
    };

    /// Initialize a fake registry with no peers.
    pub fn init(allocator: std.mem.Allocator, listen_port: u16) FakeDistributedRegistry {
        return .{
            .allocator = allocator,
            .local_registry = Registry.init(allocator),
            .peers = .empty,
            .query_count = 0,
            .listen_port = listen_port,
            .mutex = .{},
        };
    }

    /// Release peer records and the local registry.
    pub fn deinit(self: *FakeDistributedRegistry) void {
        self.mutex.lock();
        for (self.peers.items) |*peer| {
            for (peer.names.items) |name| self.allocator.free(name);
            peer.names.deinit(self.allocator);
            self.allocator.free(peer.node_id);
            self.allocator.free(peer.address);
        }
        self.peers.deinit(self.allocator);
        self.mutex.unlock();

        self.local_registry.deinit();
    }

    /// Register a local mailbox under `name`.
    pub fn register(self: *FakeDistributedRegistry, name: []const u8, mailbox: *ProcessMailbox) !void {
        try self.local_registry.register(name, mailbox);
    }

    /// Look up a local mailbox by name.
    pub fn whereis(self: *FakeDistributedRegistry, name: []const u8) ?*ProcessMailbox {
        return self.local_registry.whereis(name);
    }

    /// Add a simulated peer node.
    pub fn addPeer(self: *FakeDistributedRegistry, node_id: []const u8, address: []const u8, port: u16) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.peers.items) |peer| {
            if (std.mem.eql(u8, peer.node_id, node_id)) return error.AlreadyExists;
        }

        const node_id_copy = try self.allocator.dupe(u8, node_id);
        errdefer self.allocator.free(node_id_copy);
        const address_copy = try self.allocator.dupe(u8, address);
        errdefer self.allocator.free(address_copy);

        try self.peers.append(self.allocator, .{
            .node_id = node_id_copy,
            .address = address_copy,
            .port = port,
            .alive = true,
            .names = .empty,
        });
    }

    /// Register a name as living on a simulated peer.
    pub fn registerRemote(self: *FakeDistributedRegistry, node_id: []const u8, name: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const peer = self.findPeerLocked(node_id) orelse return error.UnknownPeer;
        for (peer.names.items) |existing| {
            if (std.mem.eql(u8, existing, name)) return;
        }

        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        try peer.names.append(self.allocator, name_copy);
    }

    /// Simulate a peer becoming unreachable.
    pub fn disconnectPeer(self: *FakeDistributedRegistry, node_id: []const u8) bool {
        return self.setPeerAlive(node_id, false);
    }

    /// Simulate a disconnected peer coming back.
    pub fn reconnectPeer(self: *FakeDistributedRegistry, node_id: []const u8) bool {
        return self.setPeerAlive(node_id, true);
    }

    fn setPeerAlive(self: *FakeDistributedRegistry, node_id: []const u8, alive: bool) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const peer = self.findPeerLocked(node_id) orelse return false;
        peer.alive = alive;
        return true;
    }

    fn findPeerLocked(self: *FakeDistributedRegistry, node_id: []const u8) ?*FakePeer {
        for (self.peers.items) |*peer| {
            if (std.mem.eql(u8, peer.node_id, node_id)) return peer;
        }
        return null;
    }

    /// Resolve a name locally first, then across live simulated peers.
    ///
    /// Returned slices are borrowed: from the caller for local results, from
    /// peer storage for remote results. Disconnected peers never answer.
    pub fn whereisGlobal(self: *FakeDistributedRegistry, name: []const u8) ?RemoteProcessInfo {
        if (self.local_registry.whereis(name) != null) {
            return .{
                .name = name,
                .node_address = "local",
                .node_port = self.listen_port,
            };
        }
        return self.queryPeers(name);
    }

    /// Query live simulated peers for a name.
    pub fn queryPeers(self: *FakeDistributedRegistry, name: []const u8) ?RemoteProcessInfo {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.query_count +|= 1;
        for (self.peers.items) |peer| {
            if (!peer.alive) continue;
            for (peer.names.items) |peer_name| {
                if (std.mem.eql(u8, peer_name, name)) {
                    return .{
                        .name = peer_name,
                        .node_address = peer.address,
                        .node_port = peer.port,
                    };
                }
            }
        }
        return null;
    }

    /// Return the total number of peer queries made.
    pub fn queryCount(self: *FakeDistributedRegistry) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.query_count;
    }
};

/// Fill an inbox to capacity with `payload`, simulating a full queue.
///
/// Filling stops once the active queue reaches its configured capacity, so no
/// overflow is dropped or dead-lettered. Returns the number of messages sent.
pub fn fillInbox(inbox: *Inbox, payload: []const u8) !usize {
    const capacity = inbox.mailbox.config.capacity;
    var accepted: usize = 0;
    while (try inbox.queueDepth() < capacity) {
        inbox.send(payload) catch |err| switch (err) {
            MessageError.MailboxFull => return accepted,
            else => return err,
        };
        accepted += 1;
    }
    return accepted;
}

/// Drain up to `max_messages` from an inbox, simulating a consumer catching
/// up after a stall. Returns the number of messages consumed.
pub fn drainInbox(inbox: *Inbox, max_messages: usize) !usize {
    var consumed: usize = 0;
    while (consumed < max_messages) {
        const msg = inbox.recvTimeout(0) catch |err| switch (err) {
            MessageError.EmptyMailbox => return consumed,
            else => return err,
        } orelse return consumed;
        msg.deinit();
        consumed += 1;
    }
    return consumed;
}

test "SimulatedClock advances deterministically" {
    var clock = SimulatedClock.init(0);
    try std.testing.expectEqual(@as(i64, 0), clock.now());

    clock.advance(250);
    try std.testing.expectEqual(@as(i64, 250), clock.now());

    clock.sleep(5 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(i64, 255), clock.now());

    // Sub-millisecond sleeps still make progress.
    clock.sleep(1);
    try std.testing.expectEqual(@as(i64, 256), clock.now());

    clock.set(std.math.maxInt(i64));
    clock.advance(10);
    try std.testing.expectEqual(std.math.maxInt(i64), clock.now());
}

var simulated_timer_fires = std.atomic.Value(u32).init(0);
var simulated_interval_fires = std.atomic.Value(u32).init(0);

fn recordSimulatedTimerFire() void {
    _ = simulated_timer_fires.fetchAdd(1, .monotonic);
}

fn recordSimulatedIntervalFire() void {
    _ = simulated_interval_fires.fetchAdd(1, .monotonic);
}

test "SimulatedTimerService fires timers deterministically in deadline order" {
    simulated_timer_fires.store(0, .release);
    simulated_interval_fires.store(0, .release);

    var clock = SimulatedClock.init(0);
    var timers = SimulatedTimerService.init(std.testing.allocator, &clock);
    defer timers.deinit();

    try std.testing.expectError(error.InvalidInterval, timers.setInterval(0, recordSimulatedIntervalFire));

    _ = try timers.setTimeout(10, recordSimulatedTimerFire);
    const interval_id = try timers.setInterval(4, recordSimulatedIntervalFire);
    try std.testing.expectEqual(@as(usize, 2), timers.pendingCount());

    // Nothing fires before its deadline.
    try std.testing.expectEqual(@as(usize, 0), timers.advance(3));

    // Advancing to 12ms fires the interval at 4, 8, 12 and the timeout at 10.
    try std.testing.expectEqual(@as(usize, 4), timers.advance(9));
    try std.testing.expectEqual(@as(i64, 12), clock.now());
    try std.testing.expectEqual(@as(u32, 1), simulated_timer_fires.load(.acquire));
    try std.testing.expectEqual(@as(u32, 3), simulated_interval_fires.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), timers.pendingCount());

    // Cancelled intervals never fire again.
    try std.testing.expect(timers.cancel(interval_id));
    try std.testing.expect(!timers.cancel(interval_id));
    try std.testing.expectEqual(@as(usize, 0), timers.advance(100));
    try std.testing.expectEqual(@as(u32, 3), simulated_interval_fires.load(.acquire));
}

test "FaultInjector follows its failure plan" {
    var injector = FaultInjector.init(.{ .fail_first = 2, .fail_every = 3 });

    try std.testing.expectError(error.InjectedFault, injector.call()); // call 1: fail_first
    try std.testing.expectError(error.InjectedFault, injector.call()); // call 2: fail_first
    try std.testing.expectError(error.InjectedFault, injector.call()); // call 3: every 3rd
    try injector.call(); // call 4
    try injector.call(); // call 5
    try std.testing.expectError(error.InjectedFault, injector.call()); // call 6: every 3rd
    try injector.call(); // call 7

    try std.testing.expectEqual(@as(u32, 7), injector.callCount());
    try std.testing.expectEqual(@as(u32, 4), injector.injectedCount());

    injector.reset();
    try std.testing.expectEqual(@as(u32, 0), injector.callCount());
    try std.testing.expectError(error.InjectedFault, injector.call());

    var custom = FaultInjector.init(.{ .fail_first = 1, .error_value = error.DependencyUnavailable });
    try std.testing.expectError(error.DependencyUnavailable, custom.call());
    try custom.call();
}

test "FakeDistributedRegistry resolves names and simulates partitions" {
    const allocator = std.testing.allocator;

    var registry = FakeDistributedRegistry.init(allocator, 9100);
    defer registry.deinit();

    var mailbox = ProcessMailbox.init(allocator, .{ .capacity = 4 });
    defer mailbox.deinit();

    try registry.register("local_service", &mailbox);
    try std.testing.expect(registry.whereis("local_service") == &mailbox);

    const local = registry.whereisGlobal("local_service").?;
    try std.testing.expectEqualStrings("local", local.node_address);
    try std.testing.expectEqual(@as(u16, 9100), local.node_port);

    try registry.addPeer("node_b", "10.0.0.2", 9200);
    try std.testing.expectError(error.AlreadyExists, registry.addPeer("node_b", "10.0.0.2", 9200));
    try std.testing.expectError(error.UnknownPeer, registry.registerRemote("missing", "svc"));
    try registry.registerRemote("node_b", "remote_service");

    const remote = registry.whereisGlobal("remote_service").?;
    try std.testing.expectEqualStrings("10.0.0.2", remote.node_address);
    try std.testing.expectEqual(@as(u16, 9200), remote.node_port);

    // A disconnected peer stops answering; reconnecting heals resolution.
    try std.testing.expect(registry.disconnectPeer("node_b"));
    try std.testing.expect(registry.whereisGlobal("remote_service") == null);
    try std.testing.expect(registry.reconnectPeer("node_b"));
    try std.testing.expect(registry.whereisGlobal("remote_service") != null);

    try std.testing.expect(registry.queryCount() >= 3);
    try std.testing.expect(!registry.disconnectPeer("missing"));
}

test "fillInbox and drainInbox simulate full queues and recovering consumers" {
    const allocator = std.testing.allocator;
    var target = try @import("./inbox.zig").inboxBuilder(allocator).capacity(4).build();
    defer target.close();

    const filled = try fillInbox(target, "load");
    try std.testing.expectEqual(@as(usize, 4), filled);
    try std.testing.expectEqual(@as(usize, 4), try target.queueDepth());

    // Filling an already-full inbox sends nothing.
    try std.testing.expectEqual(@as(usize, 0), try fillInbox(target, "load"));

    try std.testing.expectEqual(@as(usize, 3), try drainInbox(target, 3));
    try std.testing.expectEqual(@as(usize, 1), try drainInbox(target, 10));
    try std.testing.expectEqual(@as(usize, 0), try drainInbox(target, 10));
}

test "policy execute composes with FaultInjector and SimulatedClock" {
    const policy = @import("../policy.zig");

    const Harness = struct {
        injector: FaultInjector,
        clock: SimulatedClock,

        fn operation(ctx: *@This()) anyerror!u32 {
            try ctx.injector.call();
            return 7;
        }

        fn clockHook(ctx: *@This()) i64 {
            return ctx.clock.now();
        }

        fn sleepHook(ctx: *@This(), nanoseconds: u64) void {
            ctx.clock.sleep(nanoseconds);
        }
    };

    var harness = Harness{
        .injector = FaultInjector.init(.{ .fail_first = 2 }),
        .clock = SimulatedClock.init(0),
    };

    const result = policy.execute(Harness, u32, &harness, Harness.operation, .{
        .retry = .{
            .max_attempts = 3,
            .backoff = .{ .fixed_ms = 20 },
        },
        .clock = Harness.clockHook,
        .sleeper = Harness.sleepHook,
    });

    switch (result) {
        .success => |success| {
            try std.testing.expectEqual(@as(u32, 7), success.value);
            try std.testing.expectEqual(@as(u32, 3), success.report.attempts);
            try std.testing.expectEqual(@as(u32, 2), success.report.retries);
            // Two fixed 20ms backoffs elapsed on the simulated clock.
            try std.testing.expectEqual(@as(i64, 40), success.report.elapsed_ms);
        },
        else => return error.ExpectedSuccess,
    }
    try std.testing.expectEqual(@as(u32, 3), harness.injector.callCount());
    try std.testing.expectEqual(@as(u32, 2), harness.injector.injectedCount());
}
