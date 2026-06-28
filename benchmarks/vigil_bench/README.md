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

## Baseline

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
