const std = @import("std");
const Message = @import("messages.zig").Message;
const ProcessMailbox = @import("messages.zig").ProcessMailbox;

/// Timer utilities for scheduling messages.
pub const Timer = struct {
    /// Schedule a message to be sent after a delay.
    /// Spawns a detached thread to handle the timing.
    /// The message is owned by the timer until sent.
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
        context.* = .{
            .delay = delay_ms,
            .mailbox = mailbox,
            .msg = msg,
            .allocator = allocator,
        };

        const thread_fn = struct {
            fn run(ctx: *Context) void {
                defer ctx.allocator.destroy(ctx);

                std.Thread.sleep(@as(u64, ctx.delay) * std.time.ns_per_ms);

                // Send the message (this copies it into the mailbox)
                // If successful, ownership is transferred to the mailbox.
                // If failed, we must deinit it.
                ctx.mailbox.send(ctx.msg) catch {
                    ctx.msg.deinit();
                };
            }
        }.run;

        const thread = try std.Thread.spawn(.{}, thread_fn, .{context});
        thread.detach();
    }
};

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
    std.Thread.sleep(50 * std.time.ns_per_ms);

    // Check mailbox
    var received = try mailbox.receive();
    defer received.deinit(); // We own the received message

    try std.testing.expectEqualStrings("timer_msg", received.id);
}
