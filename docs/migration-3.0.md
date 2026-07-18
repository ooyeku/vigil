# Migrating from Vigil 2.x to 3.0

v3.0.0 finishes the API cohesion work: one naming convention, no global
state, no duplicate machinery. Most changes are mechanical renames.

## Naming convention

Point-in-time state is `snapshot()`; lifetime counters are `metrics()`.

| v2.x | v3.0 |
| --- | --- |
| `ProcessMailbox.getStats()` / `MailboxStats` | `metrics()` / `MailboxMetrics` |
| `Inbox.stats()` | `Inbox.metrics()` |
| `ChildProcess.getStats()` / `ProcessStats` | `metrics()` / `ProcessMetrics` |
| `Registry.Snapshot` | module-level `RegistrySnapshot` |
| `Supervisor.SupervisorSnapshot` (nested) | module-level `SupervisorSnapshot` |
| `FlowControlStats` | `FlowControlMetrics` |
| `Preset` / `PresetConfig` | `AppPreset` / `AppPresetConfig` |

## Removed APIs

- **`vigil/legacy` module**: import `vigil` directly.
- **`vigil.Timer`** (one thread per timer): use `vigil.TimerService` or
  `Runtime.timers()`. `GenServer.schedule()` now requires
  `setTimerService()` and returns `error.NoTimerService` without one.
- **Global telemetry** (`telemetry.initGlobal/getGlobal/on/emit`):
  inject emitters instead. `CircuitBreaker`, `ProcessGroup`,
  `PubSubBroker`, and `Supervisor` gained `setTelemetryEmitter()`;
  `Runtime.supervisor()` wires the runtime emitter automatically.
- **`FlowControlledInbox`**: configure rate limits and backpressure on the
  inbox builder (`withRateLimit`, `withBackpressure`) and read counters
  from the new `Inbox.flowMetrics()`.
- **`Supervisor.getStats()/inspect()/getChildInfo()`, `SupervisorStats`**:
  use `Supervisor.snapshot()`, which now also carries
  `last_failure_time_ms`.

## Renamed enum variants and errors

- `Signal`: `healthCheck`→`health_check`, `memoryWarning`→`memory_warning`,
  `cpuWarning`→`cpu_warning`, `deadlockDetected`→`deadlock_detected`,
  `messageErr`→`message_error`.
- `InboxError` is gone; `InboxClosed` lives in `MessageError`. Code using
  `error.InboxClosed` literals is unaffected.
