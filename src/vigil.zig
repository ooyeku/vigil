//! Vigil - Process Supervision and Communication Library
//!
//! A robust framework for building reliable distributed systems with
//! process supervision, message passing, and monitoring capabilities.
//!
//! High-level API:
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
pub const testing = @import("api/testing.zig");
pub const flow_control = @import("api/flow_control.zig");
pub const request_reply = @import("api/request_reply.zig");
pub const runtime_api = @import("runtime.zig");

// New feature modules
pub const telemetry = @import("telemetry.zig");
pub const circuit_breaker = @import("circuit_breaker.zig");
pub const process_group = @import("process_group.zig");
pub const pubsub = @import("pubsub.zig");
pub const checkpoint = @import("checkpoint.zig");
pub const distributed_registry = @import("distributed_registry.zig");
pub const distributed_protocol = @import("distributed_protocol.zig");
pub const shutdown = @import("shutdown.zig");
pub const errors = @import("errors.zig");
pub const compat = @import("compat.zig");

// High-level API re-exports
pub const msg = msg_builder.msg;
pub const MessageBuilder = msg_builder.MessageBuilder;
pub const inbox = inbox_api.inbox;
pub const inboxBuilder = inbox_api.inboxBuilder;
pub const Inbox = inbox_api.Inbox;
pub const InboxBuilder = inbox_api.InboxBuilder;
pub const supervisor = supervisor_builder.supervisor;
pub const SupervisorBuilder = supervisor_builder.SupervisorBuilder;
pub const app = app_builder.app;
pub const appWithPreset = app_builder.appWithPreset;
pub const AppBuilder = app_builder.AppBuilder;
pub const server = server_sugar.server;
pub const Preset = presets.Preset;
pub const PresetConfig = presets.PresetConfig;
pub const Runtime = runtime_api.Runtime;
pub const RuntimeOptions = runtime_api.RuntimeOptions;
pub const runtime = runtime_api.runtime;

// Testing utilities
pub const TestContext = testing.TestContext;
pub const MockInbox = testing.MockInbox;
pub const MockSupervisor = testing.MockSupervisor;
pub const expectMessage = testing.expectMessage;
pub const expectSignal = testing.expectSignal;

// Flow control
pub const RateLimiter = flow_control.RateLimiter;
pub const BackpressureStrategy = flow_control.BackpressureStrategy;
pub const FlowControlledInbox = flow_control.FlowControlledInbox;

// Request/Reply
pub const request = request_reply.request;
pub const reply = request_reply.reply;

// Circuit breaker
pub const CircuitBreaker = circuit_breaker.CircuitBreaker;
pub const CircuitState = circuit_breaker.CircuitState;

// Process groups
pub const ProcessGroup = process_group.ProcessGroup;
pub const BroadcastResult = process_group.BroadcastResult;

// Pub/Sub
pub const publish = pubsub.publish;
pub const subscribe = pubsub.subscribe;
pub const Subscriber = pubsub.Subscriber;
pub const PublishResult = pubsub.PublishResult;

// Checkpointing
pub const Checkpointer = checkpoint.Checkpointer;
pub const FileCheckpointer = checkpoint.FileCheckpointer;
pub const MemoryCheckpointer = checkpoint.MemoryCheckpointer;

// Distributed registry
pub const DistributedRegistry = distributed_registry.DistributedRegistry;
pub const RemoteProcessInfo = distributed_registry.RemoteProcessInfo;

// Shutdown
pub const onShutdown = shutdown.onShutdown;
pub const shutdownAll = shutdown.shutdownAll;

// Errors
pub const VigilError = errors.VigilError;

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
pub const Registry = @import("registry.zig").Registry;
pub const Timer = @import("timer.zig").Timer;

/// Get library version information
pub fn getVersion() struct { major: u32, minor: u32, patch: u32 } {
    return .{
        .major = 2,
        .minor = 0,
        .patch = 0,
    };
}

test "v2 root module excludes obsolete 0.2 compatibility helpers" {
    try std.testing.expect(!@hasDecl(@This(), "createMailbox"));
    try std.testing.expect(!@hasDecl(@This(), "createSupervisor"));
    try std.testing.expect(!@hasDecl(@This(), "createSupervisionTree"));
    try std.testing.expect(!@hasDecl(@This(), "createResponse"));
    try std.testing.expect(!@hasDecl(@This(), "addWorkerGroup"));
    try std.testing.expect(!@hasDecl(@This(), "broadcast"));
    try std.testing.expect(!@hasDecl(@This(), "global_registry"));
}

test "v2 root module exports runtime and version" {
    try std.testing.expect(@hasDecl(@This(), "Runtime"));
    try std.testing.expect(@hasDecl(@This(), "RuntimeOptions"));
    try std.testing.expect(@hasDecl(@This(), "runtime"));
    try std.testing.expect(@hasDecl(@This(), "distributed_protocol"));

    const version = getVersion();
    try std.testing.expectEqual(@as(u32, 2), version.major);
    try std.testing.expectEqual(@as(u32, 0), version.minor);
    try std.testing.expectEqual(@as(u32, 0), version.patch);
}

test {
    std.testing.refAllDecls(@This());
}
