const std = @import("std");
const Mutex = std.Thread.Mutex;
const testing = std.testing;
const Allocator = std.mem.Allocator;

pub const MessageError = error{
    EmptyMailbox,
    MailboxFull,
    InvalidMessage,
    InvalidSender,
};

pub const Message = struct {
    id: []const u8,
    payload: ?[]const u8,
    signal: ?Signal,
    sender: []const u8,
    allocator: ?Allocator,

    pub fn init(
        allocator: Allocator,
        id: []const u8,
        sender: []const u8,
        payload: ?[]const u8,
        signal: ?Signal,
    ) !Message {
        const id_copy = try allocator.dupe(u8, id);
        const sender_copy = try allocator.dupe(u8, sender);
        const payload_copy = if (payload) |p| try allocator.dupe(u8, p) else null;

        return Message{
            .id = id_copy,
            .sender = sender_copy,
            .payload = payload_copy,
            .signal = signal,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Message) void {
        if (self.allocator) |allocator| {
            allocator.free(self.id);
            allocator.free(self.sender);
            if (self.payload) |payload| {
                allocator.free(payload);
            }
        }
    }
};

pub const Signal = enum {
    restart,
    shutdown,
    terminate,
    exit,
    messageErr,
    info,
    warning,
    debug,
    log,
    alert,
    metric,
    event,
    heartbeat,
};

pub const ProcessMailbox = struct {
    messages: std.ArrayList(Message),
    mutex: Mutex,
    capacity: usize,

    pub fn init(allocator: Allocator, capacity: usize) ProcessMailbox {
        return .{
            .messages = std.ArrayList(Message).init(allocator),
            .mutex = .{},
            .capacity = capacity,
        };
    }

    pub fn deinit(self: *ProcessMailbox) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.messages.items, 0..) |_, i| {
            self.messages.items[i].deinit();
        }
        self.messages.deinit();
    }

    pub fn send(self: *ProcessMailbox, msg: Message) MessageError!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.messages.items.len >= self.capacity) {
            return MessageError.MailboxFull;
        }

        self.messages.append(msg) catch {
            var msg_mut = msg;
            msg_mut.deinit();
            return MessageError.InvalidMessage;
        };
    }

    pub fn receive(self: *ProcessMailbox) MessageError!Message {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.messages.items.len == 0) {
            return MessageError.EmptyMailbox;
        }

        return self.messages.orderedRemove(0);
    }

    pub fn peek(self: *ProcessMailbox) MessageError!Message {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.messages.items.len == 0) {
            return MessageError.EmptyMailbox;
        }

        return self.messages.items[0];
    }

    pub fn clear(self: *ProcessMailbox) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.messages.items) |*msg| {
            msg.deinit();
        }
        self.messages.clearRetainingCapacity();
    }
};

test "ProcessMailbox basic operations" {
    const allocator = testing.allocator;
    var mailbox = ProcessMailbox.init(allocator, 10);
    defer mailbox.deinit();

    const msg1 = try Message.init(
        allocator,
        "msg1",
        "sender1",
        "test payload",
        Signal.info,
    );

    try mailbox.send(msg1);

    var received = try mailbox.receive();
    defer received.deinit();

    try testing.expectEqualStrings("msg1", received.id);
    try testing.expectEqualStrings("sender1", received.sender);
    try testing.expectEqualStrings("test payload", received.payload.?);
    try testing.expectEqual(Signal.info, received.signal.?);
}

test "ProcessMailbox capacity limit" {
    const allocator = testing.allocator;
    var mailbox = ProcessMailbox.init(allocator, 2);
    defer mailbox.deinit();

    const msg1 = try Message.init(allocator, "1", "sender", null, null);
    const msg2 = try Message.init(allocator, "2", "sender", null, null);
    var msg3 = try Message.init(allocator, "3", "sender", null, null);

    try mailbox.send(msg1);
    try mailbox.send(msg2);
    try testing.expectError(MessageError.MailboxFull, mailbox.send(msg3));

    msg3.deinit();
}

test "ProcessMailbox empty receive" {
    const allocator = testing.allocator;
    var mailbox = ProcessMailbox.init(allocator, 10);
    defer mailbox.deinit();

    try testing.expectError(MessageError.EmptyMailbox, mailbox.receive());
}

test "Message memory management" {
    const allocator = testing.allocator;

    var msg = try Message.init(
        allocator,
        "test_id",
        "test_sender",
        "test_payload",
        null,
    );
    defer msg.deinit();

    try testing.expectEqualStrings("test_id", msg.id);
    try testing.expectEqualStrings("test_sender", msg.sender);
    try testing.expectEqualStrings("test_payload", msg.payload.?);
}
