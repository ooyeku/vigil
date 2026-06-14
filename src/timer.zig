const std = @import("std");
const Message = @import("messages.zig").Message;
const ProcessMailbox = @import("messages.zig").ProcessMailbox;
const compat = @import("compat.zig");

var timer_test_count = std.atomic.Value(u32).init(0);

fn incrementTimerTestCount() void {
    _ = timer_test_count.fetchAdd(1, .monotonic);
}

/// Function called by `Timer` after a timeout or interval tick.
pub const TimerCallback = *const fn () void;

/// Timer utilities for scheduling messages.
pub const Timer = struct {
    /// Allocator for timer contexts.
    allocator: std.mem.Allocator,
    /// Active timeout/interval context, if any.
    context: ?*TimerContext = null,
    /// Worker thread for the active timeout/interval.
    thread: ?std.Thread = null,

    const TimerContext = struct {
        cancelled: std.atomic.Value(bool),
        interval_ms: u32,
        callback: TimerCallback,
        repeat: bool,
    };

    /// Initialize an idle timer.
    pub fn init(allocator: std.mem.Allocator) Timer {
        return .{
            .allocator = allocator,
            .context = null,
            .thread = null,
        };
    }

    /// Cancel active work and join the timer thread.
    pub fn deinit(self: *Timer) void {
        self.cancel();
        self.joinExistingThread();
    }

    /// Request cancellation of the active timeout or interval.
    pub fn cancel(self: *Timer) void {
        if (self.context) |ctx| {
            ctx.cancelled.store(true, .release);
        }
    }

    /// Run `callback` once after `delay_ms`.
    ///
    /// Replaces any existing timeout or interval on this timer.
    pub fn setTimeout(self: *Timer, delay_ms: u32, callback: TimerCallback) !void {
        self.cancel();
        self.joinExistingThread();
        self.context = try self.allocator.create(TimerContext);
        self.context.?.* = .{
            .cancelled = std.atomic.Value(bool).init(false),
            .interval_ms = delay_ms,
            .callback = callback,
            .repeat = false,
        };
        errdefer {
            self.allocator.destroy(self.context.?);
            self.context = null;
        }
        self.thread = try std.Thread.spawn(.{}, timerLoop, .{self.context.?});
    }

    /// Run `callback` every `interval_ms` until cancelled.
    ///
    /// Replaces any existing timeout or interval on this timer.
    pub fn setInterval(self: *Timer, interval_ms: u32, callback: TimerCallback) !void {
        self.cancel();
        self.joinExistingThread();
        self.context = try self.allocator.create(TimerContext);
        self.context.?.* = .{
            .cancelled = std.atomic.Value(bool).init(false),
            .interval_ms = interval_ms,
            .callback = callback,
            .repeat = true,
        };
        errdefer {
            self.allocator.destroy(self.context.?);
            self.context = null;
        }
        self.thread = try std.Thread.spawn(.{}, timerLoop, .{self.context.?});
    }

    fn joinExistingThread(self: *Timer) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        if (self.context) |ctx| {
            self.allocator.destroy(ctx);
            self.context = null;
        }
    }

    fn timerLoop(ctx: *TimerContext) void {
        while (!ctx.cancelled.load(.acquire)) {
            compat.sleep(@as(u64, ctx.interval_ms) * std.time.ns_per_ms);
            if (ctx.cancelled.load(.acquire)) {
                return;
            }
            ctx.callback();
            if (!ctx.repeat) {
                return;
            }
        }
    }

    /// Schedule a message to be sent after a delay.
    ///
    /// Spawns a detached thread to handle the timing.
    /// This function takes ownership of `msg` once it succeeds. If thread
    /// creation fails, the message is deinitialized before returning the error.
    pub fn sendAfter(
        allocator: std.mem.Allocator,
        delay_ms: u32,
        mailbox: *ProcessMailbox,
        msg: Message,
    ) !void {
        const Context = struct {
            delay: u32,
            mailbox: *ProcessMailbox,
            msg: Message,
            allocator: std.mem.Allocator,
        };

        const context = try allocator.create(Context);
        errdefer allocator.destroy(context);
        context.* = .{
            .delay = delay_ms,
            .mailbox = mailbox,
            .msg = msg,
            .allocator = allocator,
        };
        errdefer context.msg.deinit();

        const thread_fn = struct {
            fn run(ctx: *Context) void {
                defer ctx.allocator.destroy(ctx);

                compat.sleep(@as(u64, ctx.delay) * std.time.ns_per_ms);

                // ProcessMailbox.send consumes the message on success and on
                // failure, so there is no cleanup left in this thread.
                ctx.mailbox.send(ctx.msg) catch {};
            }
        }.run;

        const thread = try std.Thread.spawn(.{}, thread_fn, .{context});
        thread.detach();
    }
};

test "Timer setTimeout runs callback" {
    timer_test_count.store(0, .release);

    var timer = Timer.init(std.testing.allocator);
    defer timer.deinit();

    try timer.setTimeout(10, incrementTimerTestCount);
    compat.sleep(40 * std.time.ns_per_ms);

    try std.testing.expectEqual(@as(u32, 1), timer_test_count.load(.acquire));
}

test "Timer cancel stops interval" {
    timer_test_count.store(0, .release);

    var timer = Timer.init(std.testing.allocator);
    defer timer.deinit();

    try timer.setInterval(5, incrementTimerTestCount);
    compat.sleep(20 * std.time.ns_per_ms);
    timer.cancel();

    const count_after_cancel = timer_test_count.load(.acquire);
    compat.sleep(20 * std.time.ns_per_ms);

    try std.testing.expectEqual(count_after_cancel, timer_test_count.load(.acquire));
}

test "Timer cancel prevents pending timeout callback" {
    timer_test_count.store(0, .release);

    var timer = Timer.init(std.testing.allocator);
    defer timer.deinit();

    try timer.setTimeout(40, incrementTimerTestCount);
    timer.cancel();
    compat.sleep(70 * std.time.ns_per_ms);

    try std.testing.expectEqual(@as(u32, 0), timer_test_count.load(.acquire));
}

test "Timer sendAfter" {
    const allocator = std.testing.allocator;
    var mailbox = ProcessMailbox.init(allocator, .{ .capacity = 10 });
    defer mailbox.deinit();

    var msg = try Message.init(allocator, "timer_msg", "tester", "payload", .info, .normal, null);

    // We need to dupe the message because sendAfter takes ownership
    const msg_copy = try msg.dupe();
    defer msg.deinit(); // Original message

    try Timer.sendAfter(allocator, 10, &mailbox, msg_copy);

    // Wait for timer
    compat.sleep(50 * std.time.ns_per_ms);

    // Check mailbox
    var received = try mailbox.receive();
    defer received.deinit(); // We own the received message

    try std.testing.expectEqualStrings("timer_msg", received.id);
}

test "Timer sendAfter handles failed delivery without double free" {
    const allocator = std.testing.allocator;
    var mailbox = ProcessMailbox.init(allocator, .{
        .capacity = 1,
        .max_message_size = 1,
    });
    defer mailbox.deinit();

    const msg = try Message.init(
        allocator,
        "too-large",
        "timer",
        "oversized",
        null,
        .normal,
        null,
    );

    try Timer.sendAfter(allocator, 1, &mailbox, msg);
    compat.sleep(40 * std.time.ns_per_ms);

    try std.testing.expectError(error.EmptyMailbox, mailbox.receive());
}
