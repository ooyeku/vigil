//! Testing utilities for Vigil
//! Provides mocking, assertions, and time control for testing Vigil applications.

const std = @import("std");
const Message = @import("../messages.zig").Message;
const MessagePriority = @import("../messages.zig").MessagePriority;
const Signal = @import("../messages.zig").Signal;
const Inbox = @import("./inbox.zig").Inbox;
const Supervisor = @import("../supervisor.zig").Supervisor;

/// Test context manages test lifecycle, time control, and mocks
pub const TestContext = struct {
    allocator: std.mem.Allocator,
    current_time_ms: i64,
    mock_inboxes: std.ArrayListUnmanaged(*MockInbox),
    mock_supervisors: std.ArrayListUnmanaged(*MockSupervisor),

    /// Initialize a new test context
    pub fn init(allocator: std.mem.Allocator) TestContext {
        return .{
            .allocator = allocator,
            .current_time_ms = 0,
            .mock_inboxes = .{},
            .mock_supervisors = .{},
        };
    }

    /// Cleanup all resources
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

    /// Advance simulated time by milliseconds
    pub fn advanceTime(self: *TestContext, ms: i64) void {
        self.current_time_ms += ms;
    }

    /// Get current simulated time in milliseconds
    pub fn now(self: *TestContext) i64 {
        return self.current_time_ms;
    }

    /// Create a mock inbox that captures messages
    pub fn mockInbox(self: *TestContext) !*MockInbox {
        const mock = try self.allocator.create(MockInbox);
        errdefer self.allocator.destroy(mock);

        mock.* = MockInbox.init(self.allocator);
        try self.mock_inboxes.append(self.allocator, mock);
        return mock;
    }

    /// Create a mock supervisor
    pub fn mockSupervisor(self: *TestContext) !*MockSupervisor {
        const mock = try self.allocator.create(MockSupervisor);
        errdefer self.allocator.destroy(mock);

        mock.* = MockSupervisor.init(self.allocator);
        try self.mock_supervisors.append(self.allocator, mock);
        return mock;
    }
};

/// Mock inbox that captures messages for testing
pub const MockInbox = struct {
    allocator: std.mem.Allocator,
    messages: std.ArrayListUnmanaged(Message),
    mutex: std.Thread.Mutex,

    fn init(allocator: std.mem.Allocator) MockInbox {
        return .{
            .allocator = allocator,
            .messages = .{},
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

    /// Send a message (captures it)
    pub fn send(self: *MockInbox, msg: Message) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const msg_copy = try msg.dupe();
        try self.messages.append(self.allocator, msg_copy);
    }

    /// Receive a message (removes from captured list)
    pub fn recv(self: *MockInbox) ?Message {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.messages.items.len == 0) return null;
        return self.messages.orderedRemove(0);
    }

    /// Get count of captured messages
    pub fn count(self: *MockInbox) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.messages.items.len;
    }

    /// Peek at messages without removing
    pub fn peek(self: *MockInbox, index: usize) ?Message {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (index >= self.messages.items.len) return null;
        return self.messages.items[index];
    }

    /// Clear all captured messages
    pub fn clear(self: *MockInbox) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.messages.items) |*msg| {
            msg.deinit();
        }
        self.messages.clearRetainingCapacity();
    }
};

/// Mock supervisor for testing without threads
pub const MockSupervisor = struct {
    allocator: std.mem.Allocator,
    children: std.ArrayListUnmanaged(ChildInfo),
    mutex: std.Thread.Mutex,
    restart_count: u32,
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
            .children = .{},
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

    /// Add a child process
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

    /// Start all children
    pub fn start(self: *MockSupervisor) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.state != .initial) return error.AlreadyRunning;

        for (self.children.items) |*child| {
            child.state = .running;
        }
        self.state = .running;
    }

    /// Stop all children
    pub fn stop(self: *MockSupervisor) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.children.items) |*child| {
            child.state = .stopped;
        }
        self.state = .stopped;
    }

    /// Simulate a child failure
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

    /// Get child count
    pub fn childCount(self: *MockSupervisor) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.children.items.len;
    }

    /// Get restart count
    pub fn getRestartCount(self: *MockSupervisor) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.restart_count;
    }
};

/// Assertion helper for messages
pub const MessageAssertion = struct {
    payload: ?[]const u8 = null,
    sender: ?[]const u8 = null,
    priority: ?MessagePriority = null,
    signal: ?Signal = null,
    correlation_id: ?[]const u8 = null,
};

/// Expect a message matching the assertion
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

/// Expect a specific signal
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
