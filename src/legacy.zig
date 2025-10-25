//! Legacy (0.2.x) low-level API module.
//! This module re-exports all the original vigil modules for advanced use.
//! For new code, use the high-level API from @import("vigil").
//! For advanced/specialized use, access low-level APIs here.

pub const ProcessMod = @import("process.zig");
pub const MessageMod = @import("messages.zig");
pub const SupervisorMod = @import("supervisor.zig");
pub const SupervisorTreeMod = @import("sup_tree.zig");
pub const WorkerMod = @import("worker.zig");
pub const GenServerMod = @import("genserver.zig");
pub const ConfigMod = @import("config.zig");

// Core components
pub const ProcessStats = ProcessMod.ProcessStats;
pub const ProcessResult = ProcessMod.ProcessResult;
pub const ChildSpec = ProcessMod.ChildSpec;
pub const SupervisorStats = SupervisorMod.SupervisorStats;
pub const Supervisor = SupervisorMod.Supervisor;
pub const SupervisorTree = SupervisorTreeMod.SupervisorTree;
pub const TreeStats = SupervisorTreeMod.TreeStats;
pub const GenServer = GenServerMod.GenServer;
pub const Message = MessageMod.Message;
pub const ProcessMailbox = MessageMod.ProcessMailbox;
pub const MessageMetadata = MessageMod.MessageMetadata;

// Configuration types
pub const SupervisorOptions = SupervisorMod.SupervisorOptions;
pub const TreeConfig = SupervisorTreeMod.TreeConfig;
pub const MailboxConfig = MessageMod.MailboxConfig;
pub const MailboxStats = MessageMod.ProcessMailbox.MailboxStats;

// Enums and error sets
pub const ProcessError = ProcessMod.ProcessError;
pub const ProcessState = ProcessMod.ProcessState;
pub const ProcessSignal = ProcessMod.ProcessSignal;
pub const ProcessPriority = ProcessMod.ProcessPriority;
pub const SupervisorError = SupervisorMod.SupervisorError;
pub const SupervisorState = SupervisorMod.SupervisorState;
pub const SupervisorTreeError = SupervisorTreeMod.SupervisorTreeError;
pub const RestartStrategy = SupervisorMod.RestartStrategy;
pub const MessagePriority = MessageMod.MessagePriority;
pub const Signal = MessageMod.Signal;
pub const MessageError = MessageMod.MessageError;
