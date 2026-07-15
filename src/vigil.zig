//! Vigil - process supervision and communication for Zig.
//!
//! Vigil is a library for building resilient services with explicit
//! runtime ownership, message-passing inboxes, supervisors, telemetry,
//! flow control, pub/sub, process groups, circuit breakers, and
//! reliability policies, and checkpointing.
//!
//! The root package is library-only: it exports APIs and tests, but it
//! intentionally has no `main` function or `zig build run` step. Runnable
//! demos live under `examples/`.
//!
//! Prefer the v2 runtime API for new code. A `Runtime` owns a registry,
//! telemetry emitter, and shutdown manager so tests and applications can
//! create independent instances without global state:
//! ```zig
//! const vigil = @import("vigil");
//!
//! var rt = try vigil.runtime(allocator, .{});
//! defer rt.deinit();
//!
//! var inbox = try rt.inbox(.{ .capacity = 32 });
//! defer inbox.close();
//!
//! try rt.register("orders.inbox", inbox.mailbox);
//! try inbox.send("order-created");
//!
//! var msg = try inbox.recvTimeout(100) orelse return error.NoMessage;
//! defer msg.deinit();
//! ```
//!
//! A reduced set of deprecated 0.2.x type aliases remains temporarily in the
//! legacy module for migrations. Current code should not depend on it:
//! ```zig
//! const vigil_legacy = @import("vigil/legacy");
//! ```

const std = @import("std");
const messages = @import("messages.zig");
const genserver = @import("genserver.zig");
const build_options = @import("vigil_build_options");

/// Fluent message construction API. Most callers use the root `msg`
/// shortcut rather than importing this module directly.
pub const msg_builder = @import("api/msg_builder.zig");
/// High-level channel-like inbox API built on Vigil mailboxes.
pub const inbox_api = @import("api/inbox.zig");
/// Fluent supervisor configuration API.
pub const supervisor_builder = @import("api/supervisor_builder.zig");
/// Small server-construction conveniences.
pub const server_sugar = @import("api/server_sugar.zig");
/// Application-builder conveniences for worker and worker-pool apps.
pub const app_builder = @import("api/app_builder.zig");
/// Named configuration presets for development, production, HA, and tests.
pub const presets = @import("api/presets.zig");
/// Test doubles and assertions for inbox and supervisor behavior.
pub const testing = @import("api/testing.zig");
/// Rate limiting and backpressure primitives.
pub const flow_control = @import("api/flow_control.zig");
/// Request/reply helpers built around message correlation ids.
pub const request_reply = @import("api/request_reply.zig");
/// Runtime-owned registry, telemetry, shutdown, and factory helpers.
pub const runtime_api = @import("runtime.zig");
/// Retry, backoff, timeout, fallback, and circuit-breaker policy helpers.
pub const policy = @import("policy.zig");

/// Event emission and subscription primitives.
pub const telemetry = @import("telemetry.zig");
/// Bounded timeline of recent notable events.
pub const EventTimeline = telemetry.EventTimeline;
/// One retained event-timeline entry.
pub const TimelineEntry = telemetry.TimelineEntry;
/// Owned snapshot of retained event-timeline entries.
pub const TimelineSnapshot = telemetry.TimelineSnapshot;
/// Circuit breaker implementation for fail-fast dependency protection.
pub const circuit_breaker = @import("circuit_breaker.zig");
/// Process groups for broadcast, round-robin, and keyed routing.
pub const process_group = @import("process_group.zig");
/// Topic-based publish/subscribe messaging.
pub const pubsub = @import("pubsub.zig");
/// Persistent state checkpoint interfaces and implementations.
pub const checkpoint = @import("checkpoint.zig");
/// Cluster-aware name registry.
pub const distributed_registry = @import("distributed_registry.zig");
/// Wire protocol parser and frame writer for distributed nodes.
pub const distributed_protocol = @import("distributed_protocol.zig");
/// Shutdown hook manager. Prefer `Runtime.onShutdown` for new apps.
pub const shutdown = @import("shutdown.zig");
/// Common Vigil error set.
pub const errors = @import("errors.zig");
/// Portability shims used by Vigil and examples.
pub const compat = @import("compat.zig");

/// Start building an owned `Message` with a payload.
pub const msg = msg_builder.msg;
/// Fluent builder returned by `msg(payload)`.
pub const MessageBuilder = msg_builder.MessageBuilder;
/// Allocate a default inbox. Call `close()` exactly once when finished.
pub const inbox = inbox_api.inbox;
/// Start configuring an inbox with capacity, TTL, rate limit, and backpressure.
pub const inboxBuilder = inbox_api.inboxBuilder;
/// Channel-like wrapper around `ProcessMailbox`.
pub const Inbox = inbox_api.Inbox;
/// Fluent builder for `Inbox`.
pub const InboxBuilder = inbox_api.InboxBuilder;
/// Callback invoked when a failed message first becomes poison.
pub const PoisonMessageHandler = inbox_api.PoisonMessageHandler;
/// Start configuring a supervisor.
pub const supervisor = supervisor_builder.supervisor;
/// Fluent supervisor builder.
pub const SupervisorBuilder = supervisor_builder.SupervisorBuilder;
/// Create an application builder with the production preset.
pub const app = app_builder.app;
/// Create an application builder with an explicit preset.
pub const appWithPreset = app_builder.appWithPreset;
/// Builder for simple worker applications.
pub const AppBuilder = app_builder.AppBuilder;
/// Server-construction shortcut from `api/server_sugar.zig`.
pub const server = server_sugar.server;
/// Deployment presets used by app-builder APIs.
pub const Preset = presets.Preset;
/// Concrete values behind a `Preset`.
pub const PresetConfig = presets.PresetConfig;
/// Owned v2 runtime. Prefer this over global registries and shutdown hooks.
pub const Runtime = runtime_api.Runtime;
/// Runtime feature flags.
pub const RuntimeOptions = runtime_api.RuntimeOptions;
/// Runtime-owned inbox configuration.
pub const InboxOptions = runtime_api.InboxOptions;
/// Owned runtime-state snapshot for debugging and health reporting.
pub const RuntimeSnapshot = runtime_api.RuntimeSnapshot;
/// Compact runtime health/readiness summary.
pub const RuntimeHealth = runtime_api.RuntimeHealth;
/// Coarse runtime health state.
pub const RuntimeHealthStatus = runtime_api.RuntimeHealthStatus;
/// Create an owned runtime instance.
pub const runtime = runtime_api.runtime;

/// Test context with controlled time and helper factories.
pub const TestContext = testing.TestContext;
/// In-memory inbox test double.
pub const MockInbox = testing.MockInbox;
/// Supervisor test double.
pub const MockSupervisor = testing.MockSupervisor;
/// Assert that a mock inbox contains a matching message.
pub const expectMessage = testing.expectMessage;
/// Assert that a mock inbox contains a matching signal.
pub const expectSignal = testing.expectSignal;
/// Deterministic clock for tests and simulated runtimes.
pub const SimulatedClock = testing.SimulatedClock;
/// Deterministic timer service driven by a `SimulatedClock`.
pub const SimulatedTimerService = testing.SimulatedTimerService;
/// Scripted failure schedule used by `FaultInjector`.
pub const FaultPlan = testing.FaultPlan;
/// Deterministic fault-injection helper for dependency and policy tests.
pub const FaultInjector = testing.FaultInjector;
/// In-memory fake distributed registry for deterministic cluster tests.
pub const FakeDistributedRegistry = testing.FakeDistributedRegistry;

/// Token-bucket rate limiter.
pub const RateLimiter = flow_control.RateLimiter;
/// Strategy used when an inbox crosses its high-water mark.
pub const BackpressureStrategy = flow_control.BackpressureStrategy;
/// Wrapper that applies rate limiting/backpressure around an inbox.
pub const FlowControlledInbox = flow_control.FlowControlledInbox;
/// Lifetime counters for flow-control outcomes.
pub const FlowControlStats = flow_control.FlowControlStats;

/// Build a reply message that preserves the request correlation id.
pub const reply = request_reply.reply;
/// Reply mailbox for awaiting correlated responses.
pub const ReplyMailbox = request_reply.ReplyMailbox;
/// Value snapshot of reply-mailbox state.
pub const ReplyMailboxSnapshot = request_reply.ReplyMailboxSnapshot;

/// Fail-fast guard around unreliable dependencies.
pub const CircuitBreaker = circuit_breaker.CircuitBreaker;
/// Configuration for circuit breaker thresholds and recovery behavior.
pub const CircuitBreakerConfig = circuit_breaker.CircuitBreakerConfig;
/// Public state of a circuit breaker.
pub const CircuitState = circuit_breaker.CircuitState;
/// Value snapshot of circuit-breaker state.
pub const CircuitBreakerSnapshot = circuit_breaker.CircuitBreakerSnapshot;
/// Final outcome category for a policy-protected operation.
pub const PolicyOutcome = policy.PolicyOutcome;
/// Metadata returned for terminal policy outcomes.
pub const PolicyReport = policy.PolicyReport;
/// Failure details passed to fallback handlers and returned by failures.
pub const PolicyFailure = policy.PolicyFailure;
/// Retry policy for protected operations.
pub const RetryPolicy = policy.RetryPolicy;
/// Delay strategy used between retry attempts.
pub const BackoffPolicy = policy.BackoffPolicy;
/// Exponential backoff configuration.
pub const ExponentialBackoff = policy.ExponentialBackoff;
/// Deterministic jittered exponential backoff configuration.
pub const JitteredBackoff = policy.JitteredBackoff;
/// Generic options type factory for policy-protected operations.
pub const PolicyOptions = policy.PolicyOptions;
/// Generic result type factory for policy-protected operations.
pub const PolicyResult = policy.PolicyResult;
/// Execute a fallible operation under retry, timeout, fallback, and circuit rules.
pub const executePolicy = policy.execute;
/// Fail-fast isolation pool bounding concurrent access to a dependency.
pub const Bulkhead = policy.Bulkhead;
/// Configuration for a `Bulkhead` isolation pool.
pub const BulkheadConfig = policy.BulkheadConfig;
/// Value snapshot of bulkhead usage.
pub const BulkheadSnapshot = policy.BulkheadSnapshot;

/// Group of inboxes that can receive broadcast or routed messages.
pub const ProcessGroup = process_group.ProcessGroup;
/// Delivery counts from `ProcessGroup.broadcast`.
pub const BroadcastResult = process_group.BroadcastResult;
/// Owned snapshot of process-group membership.
pub const ProcessGroupSnapshot = process_group.ProcessGroupSnapshot;
/// Snapshot of one process-group member.
pub const ProcessGroupMemberSnapshot = process_group.ProcessGroupMemberSnapshot;

/// Topic-based pub/sub broker.
pub const PubSubBroker = pubsub.PubSubBroker;
/// Inbox-backed topic subscriber.
pub const Subscriber = pubsub.Subscriber;
/// Delivery counts from a pub/sub publish operation.
pub const PublishResult = pubsub.PublishResult;
/// Owned snapshot of broker subscribers.
pub const PubSubBrokerSnapshot = pubsub.PubSubBrokerSnapshot;
/// Snapshot of one pub/sub subscriber.
pub const SubscriberSnapshot = pubsub.SubscriberSnapshot;
/// Owned inspection of one subscriber including its topic patterns.
pub const SubscriberInspection = pubsub.SubscriberInspection;

/// Type-erased checkpoint persistence interface.
pub const Checkpointer = checkpoint.Checkpointer;
/// File-backed checkpoint persistence implementation.
pub const FileCheckpointer = checkpoint.FileCheckpointer;
/// In-memory checkpoint persistence implementation, useful in tests.
pub const MemoryCheckpointer = checkpoint.MemoryCheckpointer;

/// Registry that can resolve local and remote process names.
pub const DistributedRegistry = distributed_registry.DistributedRegistry;
/// Remote process resolution result.
pub const RemoteProcessInfo = distributed_registry.RemoteProcessInfo;
/// Owned snapshot of distributed-registry peer health and counters.
pub const DistributedRegistrySnapshot = distributed_registry.DistributedRegistrySnapshot;
/// Snapshot of one peer's health and connection state.
pub const PeerSnapshot = distributed_registry.PeerSnapshot;

/// Shared error set for high-level Vigil operations.
pub const VigilError = errors.VigilError;

/// Owned message type used by inboxes, request/reply, and supervisors.
pub const Message = msg_builder.Message;
/// Message priority used by mailboxes with priority queues enabled.
pub const MessagePriority = msg_builder.MessagePriority;
/// Lightweight process control signal attached to a message.
pub const Signal = msg_builder.Signal;
/// Why a message entered dead-letter storage.
pub const DeadLetterReason = messages.DeadLetterReason;
/// Scalar details for a dead-letter lifecycle event.
pub const DeadLetterNotice = messages.DeadLetterNotice;
/// One owned entry returned by dead-letter snapshots.
pub const DeadLetterEntry = messages.DeadLetterEntry;
/// Owned dead-letter inspection snapshot.
pub const DeadLetterSnapshot = messages.DeadLetterSnapshot;
/// Non-consuming snapshot of one queued message.
pub const QueuedMessageSnapshot = messages.QueuedMessageSnapshot;
/// Owned non-consuming snapshot of a mailbox's active queue.
pub const MailboxQueueSnapshot = messages.MailboxQueueSnapshot;
/// Replay outcome for a retained dead-letter entry.
pub const DeadLetterReplayResult = messages.DeadLetterReplayResult;
/// Replay status for a retained dead-letter entry.
pub const DeadLetterReplayStatus = messages.DeadLetterReplayStatus;

/// Low-level supervisor type re-exported for compatibility.
pub const Supervisor = supervisor_builder.Supervisor;
/// Owned snapshot of a supervisor and its supervised children.
pub const SupervisorSnapshot = Supervisor.SupervisorSnapshot;
/// Snapshot of one supervised child.
pub const SupervisorChildSnapshot = Supervisor.SupervisorChildSnapshot;
/// Restart strategy used by supervisors.
pub const RestartStrategy = supervisor_builder.RestartStrategy;
/// Process scheduling priority used by supervisor children.
pub const ProcessPriority = supervisor_builder.ProcessPriority;
/// Generic server abstraction.
pub const GenServer = genserver.GenServer;
/// Lower-level mailbox type. Prefer `Inbox` unless you need raw mailbox APIs.
pub const ProcessMailbox = messages.ProcessMailbox;
/// Thread-safe local process registry.
pub const Registry = @import("registry.zig").Registry;
/// Timer helper for delayed and periodic callbacks.
///
/// Spawns one thread per timer; prefer `TimerService` for new code.
pub const Timer = @import("timer.zig").Timer;
/// Value snapshot of timer state.
pub const TimerSnapshot = @import("timer.zig").TimerSnapshot;
/// Runtime-owned timer scheduler module.
pub const timer_service = @import("timer_service.zig");
/// Min-heap timer scheduler: timeouts, intervals, and delayed sends on one
/// thread. Prefer `Runtime.timers()` which owns the service lifecycle.
pub const TimerService = timer_service.TimerService;
/// Value snapshot of timer-service state.
pub const TimerServiceSnapshot = timer_service.TimerServiceSnapshot;

/// Return the semantic version of the public root API.
pub fn getVersion() struct { major: u32, minor: u32, patch: u32 } {
    return .{
        .major = @intCast(build_options.version.major),
        .minor = @intCast(build_options.version.minor),
        .patch = @intCast(build_options.version.patch),
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
    try std.testing.expect(!@hasDecl(@This(), "publish"));
    try std.testing.expect(!@hasDecl(@This(), "subscribe"));
    try std.testing.expect(!@hasDecl(@This(), "onShutdown"));
    try std.testing.expect(!@hasDecl(@This(), "shutdownAll"));
    try std.testing.expect(!@hasDecl(@This(), "request"));
    try std.testing.expect(!@hasDecl(@This(), "RequestOptions"));
}

test "v2 root module exports runtime and version" {
    try std.testing.expect(@hasDecl(@This(), "Runtime"));
    try std.testing.expect(@hasDecl(@This(), "RuntimeOptions"));
    try std.testing.expect(@hasDecl(@This(), "runtime"));
    try std.testing.expect(@hasDecl(@This(), "RuntimeSnapshot"));
    try std.testing.expect(@hasDecl(@This(), "RuntimeHealth"));
    try std.testing.expect(@hasDecl(@This(), "RuntimeHealthStatus"));
    try std.testing.expect(@hasDecl(@This(), "ProcessGroupSnapshot"));
    try std.testing.expect(@hasDecl(@This(), "PubSubBrokerSnapshot"));
    try std.testing.expect(@hasDecl(@This(), "CircuitBreakerSnapshot"));
    try std.testing.expect(@hasDecl(@This(), "TimerSnapshot"));
    try std.testing.expect(@hasDecl(@This(), "ReplyMailboxSnapshot"));
    try std.testing.expect(@hasDecl(@This(), "policy"));
    try std.testing.expect(@hasDecl(@This(), "PolicyOutcome"));
    try std.testing.expect(@hasDecl(@This(), "PolicyReport"));
    try std.testing.expect(@hasDecl(@This(), "PolicyFailure"));
    try std.testing.expect(@hasDecl(@This(), "RetryPolicy"));
    try std.testing.expect(@hasDecl(@This(), "BackoffPolicy"));
    try std.testing.expect(@hasDecl(@This(), "ExponentialBackoff"));
    try std.testing.expect(@hasDecl(@This(), "JitteredBackoff"));
    try std.testing.expect(@hasDecl(@This(), "PolicyOptions"));
    try std.testing.expect(@hasDecl(@This(), "PolicyResult"));
    try std.testing.expect(@hasDecl(@This(), "executePolicy"));
    try std.testing.expect(@hasDecl(@This(), "distributed_protocol"));
    try std.testing.expect(@hasDecl(@This(), "EventTimeline"));
    try std.testing.expect(@hasDecl(@This(), "TimelineEntry"));
    try std.testing.expect(@hasDecl(@This(), "TimelineSnapshot"));
    try std.testing.expect(@hasDecl(@This(), "SupervisorSnapshot"));
    try std.testing.expect(@hasDecl(@This(), "SupervisorChildSnapshot"));
    try std.testing.expect(@hasDecl(@This(), "QueuedMessageSnapshot"));
    try std.testing.expect(@hasDecl(@This(), "MailboxQueueSnapshot"));
    try std.testing.expect(@hasDecl(@This(), "SubscriberInspection"));
    try std.testing.expect(@hasDecl(@This(), "SimulatedClock"));
    try std.testing.expect(@hasDecl(@This(), "SimulatedTimerService"));
    try std.testing.expect(@hasDecl(@This(), "FaultPlan"));
    try std.testing.expect(@hasDecl(@This(), "FaultInjector"));
    try std.testing.expect(@hasDecl(@This(), "FakeDistributedRegistry"));
    try std.testing.expect(@hasDecl(@This(), "Bulkhead"));
    try std.testing.expect(@hasDecl(@This(), "BulkheadConfig"));
    try std.testing.expect(@hasDecl(@This(), "BulkheadSnapshot"));

    const version = getVersion();
    try std.testing.expectEqual(@as(u32, @intCast(build_options.version.major)), version.major);
    try std.testing.expectEqual(@as(u32, @intCast(build_options.version.minor)), version.minor);
    try std.testing.expectEqual(@as(u32, @intCast(build_options.version.patch)), version.patch);
}

test "library root has no runnable entrypoint" {
    try std.testing.expect(!@hasDecl(@This(), "main"));
}

test {
    std.testing.refAllDecls(@This());
}
