# TTFT vs Concurrency (input = 220K chars ≈ 56K tokens)

End-to-end TTFT measured by `bench/http-bench/`, going through
`client → Istio Gateway (NodePort 30080) → EPP (ext_proc) → llm-d-inference-sim (PD)`.

| concurrency | TTFT mean | TTFT P50 | TTFT P90 | TTFT P99 | throughput |
|------------:|----------:|---------:|---------:|---------:|-----------:|
| 20          |   374 ms  |  —       |  —       |  —       | —          |
| **60**      | **1109 ms** | **1148 ms** | **1231 ms** | **1303 ms** | **50.7 req/s** |
| 80          |  1437 ms  |  —       |  —       |  —       | —          |
| 150         |  2531 ms  |  —       |  —       |  —       | —          |

Concurrency=60 is the focal data point (full output in
`profiles/http-bench-conc60.txt`). 450 requests, 0 errors.

## What EPP itself reports (same run)

From `profiles/http-metrics-conc60.txt`:

```
inference_objective_request_duration_seconds_sum   = 2844.48
inference_objective_request_duration_seconds_count = 1886
=> 1508 ms / request   (per-request wall-clock measured by EPP)

inference_extension_scheduler_e2e_duration_seconds_sum   = 2.96
inference_extension_scheduler_e2e_duration_seconds_count = 1886
=> 1.57 ms / request   (Scheduler.Schedule wall-clock)

sum(all plugin durations)                          ≈ 0.28 s / 1886
=> 0.15 ms / request   (all plugin extension points combined)
```

Scheduler and plugins together explain **~0.1%** of per-request latency.
The remaining ~1.5 s is spent **outside the Scheduler** — in request
ingest, parsing, repackaging, and the datalayer collector.

Note: with PD enabled, each end-user request is scheduled twice
(prefill profile + decode profile), which is why the `_count` columns
(1886) ≈ 2× client request count (450 × 2 + warmup overlap from earlier
concurrency sweeps).
