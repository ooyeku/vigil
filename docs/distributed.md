# Distributed Systems Guide

`DistributedRegistry` extends local name resolution across a TCP cluster.
It is deliberately simple: a text protocol (`VIGIL/2` frames), best-effort
sync, and caching — a service directory, not a consensus system.

## Topology and lifecycle

Every node runs the same shape:

```zig
var registry = try vigil.DistributedRegistry.init(allocator, .{
    .cluster_nodes = &.{ "10.0.0.2:9100", "10.0.0.3:9100" },
    .listen_port = 9100,
    .sync_interval_ms = 1_000,
    .heartbeat_timeout_ms = 5_000,
});
try registry.startSync(); // listener + heartbeat/sync threads
defer registry.deinit();  // stopSync() implied
```

Register with `.local` (this node only) or `.global` (advertised to peers).
Global names must be single protocol tokens — no whitespace.

## How resolution works

- `whereis(name)` — local registry only.
- `whereisGlobal(name)` — local first, then the remote cache. Never touches
  the network; safe on hot paths.
- `queryPeers(name)` — actively asks each live peer (`WHERE`), caches the
  answer. Use when a cache miss matters.

Background sync pushes your global names to peers as batched `REG` frames
every interval, so steady-state resolution is a cache hit.

## Failure behavior

Each peer gets one persistent connection. When an exchange fails, the
connection is dropped and retried once fresh; if that also fails the peer is
marked dead and enters exponential reconnect backoff (250ms doubling to
30s). While backed off, queries skip the peer — a dead node costs nothing.
Heartbeats every sync interval detect silent death
(`heartbeat_timeout_ms`), and the first successful exchange after a
partition heals the peer automatically. This is exercised end to end by the
partition-heal tests and the soak harness's chaos scenario.

Design consequence: during a partition you get *stale cache or nothing* —
entries are not invalidated when a peer dies. Treat cached remote info as a
hint and handle connection failure at the call site.

## Watch it

`registry.snapshot(allocator)` reports per-peer liveness, `last_seen_ms`,
`consecutive_failures`, and `reconnects`, plus lifetime cache hit/miss,
query, heartbeat, and sync-frame counters. A peer with climbing failures
and no reconnects is unreachable; hits flat while queries climb means your
cache is not warming — check that both sides run `startSync()`.

## Testing without a network

`FakeDistributedRegistry` (in `vigil.testing`) fakes peers, remote names,
and partitions (`disconnectPeer`/`reconnectPeer`) with no sockets, for
deterministic unit tests. Keep the real-socket coverage to the library's
integration tests and the soak harness.
