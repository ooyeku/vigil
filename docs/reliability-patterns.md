# Reliability Patterns Guide

How to make failure behavior intentional. Every pattern here is observable:
wire the runtime emitter in and outcomes appear on the event timeline.

## Guard a flaky dependency

Compose retry, backoff, deadline, breaker, and fallback in one call:

```zig
const result = vigil.executePolicy(Ctx, Payload, &ctx, Ctx.operation, .{
    .retry = .{ .max_attempts = 3, .backoff = .{ .exponential = .{
        .initial_ms = 100, .multiplier = 2, .max_ms = 2_000,
    } } },
    .timeout_ms = 10_000,
    .circuit_breaker = &breaker,
    .fallback = Ctx.cachedAnswer,
    .telemetry = &rt.telemetry_emitter, // policy_retry/_timeout/_fallback events
});
```

Switch on the typed result: `.success`, `.fallback`, `.timeout`,
`.circuit_open` (rejected before the dependency was touched — the breaker
doing its job), `.permanent_failure`. The report carries attempts, retries,
and elapsed time for logging.

- Breakers: per dependency, not per call site. Watch `snapshot()` for
  `open_transitions` and `last_transition_time_ms`; `forceClose()` is the
  operator override after a confirmed recovery.
- Bulkheads: cap concurrent calls into one dependency so a hang can't absorb
  every worker. Acquire inside the policy operation so each retry takes a
  fresh permit.

## Quarantine instead of losing messages

Messages that fail delivery go to bounded dead-letter storage, not the void:

- `deadLetter(msg, reason)` quarantines a message you failed to process.
- `deadLetters()` inspects without consuming; `replayDeadLetter(id)` returns
  one to the queue (TTL renewed); `discardDeadLetter(id)` drops it.
- A message that keeps failing past `max_delivery_attempts` becomes
  *poison*: replay refuses it, `onPoisonMessage()` fires once, and health
  reports degrade until an operator discards it.

## Shed load before falling over

Producer overload is flow control's job (consumer failure is dead-letter's):

- `.adaptive` backpressure slows producers progressively between the
  watermarks, then blocks at the high mark — a dimmer, not a breaker.
- `.drop_oldest` / `.drop_newest` / `.return_error` for queues where
  freshness, completeness, or explicit failure matter most.
- Rate limits with a real `burst_size` separate sustained rate from bursts.
- Read `flowMetrics()` to see what flow control actually did.

## Supervise with intent

Restart types follow Erlang semantics: `permanent` restarts on any
termination, `transient` only on failure, `temporary` never. Pair with
restart strategies (`one_for_one`, `one_for_all`, `rest_for_one`) and keep
`max_restarts`/`max_seconds` tight enough that a crash loop surfaces as
`TooManyRestarts` instead of burning quietly.

## Recommended failure-path map

| Failure | Pattern |
| --- | --- |
| Dependency down | policy retry + breaker + fallback |
| Dependency slow | policy timeout + bulkhead |
| Consumer crash | supervisor restart + dead-letter replay |
| Producer overload | adaptive backpressure + rate limit |
| Repeated bad message | poison quarantine + operator discard |
| Node unreachable | distributed registry backoff (see distributed guide) |
