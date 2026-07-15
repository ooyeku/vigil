# Vigil Roadmap

Vigil v2.0.0 has shipped. The next arc should turn Vigil from a reliable
actor-style Zig library into a serious high-performance production runtime.

The goal is not just "make it faster." The goal is to make Vigil:

- performant under real load,
- reliable when dependencies, workers, and queues fail,
- debuggable when a live system behaves unexpectedly,
- measurable enough that improvements are proven,
- cohesive enough that the runtime feels like one system instead of a bag of
  useful primitives.

This roadmap stages that work across v2.1.0, v2.2.0, v2.3.0, and v3.0.0.
Each minor release should be serviceable on its own while clearly moving toward
the v3.0.0 production-runtime moment.

Current status:

- v2.1.0 shipped the measurement and first runtime-introspection foundation.
- v2.2.0 has started with first-class reliability policies for retry, backoff,
  timeout classification, fallback, bulkhead isolation, and circuit-breaker
  composition.
- v2.2.0 now includes bounded dead-letter inspection, replay, discard,
  poison-message limits, lifecycle telemetry, and runtime health integration.
- v2.2.0 now includes the debug-layer introspection surface: structured debug
  dumps, supervision-tree snapshots, non-consuming inbox inspection, route
  table and subscription inspection, circuit-breaker diagnostics, and the
  runtime event timeline.
- v2.2.0 now includes deterministic testing support (simulated clock and
  timers, fault injection, fake distributed registry, full-queue and
  slow-consumer helpers) plus property/fuzz tests for routing and protocol
  parsing, and the `examples/ops_toolkit` operational examples.
- v2.2.0 has shipped.
- v2.3.0 has shipped: ring-buffer mailboxes with lazy expiry and condition
  wakeups, single-allocation messages, the runtime timer service, batch and
  nonblocking messaging, allocation-free telemetry, precompiled pub/sub
  fanout, the sharded registry, lock-free adaptive flow control, persistent
  distributed peer connections with metrics, the async versioned checkpoint
  pipeline, and safe/balanced/throughput runtime profiles. Messaging
  throughput improved ~70x and timer scheduling ~37x over the v2.2.1
  baselines; see `benchmarks/vigil_bench/README.md`. The next arc is the
  v3.0.0 Stabilize And Integrate release.

## Product Direction

By v3.0.0, Vigil should be easy to describe:

> Vigil is a high-performance, observable, fault-tolerant runtime for building
> resilient Zig services with supervised workers, message passing, flow control,
> telemetry, runtime introspection, and production reliability patterns.

## Release Strategy

### v2.1.0: Measure And Inspect

Make Vigil measurable and introduce the first runtime introspection surface.
This release should answer: "What is my Vigil system doing?"

### v2.2.0: Operate And Recover

Add production reliability patterns and richer debugging tools. This release
should answer: "What happens when something fails, slows down, or overloads?"

### v2.3.0: Scale The Runtime

Land the major performance, concurrency, scheduler, fanout, distributed, and
stateful-system improvements. This release should answer: "Can Vigil handle
serious production load?"

### v3.0.0: Stabilize And Integrate

Harden the full system, settle the API, validate behavior under stress, and make
the pieces feel cohesive. This release should answer: "Is Vigil ready to be a
production runtime foundation?"

## Guiding Principles

- Measure before optimizing.
- Prefer safe defaults with explicit fast paths.
- Make runtime state inspectable.
- Make failure behavior intentional and documented.
- Keep ownership and allocation behavior visible.
- Preserve the v2 runtime ownership model.
- Make every feature testable in isolation and observable in a running system.
- Use v3.0.0 for cohesion, stability, and release confidence, not a large new
  feature pile.

## v2.1.0: Measure And Inspect

Status: shipped.

v2.1.0 should create the measurement and introspection foundation needed for all
later work. It should be useful even before the hot paths are rewritten.

### Performance Measurement

- Add a repeatable benchmark harness.
- Measure inbox send/receive throughput and latency.
- Measure pub/sub fanout cost.
- Measure process group broadcast and routing cost.
- Measure telemetry emission cost.
- Measure timer scheduling overhead.
- Measure registry lookup and registration cost.
- Measure request/reply latency.
- Track allocations per operation.
- Track contention under concurrent producers and consumers.
- Publish baseline numbers for v2.0.0 behavior.

### Stress And Regression Testing

- Add stress tests for inboxes, process groups, pub/sub, timers, and registry
  operations.
- Add leak checks for high-volume message flows.
- Add long-running churn tests for create/send/receive/close cycles.
- Add failure-path tests for closed inboxes, full queues, expired messages, and
  disconnected clients.
- Add CI-friendly benchmark smoke tests that detect obvious regressions without
  requiring perfect machine-stable numbers.

### Runtime Introspection: First Layer

- Add `Runtime.snapshot()` or equivalent runtime-state snapshot API.
- Include registered process names.
- Include inbox queue depths and basic message stats.
- Include process group names and member counts.
- Include pub/sub subscriber counts.
- Include circuit breaker states.
- Include shutdown state.
- Include timer counts once runtime-owned timers exist later.

### Health And Readiness

- Add runtime health summary helpers.
- Add readiness status helpers for apps and examples.
- Expose unhealthy circuit breakers and overloaded queues in the health summary.
- Add examples showing how to build a `HEALTH` or `STATUS` command from runtime
  state.

### v2.1.0 Definition Of Done

- Users can benchmark Vigil locally.
- Users can inspect the basic state of a running runtime.
- The project has baseline performance numbers to compare future releases
  against.
- The examples expose meaningful health/readiness information.

## v2.2.0: Operate And Recover

Status: shipped.

v2.2.0 should make Vigil safer to operate when things go wrong. This is the
release where reliability patterns become first-class rather than hand-rolled in
examples.

### Reliability Policies

- Add retry policies.
- Add exponential backoff.
- Add fixed backoff.
- Add jittered backoff.
- Add timeout wrappers for fallible operations.
- Add fallback handlers.
- Add bulkheads or isolation pools for dependency protection.
- Add policy composition around circuit breakers.
- Add clear policy result types so callers can distinguish success, retry,
  timeout, fallback, and permanent failure.

### Dead Letter And Poison Message Handling

- Add dead-letter inspection APIs.
- Add dead-letter replay APIs.
- Add dead-letter discard APIs.
- Add poison-message detection hooks.
- Add max-attempt handling for repeated delivery failures.
- Add telemetry events for dead-letter, replay, discard, and poison-message
  outcomes.

### Runtime Introspection: Debug Layer

- Add structured debug dumps for runtime state.
- Add supervisor tree snapshots.
- Add inbox inspection without consuming messages where safe.
- Add process group route table inspection.
- Add pub/sub subscription inspection.
- Add circuit breaker diagnostics with failure counts and last transition time.
- Add runtime event timeline support for recent notable events.

### Testing And Simulation

- Add deterministic runtime clock support.
- Add simulated timers for tests.
- Add fault injection helpers.
- Add fake distributed registry for tests.
- Add helpers for simulating slow consumers, failed dependencies, full queues,
  and disconnected peers.
- Add property or fuzz tests for message routing and distributed protocol
  parsing.

### Operational Examples

- Add a resilient job queue example.
- Add a retry/backoff dependency-client example.
- Add a dead-letter replay example.
- Add a runtime introspection endpoint example.
- Add a checkpointed state-machine example if checkpoint APIs are ready enough.

### v2.2.0 Definition Of Done

- Users can express common reliability behavior without building it from
  scratch.
- Users can inspect and debug a running system beyond simple counters.
- Tests can simulate time and common failure modes deterministically.
- Examples show production-flavored failure handling.

## v2.3.0: Scale The Runtime

Status: shipped.

v2.3.0 should contain most of the major implementation improvements. This is the
release where Vigil becomes materially faster, more scalable, and more capable
under real load.

### Messaging And Inbox Hot Paths

- Replace `ArrayList` queue removal patterns with bounded ring buffers or
  deques.
- Add specialized inbox implementations:
  - single-producer/single-consumer,
  - multi-producer/single-consumer,
  - multi-producer/multi-consumer.
- Add direct queue-depth tracking.
- Reduce lock scope in mailbox send and receive operations.
- Replace receive polling sleeps with condition, futex, or event-style wakeups.
- Add batch send APIs.
- Add batch receive APIs.
- Add nonblocking receive APIs with clearer fast-path behavior.
- Add zero-copy or low-copy payload options.
- Support borrowed/static payloads when the caller can guarantee lifetime.
- Support reference-counted or arena-backed payloads for shared fanout.
- Pool or slab-allocate messages for high-volume workloads.
- Avoid duplicating common sender and id strings on every message.
- Replace timestamp-based allocated message ids with cheaper monotonic ids.
- Add explicit fast-message APIs for callers that do not need every metadata
  field.

### Runtime Scheduler And Timers

- Add a runtime-owned timer service.
- Replace per-timer threads with a timer wheel or min-heap scheduler.
- Batch expired timers on each scheduler tick.
- Add delayed-message scheduling that does not spawn one detached thread per
  message.
- Add cancellation handles for scheduled messages.
- Integrate timer shutdown into runtime shutdown.
- Add low-jitter timer benchmarks.

### Telemetry Fast Path

- Add allocation-free event emission paths.
- Add no-op fast paths when telemetry is disabled.
- Add counters and gauges for common runtime metrics.
- Add sampling before expensive event construction.
- Add filtering before event construction.
- Use runtime-owned or per-thread buffers for high-volume telemetry.
- Add structured metric snapshots for inboxes, supervisors, process groups,
  pub/sub brokers, timers, registries, and circuit breakers.

### Pub/Sub And Process Group Scaling

- Precompile topic patterns.
- Replace linear subscriber scans with a trie or topic index.
- Optimize wildcard matching for `*` and `#` patterns.
- Add batch publish APIs.
- Add batch process-group broadcast APIs.
- Add backpressure-aware publish modes.
- Add fanout modes that avoid copying payloads for every subscriber.
- Add stable routing strategies for dynamic membership.
- Add metrics for subscriber count, delivery failures, and fanout latency.

### Concurrency And Contention

- Add sharded registries for lower-contention name lookup.
- Consider read-heavy data structures for registry and pub/sub subscribers.
- Avoid holding group or broker locks while performing downstream sends.
- Add runtime-level executors for background work.
- Add worker-pool execution primitives where one thread per task is too costly.
- Add contention benchmarks for inboxes, registries, pub/sub, and process
  groups.

### Flow Control

- Track queue depth directly.
- Add adaptive backpressure based on queue growth and latency.
- Support bulk token consumption in rate limiters.
- Add lock-free or lower-lock rate limiter fast paths.
- Add separate policies for producer overload and consumer failure.
- Add metrics for throttled, dropped, blocked, and accepted messages.

### Distributed Runtime Improvements

- Use persistent peer connections instead of reconnecting per query.
- Add connection pooling for peer queries.
- Add nonblocking or event-loop socket support.
- Batch heartbeats.
- Batch registry sync messages.
- Consider compact binary frames for hot protocol paths.
- Add retry and backoff policies for peer communication.
- Add metrics for peer health, sync lag, query latency, and cache hits.
- Add load and failure tests for distributed registry behavior.

### Stateful Systems

- Add async checkpoint writes.
- Support incremental or delta checkpoints.
- Add buffered file I/O.
- Support pluggable fast serializers.
- Add checkpoint compression hooks.
- Add checkpoint latency and size metrics.
- Add crash-recovery hooks.
- Add checkpoint migration and state-versioning support.

### Fast-Path APIs And Build-Time Tuning

- Add explicit fast-path APIs where users opt into fewer features.
- Add comptime configuration to remove unused features from hot paths.
- Add minimal inbox/message modes for systems that do not need TTL, priority,
  dead-letter queues, tracing, or rich metadata.
- Add runtime profiles such as `safe`, `balanced`, and `throughput`.
- Document when to use ergonomic APIs versus fast-path APIs.
- Add performance-focused examples.

### v2.3.0 Definition Of Done

- Messaging and inbox benchmarks are materially better than v2.0.0 baselines.
- Allocations per message are materially lower than v2.0.0 baselines.
- Timer scheduling no longer requires one thread per timer.
- Pub/sub and process group fanout have scalable paths.
- Runtime telemetry and introspection work under high load.
- Reliability policies integrate with telemetry and introspection.
- Distributed and checkpointing systems have load and failure tests.

## v3.0.0: Stabilize And Integrate

v3.0.0 should be the production-runtime release. Most major implementation work
should already be present in v2.3.0. The v3.0.0 release should focus on
stability, integration, API cohesion, documentation, and confidence.

### API Cohesion

- Review all v2.1.0 through v2.3.0 APIs as one runtime surface.
- Remove or rename APIs that do not fit the final model.
- Stabilize fast-path APIs.
- Stabilize reliability policy APIs.
- Stabilize introspection snapshot schemas.
- Stabilize telemetry and metrics naming.
- Provide migration notes from v2.x to v3.0.0.

### Runtime Integration

- Ensure scheduler, telemetry, introspection, shutdown, flow control, and
  reliability policies work together cleanly.
- Ensure every runtime-owned service participates in graceful shutdown.
- Ensure runtime snapshots expose every major subsystem consistently.
- Ensure failure policies emit useful telemetry and update introspection state.
- Ensure fast-path APIs still preserve clear ownership and safety contracts.

### Stability And Reliability

- Run long-duration soak tests.
- Run high-concurrency stress tests.
- Run fault-injection and chaos-style tests.
- Run distributed partition and reconnect tests.
- Run checkpoint crash-recovery tests.
- Run memory-leak and allocator-pressure tests.
- Run API compatibility tests for documented examples.
- Confirm no known double-free, use-after-free, shutdown race, or thread leak
  paths remain.

### Production Documentation

- Rewrite API docs around production use cases.
- Add a performance tuning guide.
- Add a reliability patterns guide.
- Add an introspection and debugging guide.
- Add a distributed systems guide.
- Add a checkpointing and recovery guide.
- Add a migration guide.
- Add a "which API should I use?" guide for ergonomic versus fast-path APIs.

### Production Examples

- High-throughput worker pool.
- Resilient job queue.
- Metrics collector.
- Runtime introspection endpoint.
- Dead-letter replay workflow.
- Checkpointed state machine.
- Distributed worker registry.
- Pub/sub notification pipeline.
- Graceful drain and shutdown service.

### v3.0.0 Definition Of Done

- The runtime feels cohesive rather than assembled from separate features.
- Every major subsystem is measurable, observable, and documented.
- Every major failure path has a recommended reliability pattern.
- Every public production API has tests and examples.
- Benchmarks show clear improvement over v2.0.0 baselines.
- Stress and soak tests pass consistently.
- The migration path from v2.x is documented.
- The project can credibly claim: Vigil is a high-performance production
  runtime for resilient Zig systems.

## Cross-Version Success Criteria

Across the full roadmap, Vigil should demonstrate:

- Higher inbox throughput than v2.0.0.
- Lower allocations per message than v2.0.0.
- Lower pub/sub fanout overhead than v2.0.0.
- Timer scheduling without one thread per timer.
- Runtime introspection that is useful during live debugging.
- Reliability policies that are reusable and observable.
- Clear health and readiness patterns.
- Deterministic failure-mode tests.
- Distributed registry behavior that survives peer failure and reconnects.
- Documentation that teaches users how to build real systems, not just call
  isolated APIs.

## Recommended Build Order

1. Build the benchmark and introspection foundation in v2.1.0.
2. Add reliability and debugging primitives in v2.2.0.
3. Land the major runtime scaling work in v2.3.0.
4. Use v3.0.0 to stabilize, integrate, document, and prove the system.

This sequence keeps each release useful while preserving the larger story:
Vigil becomes faster, more reliable, more debuggable, and finally cohesive
enough to stand as a serious production runtime.
