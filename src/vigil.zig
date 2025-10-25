//! Vigil 0.3.0+ - Process Supervision and Communication Library
//!
//! A robust framework for building reliable distributed systems with
//! process supervision, message passing, and monitoring capabilities.
//!
//! New high-level API for 0.3.0+:
//! ```zig
//! const vigil = @import("vigil");
//!
//! // Simple worker app
//! var app = try vigil.app(allocator)
//!     .worker("worker1", myWorkerFn)
//!     .workerPool("pool", poolWorkerFn, 4)
//!     .build();
//! defer app.shutdown();
//! try app.start();
//! ```
//!
//! For low-level APIs (0.2.x functionality), use:
//! ```zig
//! const vigil_legacy = @import("vigil/legacy");
//! ```

const std = @import("std");
const legacy = @import("legacy.zig");

// High-level API modules
pub const msg_builder = @import("api/msg_builder.zig");
pub const inbox_api = @import("api/inbox.zig");
pub const supervisor_builder = @import("api/supervisor_builder.zig");
pub const server_sugar = @import("api/server_sugar.zig");
pub const app_builder = @import("api/app_builder.zig");
pub const presets = @import("api/presets.zig");

// High-level API re-exports
pub const msg = msg_builder.msg;
pub const MessageBuilder = msg_builder.MessageBuilder;
pub const inbox = inbox_api.inbox;
pub const Inbox = inbox_api.Inbox;
pub const supervisor = supervisor_builder.supervisor;
pub const SupervisorBuilder = supervisor_builder.SupervisorBuilder;
pub const app = app_builder.app;
pub const appWithPreset = app_builder.appWithPreset;
pub const AppBuilder = app_builder.AppBuilder;
pub const server = server_sugar.server;
pub const Preset = presets.Preset;
pub const PresetConfig = presets.PresetConfig;

// Message and base types from high-level API
pub const Message = msg_builder.Message;
pub const MessagePriority = msg_builder.MessagePriority;
pub const Signal = msg_builder.Signal;

// Re-export common low-level types for convenience and backward compatibility
pub const Supervisor = supervisor_builder.Supervisor;
pub const RestartStrategy = supervisor_builder.RestartStrategy;
pub const ProcessPriority = supervisor_builder.ProcessPriority;
pub const GenServer = legacy.GenServer;
pub const ProcessMailbox = legacy.ProcessMailbox;

// Additional legacy exports for backward compatibility
pub const SupervisorOptions = legacy.SupervisorOptions;
pub const SupervisorTree = legacy.SupervisorTree;
pub const ChildSpec = legacy.ChildSpec;
pub const createMailbox = compat_0_2.createMailbox;
pub const createSupervisor = compat_0_2.createSupervisor;
pub const createSupervisionTree = compat_0_2.createSupervisionTree;
pub const broadcast = compat_0_2.broadcast;
pub const createResponse = compat_0_2.createResponse;
pub const addWorkerGroup = compat_0_2.addWorkerGroup;

const compat_0_2 = @import("compat_0_2.zig");

/// Get library version information
pub fn getVersion() struct { major: u32, minor: u32, patch: u32 } {
    return .{
        .major = 0,
        .minor = 3,
        .patch = 0,
    };
}

test {
    std.testing.refAllDecls(@This());
}
