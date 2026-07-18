# Performance Tuning Guide

Vigil's defaults favor safety. This guide covers the explicit fast paths for
when profiling says messaging is your bottleneck. Baseline numbers live in
`benchmarks/vigil_bench/README.md`; measure before and after any change here.

## Pick a runtime profile

The single biggest lever is how much mailbox machinery each inbox carries:

```zig
var fast = try rt.inboxWithProfile(.throughput, 4096);
```

- `safe` (default): priority queues, dead-letter retention, 30s default TTL.
- `balanced`: keeps priority and dead-letter, drops default TTLs — receives
  skip all expiry bookkeeping.
- `throughput`: one FIFO ring, no priority scan, no dead-letter machinery,
  no TTLs. Failed sends are plain errors; use for pipeline stages that
  handle retry themselves (or run under a reliability policy).

## Batch the hot loops

- `recvBatch(&buffer)` drains N messages under one lock and one expiry
  sweep; a 64-message batch costs far less than 64 `tryRecv()` calls.
- `sendBatch(payloads)` amortizes the per-send guard.
- `publishBatch(topic, payloads)` and `broadcastBatch(payloads)` match each
  subscriber/member once for the whole batch.
- `RateLimiter.allowN(n)` admits a batch all-or-nothing without n CAS loops.

## Know what each send costs

A `send()` makes exactly one allocation (id, sender, and payload share one
buffer). Blocking receives park on a futex and wake in microseconds; an idle
receiver costs zero CPU. Telemetry emission is allocation-free and, when the
emitter is disabled or has no handlers, a single atomic load. Use
`wouldEmit(event_type)` before building expensive event metadata.

## Queue depth still matters at the edges

Receive cost is independent of queue depth (expiry is checked lazily at the
head). The exceptions: a send that finds the mailbox *full* sweeps expired
messages once before reporting overflow, and `peekMessages`/`snapshotQueue`
walk the whole queue by design. Keep introspection off per-message paths.

## Ergonomic vs fast-path APIs

Use `Inbox` + a profile for almost everything; drop to raw `ProcessMailbox`
only when you need `receiveWait` semantics or custom `Message` construction.
Timers always go through `Runtime.timers()` — one scheduler thread total,
~460ns per schedule, allocation-free.
