//! Deprecated 0.2.x compatibility types.
//!
//! Current Vigil code does not depend on this module. New applications should
//! import `vigil` and use `Runtime`, `Inbox`, `Supervisor`, and `GenServer`.

const std = @import("std");
const process = @import("process.zig");
const messages = @import("messages.zig");
const supervisor = @import("supervisor.zig");
const genserver = @import("genserver.zig");

// Core components
pub const ProcessStats = process.ProcessStats;
pub const ProcessResult = process.ProcessResult;
pub const ChildSpec = process.ChildSpec;
pub const SupervisorStats = supervisor.SupervisorStats;
pub const Supervisor = supervisor.Supervisor;
pub const GenServer = genserver.GenServer;
pub const Message = messages.Message;
pub const ProcessMailbox = messages.ProcessMailbox;
pub const MessageMetadata = messages.MessageMetadata;

// Configuration types
pub const SupervisorOptions = supervisor.SupervisorOptions;
pub const MailboxConfig = messages.MailboxConfig;
pub const MailboxStats = messages.ProcessMailbox.MailboxStats;

// Enums and error sets
pub const ProcessError = process.ProcessError;
pub const ProcessState = process.ProcessState;
pub const ProcessSignal = process.ProcessSignal;
pub const ProcessPriority = process.ProcessPriority;
pub const SupervisorError = supervisor.SupervisorError;
pub const SupervisorState = supervisor.SupervisorState;
pub const RestartStrategy = supervisor.RestartStrategy;
pub const MessagePriority = messages.MessagePriority;
pub const Signal = messages.Signal;
pub const MessageError = messages.MessageError;

test "legacy module is reduced to compatibility type aliases" {
    std.testing.refAllDecls(@This());
    try std.testing.expect(!@hasDecl(@This(), "WorkerMod"));
    try std.testing.expect(!@hasDecl(@This(), "ConfigMod"));
    try std.testing.expect(!@hasDecl(@This(), "SupervisorTree"));
    try std.testing.expect(!@hasDecl(@This(), "TreeConfig"));
}
