const std = @import("std");
pub const Supervisor = @import("supervisor.zig").Supervisor;
pub const SupervisorOptions = @import("supervisor.zig").SupervisorOptions;
pub const Process = @import("process.zig").ChildProcess;
pub const ProcessState = @import("process.zig").ProcessState;
pub const ProcessError = @import("process.zig").ProcessError;
pub const ChildSpec = @import("process.zig").ChildSpec;
pub const ProcessMailbox = @import("messages.zig").ProcessMailbox;
pub const Message = @import("messages.zig").Message;
pub const MessagePriority = @import("messages.zig").MessagePriority;
pub const Signal = @import("messages.zig").Signal;
pub const MessageMetadata = @import("messages.zig").MessageMetadata;

test "vigil" {
    _ = @import("process.zig");
    _ = @import("messages.zig");
    _ = @import("supervisor.zig");
    _ = @import("sup_tree.zig");
}

test "initialize mailbox" {
    const allocator = std.testing.allocator;
    var mailbox = ProcessMailbox.init(allocator, .{
        .capacity = 10,
        .max_message_size = 1024 * 1024 * 10,
        .default_ttl_ms = 1000,
        .priority_queues = true,
        .enable_deadletter = true,
    });
    defer mailbox.deinit();
}
