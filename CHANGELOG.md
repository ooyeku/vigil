# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.2.0] - 2026-07-15

### Added
- **Composable reliability policies**: Added typed retry policies with fixed, exponential, and deterministic jittered backoff, synchronous timeout classification, fallback handlers, circuit-breaker composition, and injectable clock/sleep hooks through `vigil.executePolicy()`.
- **Dead-letter lifecycle APIs**: Added bounded dead-letter entries with stable ids, owned inspection snapshots, replay, single/all discard, explicit reasons, and poison-message attempt limits across `ProcessMailbox` and `Inbox`.
- **Dead-letter observability**: Runtime snapshots and health now expose retained dead-letter and poison counts, while runtime-created inboxes emit dead-letter, replay, discard, and poison telemetry events.
- **Poison-message hooks**: Added `Inbox.onPoisonMessage()` for application handling when a repeatedly rejected message first crosses its configured attempt threshold.
- **Bulkhead isolation pools**: Added `vigil.Bulkhead`, a fail-fast concurrency pool with `acquire`/`release`/`run` and a usage snapshot, completing the v2.2 reliability-policy set.
- **Debug-layer introspection**: Added non-consuming queue inspection (`Inbox.peekMessages()`, `ProcessMailbox.snapshotQueue()`), owned supervision-tree snapshots (`Supervisor.snapshot()`), process-group route previews (`routeIndexForKey()`, `routeMemberForKey()`), pub/sub subscription inspection with copied patterns, and circuit-breaker diagnostics (last transition time, open transitions, lifetime failure/success totals).
- **Runtime event timeline and debug dumps**: Added `vigil.EventTimeline`, a bounded thread-safe buffer of recent telemetry events attachable to any emitter, plus `Runtime.enableTimeline()`, `Runtime.timelineSnapshot()`, and `Runtime.debugDump()` for one-call human-readable runtime state.
- **Deterministic testing and simulation**: Added `SimulatedClock`, `SimulatedTimerService` (synchronous deadline-ordered timers with no threads), `FaultInjector` with scripted failure plans, `FakeDistributedRegistry` with peer partition/reconnect simulation, and `testing.fillInbox()`/`testing.drainInbox()` failure-mode helpers.
- **Routing and protocol property tests**: Added deterministic fuzz tests for distributed protocol parsing and round-tripping, plus property tests for pub/sub wildcard matching and stable keyed process-group routing.
- **Operations toolkit example**: Added `examples/ops_toolkit` with five runnable demos: resilient job queue, retry/backoff dependency client, dead-letter replay workflow, runtime introspection endpoint, and checkpointed state machine with crash recovery.

### Changed
- **v2.2 release version**: Advanced `build.zig.zon` to `2.2.0`, the roadmap's Operate and Recover release.
- **Mailbox capacity is global**: Priority mailboxes now enforce configured capacity across all priority queues, matching `queuedCount()`, `hasCapacity()`, and runtime health semantics.
- **Delivery attempts are tracked**: Successful mailbox receives increment `Message.metadata.attempt_count`; replay renews the message TTL window.
- **Legacy isolation**: Current root and high-level APIs now import concrete modules directly; `vigil/legacy` is a reduced compatibility boundary instead of an internal dependency.
- **Pub/sub broker snapshots include subscriptions**: `PubSubBrokerSnapshot` entries are now `SubscriberInspection` values carrying owned copies of each subscriber's topic patterns instead of a bare pattern count.

### Fixed
- **Dead-letter accounting and callbacks**: Retained overflow is no longer counted as dropped, poison counts are constant-time and current, and lifecycle callbacks may safely close their inbox.
- **Flow-control drops**: `drop_newest` now actually skips the send, `drop_oldest` updates drop statistics without pretending to deliver, and blocking backpressure observes inbox shutdown.
- **Flow-control thresholds**: Backpressure now uses actual queue depth, blocking resumes below the low-water mark, and impossible threshold combinations are rejected instead of hanging producers.
- **Inbox shutdown admission**: Closing an inbox and registering an operation now share one atomic lifecycle word, removing the remaining reference-count acquisition race; flow-control queue inspection participates in the same shutdown protocol.
- **Message identity and TTL precision**: High-level messages use allocation-free monotonic ids, `MessageBuilder` no longer leaks its temporary id, and TTL timestamps now use millisecond precision.
- **Message metadata accounting**: Replacing correlation and reply-to metadata updates recorded size, so mailbox limits cannot be bypassed after creation; long-lived counters now saturate instead of wrapping.
- **GenServer ownership and concurrency**: Correlation ids are unique, server lifecycle state is atomic, stopped servers reject casts and calls, checkpoint replacement is transactional, timeout/error cleanup no longer double-frees reply resources, replies cannot race mailbox destruction, and supervised servers no longer share one global start context.
- **Process and supervisor lifecycle**: Fast completion can no longer race startup state, completed thread handles are reaped, timeout-detached workers cannot access destroyed process state, terminate and reentrant callbacks avoid mutex deadlocks, partial startup rolls back, monitoring can restart, and uptime is elapsed monotonic time.
- **Timeout and timer boundaries**: Zero-duration reply waits perform one nonblocking poll, shutdown deadlines use exact monotonic boundaries, one-shot timers report completion, and zero-length intervals are rejected instead of busy-looping.
- **Circuit-breaker safety**: Invalid half-open configurations are rejected, counters saturate, reset deadlines use monotonic time, and telemetry callbacks run outside the breaker lock so handlers may inspect it safely.
- **Checkpoint reliability**: File checkpoints use Zig 0.16 filesystem APIs, initialization surfaces invalid paths, checkpoint ids cannot escape the base directory, and failed in-memory replacement preserves the previous value.
- **Distributed registry robustness**: Protocol frames validate arity and names, fragmented TCP frames are read through their newline, invalid peer/configuration values are rejected, partial failures roll back, and sync listener start/stop is race-safe.
- **Routing correctness**: Pub/sub wildcards follow segment semantics, duplicate broker registration is idempotent, failed pattern batches roll back, process groups reject duplicate ids, removal preserves round-robin bounds, and long routing keys cannot overflow in Debug builds.
- **Allocation failure safety**: Distributed registries, checkpoint replacement, subscriber pattern batches, and test doubles retain valid prior state when allocation fails.
- **Builder cleanup**: Failed duplicate child registration no longer leaves freed ids in cleanup lists, and `AppBuilder.stop()` can safely be followed by `shutdown()`.
- **Deterministic cancellation tests**: Timer cancellation now joins its worker before returning, and the supervisor lifecycle test uses an explicit worker gate instead of timing assumptions.
- **Optimized benchmark smoke tests**: ReleaseSafe tests no longer assume every operation takes at least one nanosecond after integer averaging.

### Removed
- **Obsolete legacy subsystems**: Removed the unused worker state, legacy configuration, supervision-tree, and stale standalone verification-test sources and exports.
- **Unused compatibility surface**: Removed global pub/sub and shutdown APIs, the broken unused one-inbox `request()` helper, no-op builder destructors, empty option/error types, redundant count aliases, incomplete supervisor scaling/history methods, and unused detailed telemetry constructors.

## [2.1.0] - 2026-06-28

### Added
- **Runtime snapshots and health**: Added owned runtime snapshots, compact readiness summaries, registered inbox queue statistics, and circuit-breaker-aware health checks.
- **Component introspection**: Added snapshots for registries, inboxes, process groups, pub/sub brokers, circuit breakers, timers, reply mailboxes, telemetry handlers, and shutdown hooks.
- **Benchmark harness**: Added a standalone benchmark package covering messaging, registries, telemetry, timers, process groups, pub/sub, request/reply, contention, throughput, latency, and observed allocations.
- **Operational server status**: Expanded the TCP server example with runtime-owned services and health/status reporting.

### Changed
- **Library-only root package**: Kept runnable examples and benchmarks in their own packages while the repository root focuses on the public library and its tests.

## [2.0.0] - 2026-06-13

### Added
- **Owned Runtime facade**: Added `vigil.Runtime`, `vigil.RuntimeOptions`, and `vigil.runtime()` to own registry, telemetry, shutdown hooks, inbox creation, and supervisor creation from one explicit runtime value.
- **Explicit server sugar lifecycle**: `vigil.server(...)` now exposes `init()` for allocation and `spawn()` for a running server handle with `cast`, `call`, `stop`, `join`, and `deinit`.
- **Documented timer instance API**: `vigil.Timer` now supports `init`, `deinit`, `setTimeout`, `setInterval`, and `cancel`, while preserving `sendAfter` for delayed mailbox delivery.
- **Versioned distributed registry protocol**: Distributed registry commands now use `VIGIL/2` frames with parser/formatter coverage in `distributed_protocol.zig`.

### Changed
- **Inbox builder options are real**: `InboxBuilder.withRateLimit()` and `withBackpressure()` now affect the built inbox instead of only storing unused config.
- **Supervisor builder hooks are real**: `SupervisorBuilder.onCrash()` and `withTelemetry()` now flow into supervisor options and monitored restart behavior.
- **GenServer registration is explicit**: `GenServer.register()` now takes a `*vigil.Registry`, removing hidden dependency on root global registry state.
- **Docs and examples are v2-first**: README and API docs now show runtime-owned services, `vigil.compat.sleep`, the explicit GenServer registry contract, and the `VIGIL/2` distributed protocol.

### Removed
- **Obsolete 0.2 root helpers**: Removed root exports for `createMailbox`, `createSupervisor`, `createSupervisionTree`, `createResponse`, `addWorkerGroup`, and root `broadcast`.
- **Root global registry**: Removed `vigil.global_registry`; use `vigil.Runtime` or an explicit `vigil.Registry`.
- **Compatibility shim source**: Removed `src/compat_0_2.zig`. Historical low-level types remain available through explicit `vigil/legacy` import where appropriate.

## [1.3.0] - 2026-04-18

### Changed
- **Zig 0.16 compatibility**: Minimum required Zig version bumped from `0.15.1` to `0.16.0`. The project no longer compiles on 0.15.x. `build.zig.zon`, `README.md`, and `docs/api.md` all updated to reflect the new requirement.
- **Mutex primitives migrated off `std.Thread`**: Zig 0.16 moved `std.Thread.Mutex`/`Condition`/etc. under `std.Io`, where lock/unlock now require an `Io` instance. Introduced `src/compat.zig` exposing a thin `compat.Mutex` that wraps `std.Io.Mutex` and drives it via `std.Io.Threaded.mutexLock`/`mutexUnlock` (futex-direct, no VTable). All internal `std.Thread.Mutex` fields across `circuit_breaker`, `worker`, `shutdown`, `genserver`, `api/testing`, `api/request_reply`, `api/flow_control`, `sup_tree`, `process`, `messages`, `pubsub`, `telemetry`, `registry`, `process_group`, `supervisor`, and `distributed_registry` now use `compat.Mutex`.
- **Time primitives migrated to `compat`**: `std.time.milliTimestamp`/`timestamp`/`nanoTimestamp` and `std.Thread.sleep` were removed in 0.16. `compat.zig` now provides `compat.milliTimestamp`, `compat.timestamp`, `compat.nanoTimestamp`, and `compat.sleep` implemented directly on `std.posix.system.clock_gettime` and `std.c.nanosleep`. All call sites have been switched over.
- **Networking shim replaces `std.net`**: `std.net` (and `std.posix.socket`/`connect`/`bind`/`listen`/`accept`/`close`/`write`) were removed in 0.16 in favor of `std.Io.net`, which requires an `Io` handle. Added `compat.net` (`Ip4Address`, `parseIp4`, `Stream`, `Server`) and `compat.sockets` (thin wrappers over `std.c.socket`/`connect`/`bind`/`listen`/`accept`/`close`/`write`/`read`). `distributed_registry.zig` and the `vigilant_server` example now build against this shim.
- **`std.ArrayList` init idioms updated**: 0.16 deprecated `std.ArrayListUnmanaged` in favor of the new unmanaged-by-default `std.ArrayList`. Empty-literal initializers (`.{}`, `std.ArrayList(T){}`) were replaced with `.empty` throughout. Managed-variant call sites (`std.ArrayList([]const u8).init(allocator)` → `.empty` + pass allocator to `deinit`) were updated too.
- **`std.heap.GeneralPurposeAllocator` → `std.heap.DebugAllocator`**: The allocator was renamed; `README.md` and `examples/vigilant_server/src/main.zig` now use `std.heap.DebugAllocator(.{}) = .init`.
- **`std.StringArrayHashMap` removed**: Only `StringArrayHashMapUnmanaged` exists in 0.16. `DistributedRegistry.global_names` switched to `StringArrayHashMapUnmanaged` with explicit allocator passing on `put`/`deinit`.
- **Signal handler signature**: macOS signal handlers now receive `std.c.SIG` (the enum) rather than `c_int`. The Ctrl+C handler in the `vigilant_server` example was updated.

### Added
- **`src/compat.zig` module**: Centralized Zig 0.15→0.16 compatibility layer exposing `Mutex`, `sleep`, `milliTimestamp`, `timestamp`, `nanoTimestamp`, a minimal `net` submodule (`Ip4Address`, `parseIp4`, `Stream`, `Server`), and a `sockets` submodule (`socket`, `connect`, `bind`, `listen`, `accept`, `close`).
- **`vigil.compat` re-export**: The compat layer is exposed through the public module so downstream examples and users of the `vigil` module can reach `vigil.compat.sleep`, `vigil.compat.milliTimestamp`, `vigil.compat.net.*`, etc. without reaching into library internals.

### Fixed
- **`ReplyMailbox` on 0.16**: `std.Thread.ResetEvent` was removed. The type was already tracked in `correlation_map` purely for the correlation-id lifecycle (the actual reply wait is polling-based on the inbox), so it's now a no-op local struct in `api/request_reply.zig`. No behavior change.

## [1.2.0] - 2026-03-13

### Fixed
- **GenServer `call()` broken**: `call()` previously polled the server's own mailbox for replies, competing with the `start()` message loop and causing responses to be lost. `call()` now creates a dedicated reply mailbox per request. Handlers use the new `self.reply(msg, payload)` method to send responses to the correct caller.
- **GenServer `current_context` data race**: Replaced the unsafe `@atomicStore`/`@atomicLoad` on a non-atomic `?*anyopaque` field with `std.atomic.Value(?*anyopaque)` for correct cross-thread access in supervised start functions.
- **DistributedRegistry `should_sync` data race**: Replaced the plain `bool` field (read/written across threads) with `std.atomic.Value(bool)`, matching the pattern used in `Inbox.closed`.

### Added
- **GenServer `reply()` method**: New `self.reply(msg, payload)` method for use within message handlers to respond to synchronous `call()` requests. Sends the response to the caller's dedicated reply mailbox using the message's correlation ID.
- **GenServer `deinit()` method**: Explicit resource cleanup method. `start()` and `stop()` no longer self-destruct the server; callers must call `deinit()` after stopping and joining the server thread. This eliminates use-after-free races between `call()` and server shutdown.
- **GenServer state checkpointing**: New `setCheckpointer(ckpt, id, interval_ms, fns)` method wires the existing `Checkpointer` interface into GenServer. State is auto-saved at a configurable interval during the message loop and on clean shutdown. Existing checkpoints are auto-restored on `setCheckpointer()` call. Users provide `serialize`/`deserialize` callbacks via the new `CheckpointFns` struct.
- **DistributedRegistry TCP protocol**: The previously-stubbed network layer now uses a TCP-based text protocol (`HEART`, `WHERE <name>`, `REG <name>`) for inter-node communication. `startSync()` launches both a listener thread (handles incoming queries) and a sync thread (heartbeats + registration propagation).
- **`RemoteProcessInfo` struct** (`distributed_registry.zig`): Describes a process on a remote node with `name`, `node_address`, and `node_port` fields.
- **`whereisGlobal()` method** (`DistributedRegistry`): Checks both local registry and remote registration cache, returns `?RemoteProcessInfo`.
- **`queryPeers()` method** (`DistributedRegistry`): Actively queries all peer nodes via TCP for a given name and updates the remote cache on success.
- **`listen_port` config field** (`DistributedRegistryConfig`): Configures the TCP port for the registry listener (default 9100).
- **`RemoteProcessInfo` re-export** (`vigil.zig`): Available as `vigil.RemoteProcessInfo`.

### Changed
- **GenServer lifecycle**: `start()` no longer destroys `self` on exit. `stop()` no longer destroys `self` for `.initial` state. Callers must now call `server.stop()`, join the server thread, then call `server.deinit()`. This is a **breaking change** from 1.1.0.
- **GenServer message ownership**: Messages received by the handler are now always freed after the handler returns, regardless of whether `correlation_id` is set. Handlers should not store references to message fields beyond handler scope.
- **Version bumped** from 1.1.0 to 1.2.0 in `build.zig.zon`, `vigil.getVersion()`, `README.md`, and `docs/api.md`.

## [1.1.0] - 2026-02-18

### Fixed
- **PubSub silent message drops**: `PubSubBroker.publish()` no longer silently swallows delivery failures. It now returns a `PublishResult` struct reporting `delivered` and `failed` counts, and emits `message_dropped` telemetry events for each failed delivery.
- **ProcessGroup broadcast silent drops**: `ProcessGroup.broadcast()` no longer silently swallows delivery failures. It now returns a `BroadcastResult` struct reporting `delivered` and `failed` counts, and emits `message_dropped` telemetry events for each failed delivery.
- **Request/Reply message loss**: `ReplyMailbox.waitForReply()` no longer discards messages with non-matching correlation IDs. Non-matching messages are now stashed in an internal buffer and re-queued to the inbox when the wait completes (on match, timeout, or error).
- **Wrong error for rate limiting**: `FlowControlledInbox.send()` now returns `MessageError.RateLimitExceeded` instead of the semantically incorrect `MessageError.MessageTooLarge` when a send is rejected by the rate limiter.
- **Inbox.close() race condition (TOCTOU)**: Replaced the unsafe 10ms sleep-and-hope strategy with an atomic reference count (`active_ops`). Every in-flight `send`, `recv`, and `recvTimeout` operation increments the count while accessing the mailbox. `close()` now spins until all in-flight operations have completed before deallocating, eliminating the use-after-free window.

### Added
- **`PublishResult` struct** (`pubsub.zig`): Reports `delivered` and `failed` counts from `PubSubBroker.publish()`.
- **`BroadcastResult` struct** (`process_group.zig`): Reports `delivered` and `failed` counts from `ProcessGroup.broadcast()`.
- **`MessageError.RateLimitExceeded`**: New error variant for rate limiter rejections.
- **`MessageError.DeliveryFailed`**: New error variant for subscriber delivery failures.
- **`deinitGlobal()` functions**: Added to `pubsub`, `shutdown`, and `telemetry` modules for safe teardown of global singleton state. Each function deinitializes resources under the module-level mutex and sets the global to `null`.
- **Safety documentation for `getGlobal()` functions**: All global accessor functions in `pubsub`, `shutdown`, and `telemetry` now document the pointer-lifetime contract — callers must ensure `deinitGlobal()` is only called during shutdown after all operations have completed.
- **`RateLimitExceeded` and `DeliveryFailed`** added to `VigilError` in `errors.zig`.

### Changed
- **`PubSubBroker.publish()` return type**: Changed from `!void` to `!PublishResult`.
- **Module-level `pubsub.publish()` return type**: Changed from `!void` to `!?PublishResult` (returns `null` when no global broker is initialized).
- **`ProcessGroup.broadcast()` return type**: Changed from `!void` to `!BroadcastResult`.
- **`ProcessGroup.count()` deprecated**: Aliased to `memberCount()` to remove the duplicate method.
- **Version bumped** from 1.0.1 to 1.1.0 in `build.zig.zon` and `vigil.getVersion()`.

## [1.0.1] - 2025-12-07

### Fixed
- **Memory Leak in Inbox.send()**: Fixed memory leak in `src/api/inbox.zig` where `Inbox.send()` was using `std.fmt.allocPrint()` to create dynamic message IDs that were never freed. Changed to use static string `"inbox_msg"` since `Message.init()` duplicates all strings internally.

## [1.0.0] 

### Added
- Initial release of Vigil, a high-performance actor system for Zig
- Core actor system with supervision trees
- Process mailboxes with priority queues and dead letter queues
- High-level inbox API for channel-like message passing
- Timer utilities for scheduling
- Registry for process discovery
- Flow control mechanisms with rate limiting and backpressure
- Comprehensive test suite and examples

### Changed
- N/A (initial release)

### Deprecated
- N/A (initial release)

### Removed
- N/A (initial release)

### Fixed
- N/A (initial release)

### Security
- N/A (initial release)
