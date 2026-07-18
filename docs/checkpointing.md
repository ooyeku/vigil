# Checkpointing and Recovery Guide

State that must survive a crash goes through `CheckpointService` — a
versioned, metered pipeline over any storage backend.

## The pipeline

```zig
var backend = try vigil.FileCheckpointer.init(allocator, "var/checkpoints");
defer backend.deinit();

var service = vigil.CheckpointService.init(allocator, backend.toCheckpointer(), .{
    .version = 2,
    .skip_unchanged = true,
});
try service.start();          // background writer for saveAsync
defer service.deinit();       // drains queued saves before exiting

try service.saveAsync("order-machine", serialized_state);
```

Every save is framed with a `VCK1` magic + version header, optionally
transformed by an `encode` hook (compression/encryption), skipped entirely
when byte-identical to the last save for that id, and — with `saveAsync` —
persisted off the hot path by one writer thread. `flush()` waits for the
queue; `deinit()` drains rather than drops.

## Crash safety

`FileCheckpointer` writes to a temp file and renames into place, so a crash
mid-write can never corrupt the previous good checkpoint — you recover
either the old state or the new, never garbage. `deinit()` persisting the
async queue covers orderly shutdown; for crash recovery, whatever the last
completed rename was is what `load()` returns.

## Versioning and migration

Loads parse the header; a checkpoint written without one (pre-3.0 data) is
treated as version 0. On a version mismatch the `migrate` hook receives the
decoded payload and its stored version and returns upgraded bytes; without
a hook the load fails explicitly with `error.CheckpointVersionMismatch`
rather than handing you bytes your deserializer can't parse. Bump
`options.version` whenever the serialized layout changes, and keep the
migration hook able to lift every version you've ever shipped.

## Watch it

`service.metrics()` reports saves, unchanged-skips, failures, bytes
written, cumulative save latency, and pending async saves. Rising `pending`
means storage is slower than your checkpoint rate — checkpoint less often,
shrink the payload (the `encode` hook is the place), or accept the lag.
`skipped_unchanged` climbing is good news: you're checkpointing on a timer
but the state rarely changes.

## GenServer integration

`GenServer` checkpoints its state on an interval through the same
`Checkpointer` interface (`checkpointer`/`checkpoint_id`/
`checkpoint_interval_ms` fields plus serialize/deserialize callbacks), and
restores it on start. Point it at the same backend the service uses; see
the checkpointed state machine in `examples/ops_toolkit`.

## Testing

`MemoryCheckpointer` is the in-memory backend for tests. The allocation
sweep in `checkpoint.zig` shows the pattern for proving your own backend
survives OOM at every step.
