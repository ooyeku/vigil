# Vigil Benchmark Harness

Run from this package so the root Vigil package can remain library-only:

```bash
zig build run -Doptimize=ReleaseSafe -- --iterations 10000
```

Each row reports:

- `ops`: operation count used for the row.
- `elapsed`: total measured wall-clock time.
- `avg`: average nanoseconds per operation.
- `throughput`: operations per second.
- `allocs/op`: allocator calls per operation observed by the benchmark harness.

The harness currently covers inbox send/receive, registry lookup, registry
registration, telemetry emission, timer scheduling, process-group routing,
process-group broadcast, pub/sub fanout, request/reply correlation, and
concurrent inbox producer/consumer contention.

## Baseline (v2.2.0)

Captured on 2026-07-15 with Zig 0.16.0 on Darwin arm64 using:

```bash
zig build run -Doptimize=ReleaseSafe -- --iterations 10000
```

| Benchmark | Ops | Avg | Throughput | Allocs/Op |
| --- | ---: | ---: | ---: | ---: |
| inbox send+recv | 20,000 | 54,139 ns | 18,470/s | 1.501 |
| registry lookup | 10,000 | 5 ns | 181,818,181/s | 0.000 |
| registry register | 10,000 | 60 ns | 16,528,925/s | 1.001 |
| telemetry emit | 10,000 | 11 ns | 88,495,575/s | 1.000 |
| timer schedule+join | 10,000 | 19,062 ns | 52,458/s | 1.000 |
| process group route | 10,000 | 131 ns | 7,610,350/s | 3.008 |
| process group broadcast | 40,000 | 132 ns | 7,535,795/s | 3.252 |
| pubsub fanout | 40,000 | 139 ns | 7,189,072/s | 3.252 |
| request/reply correlate | 10,000 | 341 ns | 2,929,115/s | 12.000 |
| inbox contention | 20,000 | 20,981 ns | 47,660/s | 1.501 |

Known regression vs the v2.1.0 baseline below: inbox send+recv and inbox
contention are ~5-8x slower. The v2.2.0 fix that makes mailboxes apply their
default TTL means every queued message now carries a TTL, so the
expired-message sweep in `ProcessMailbox.receive()` performs one clock read
per queued message per receive — quadratic clock reads when draining a deep
queue. In v2.1.0 those messages had no TTL and `isExpired()` returned without
touching the clock. Fixing the sweep (single clock read per receive, then the
v2.3.0 ring-buffer work) is the first hot-path item for the next release.

## Baseline (v2.1.0)

Captured on 2026-06-28 with Zig 0.16.0 on Darwin arm64 using:

```bash
zig build run -Doptimize=ReleaseSafe -- --iterations 10000
```

| Benchmark | Ops | Avg | Throughput | Allocs/Op |
| --- | ---: | ---: | ---: | ---: |
| inbox send+recv | 20,000 | 7,155 ns | 139,758/s | 1.501 |
| registry lookup | 10,000 | 5 ns | 178,571,428/s | 0.000 |
| registry register | 10,000 | 60 ns | 16,583,747/s | 1.001 |
| telemetry emit | 10,000 | 13 ns | 73,529,411/s | 1.000 |
| timer schedule+join | 10,000 | 19,300 ns | 51,811/s | 1.000 |
| process group route | 10,000 | 96 ns | 10,373,443/s | 3.008 |
| process group broadcast | 40,000 | 98 ns | 10,124,019/s | 3.252 |
| pubsub fanout | 40,000 | 101 ns | 9,832,841/s | 3.252 |
| request/reply correlate | 10,000 | 321 ns | 3,112,356/s | 16.000 |
| inbox contention | 20,000 | 4,008 ns | 249,494/s | 1.501 |
