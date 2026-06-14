//! Testing utilities for Vigil.
//!
//! Provides mocking, assertions, and time control for testing Vigil applications.

const std = @import("std");
const Message = @import("../messages.zig").Message;
const MessagePriority = @import("../messages.zig").MessagePriority;
const Signal = @import("../messages.zig").Signal;
const Inbox = @import("./inbox.zig").Inbox;
const Supervisor = @import("../supervisor.zig").Supervisor;
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
        self.current_time_ms += ms;
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
                child.restart_count += 1;
                self.restart_count += 1;
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
