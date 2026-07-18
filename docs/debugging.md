# Introspection and Debugging Guide

Every subsystem answers two questions without stopping the world:
`snapshot()` — what is the state right now — and `metrics()` — what has
happened over this instance's lifetime. All snapshots are owned values;
call `deinit()` on the ones that allocate.

## Start with the runtime dump

```zig
const dump = try rt.debugDump(allocator);
defer allocator.free(dump);
```

One readable report: health, every registered mailbox with queue depth and
dead-letter counts, timer service state, and the tail of the event timeline.
Wire it to a `STATUS` command (see `examples/ops_toolkit` and
`examples/vigilant_server`).

## The event timeline is your flight recorder

`try rt.enableTimeline(64)` makes the runtime retain the last N notable
events — dead-letters, replays, poison detections, breaker transitions,
policy retries/timeouts/fallbacks — with timestamps and metadata. When
something misbehaved a minute ago, `rt.timelineSnapshot(allocator)` answers
"what happened?" without a log pipeline.

## Drill into a subsystem

| Question | Call |
| --- | --- |
| What's queued, without consuming it? | `inbox.peekMessages(allocator)` |
| What's quarantined? | `inbox.deadLetters(allocator)` |
| What did flow control do to my sends? | `inbox.flowMetrics()` |
| What state is every supervised child in? | `supervisor.snapshot(allocator)` |
| Why is this breaker open? | `breaker.snapshot()` — failure counts, transitions, timestamps |
| Which worker gets this key? | `group.routeMemberForKey(allocator, key)` |
| Who's subscribed to what? | `broker.snapshot(allocator)` — patterns included |
| Is the cluster healthy? | `dist_registry.snapshot(allocator)` — per-peer liveness |
| Are checkpoints keeping up? | `service.metrics()` — latency, skips, pending |

## Health and readiness

`rt.health(allocator)` folds queue overload, dead-letter, and poison counts
into a coarse healthy/degraded/stopped status;
`healthWithCircuitBreakers()` adds dependency state. `degraded` + poison
messages usually means a bad message needs an operator decision — inspect,
then replay or discard.

## Deterministic reproduction

When a bug is timing-dependent, rebuild it under simulated time:
`SimulatedClock` + `SimulatedTimerService` make backoff and timers instant
and exact, `FaultInjector` scripts the failure sequence, and
`FakeDistributedRegistry` fakes partitions — no sleeps, no sockets, no
flakes. The soak harness in `stress/vigil_soak` is the opposite tool: real
threads and real churn for the bugs determinism can't reach.
