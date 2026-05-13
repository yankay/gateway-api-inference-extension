# EPP large-input perf repro — pure upstream GIE

Companion to the parent `bench/` directory. This subdirectory removes
**every llm-d component** from the reproduction and re-runs it against a
clean install of **upstream `kubernetes-sigs/gateway-api-inference-extension`
v1.5.0**:

- no `llm-d-inference-scheduler`,
- no disaggregated prefill/decode (no `vllm-p` / `vllm-d` split),
- no `disagg-headers-handler` / `disagg-profile-handler` /
  `always-disagg` plugin set, no custom `EndpointPickerConfig`,
- only the **default plugin config** baked into the upstream chart
  (`approx-prefix-cache-producer`, `prefix-cache-scorer`,
  `kv-cache-utilization-scorer`, `queue-scorer`, `max-score-picker`,
  `single-profile-handler`).

The point: the EPP request-path overhead reported in the parent
`README.md` is **not** a llm-d artifact. The same TTFT collapse and the
same allocation hot spots are present in plain upstream GIE.

## Stack under test

| Component | Version / source |
|---|---|
| Kubernetes | kind `v1.31.0` |
| Gateway API | `v1.2.1` |
| GIE CRDs / Helm chart | `v1.5.0` (`config/crd`, `config/charts/inferencepool`) |
| EPP image | `registry.k8s.io/gateway-api-inference-extension/epp:v1.5.0` |
| Gateway | Istio `1.28.0` with `ENABLE_GATEWAY_API_INFERENCE_EXTENSION=true` |
| Model server | `ghcr.io/llm-d/llm-d-inference-sim:v0.8.2` × 4, `--max-model-len=65536` |
| Load tool | `../http-bench` (Go, POST `/v1/completions`, TTFT P-tiles) |

EPP plugin set (taken straight from the chart's
`default-plugins.yaml` — no override):

```
PreRequest:               approx-prefix-cache-producer
Scorer:                   prefix-cache-scorer, kv-cache-utilization-scorer, queue-scorer
Picker:                   max-score-picker
ProfilePicker:            single-profile-handler
ProcessProfilesResults:   single-profile-handler
```

## Layout

```
pure-gie/
  README.md                this file
  repro.sh                 end-to-end repro (KIND + Istio + GIE + sim + http-bench)
  manifests/
    sim-deployment.yaml    4x llm-d-inference-sim with --max-model-len=65536
    gateway-route.yaml     Gateway + HTTPRoute -> InferencePool
  results/
    sweep.txt              concurrency sweep 20/60/100/150/200
    c150-steady-30s.txt    long c=150 run (4000 reqs, ~31s) for steady state
    c60-baseline.txt       early c=60 short run (cold cache)
  profiles/
    allocs-c150-steady.pb.gz      pprof alloc_space during the long c=150 run
    allocs-c150-steady.top30.txt  rendered `go tool pprof -top -cum` of the above
    heap-c150-steady.pb.gz        in-use heap snapshot
    mutex-c150-steady.pb.gz       mutex profile
    epp-metrics-steady.txt        full /metrics dump at end of the long run
```

## Headline numbers

### TTFT vs concurrency (220 KB prompt, mean / P50 / P99)

| concurrency | TTFT mean | TTFT P50 | TTFT P99 | throughput |
|---:|---:|---:|---:|---:|
|  20 |  158 ms |  156 ms |  220 ms | 120 req/s |
|  60 |  426 ms |  442 ms |  481 ms | 133 req/s |
| 100 |  723 ms |  754 ms |  823 ms | 130 req/s |
| **150 (steady, 4000 req)** | **1141 ms** | **1153 ms** | **1272 ms** | 129 req/s |
| 200 | 1473 ms | 1538 ms | 1709 ms | 128 req/s |

Throughput plateaus at ~130 req/s from `c=60` onward, so the curve is
queueing-dominated past that point — i.e. EPP is the bottleneck, not the
backend (which is a sleep-based sim).

### Where the time goes (steady c=150, 8694 requests inside EPP)

| EPP wall-clock metric | average per request |
|---|---:|
| `inference_objective_request_duration_seconds` | **1055 ms** |
| `inference_extension_scheduler_e2e_duration_seconds` (Scheduler.Schedule) | **26.8 µs** |
| Σ `inference_extension_plugin_duration_seconds` (all plugins, all extension points) | **~12 µs** |

→ Scheduler + every plugin combined: **~0.003 %** of per-request
latency. Whatever EPP is spending the other 1.05 s on, it is **not**
the scheduling decision.

### Where the allocations go (steady c=150, 21.4 GB total alloc)

Top of `go tool pprof -top -cum` on
`profiles/allocs-c150-steady.pb.gz`:

```
   flat   flat%    cum   cum%  function
 3.39GB  15.82% 10.37GB 48.39% sigs.k8s.io/gateway-api-inference-extension/pkg/epp/handlers.(*StreamingServer).Process
                       ≈17.3%  github.com/prometheus/common/expfmt.(*TextParser).*  (datalayer Collector)
                       ≈ 7.3%  compress/flate.NewReader / dictDecoder.init          (datalayer Collector)
 1.25GB   5.82%  1.59GB  7.42% encoding/json.Marshal
                        11.94% encoding/json.Unmarshal                              (cum)
 1.24GB   5.77%  1.24GB  5.77% .../approximateprefix.getUserInputBytes
```

Cross-walking those to the five hot paths called out in the GitHub
issue:

| Hot path (issue) | Upstream code site                                                                                                                                | This run        |
|---|---|---:|
| #1 body grown with `append`, no preallocation                                                                                                                | [`pkg/epp/handlers/server.go#L231`](https://github.com/kubernetes-sigs/gateway-api-inference-extension/blob/v1.5.0/pkg/epp/handlers/server.go#L231)                                                                                                                       | **48.4 %** alloc cum |
| #2 OpenAI parser double-`Unmarshal`                                                                                                                          | [`.../openai/openai.go#L93`](https://github.com/kubernetes-sigs/gateway-api-inference-extension/blob/v1.5.0/pkg/epp/framework/plugins/requesthandling/parsers/openai/openai.go#L93), [`L196-L226`](https://github.com/kubernetes-sigs/gateway-api-inference-extension/blob/v1.5.0/pkg/epp/framework/plugins/requesthandling/parsers/openai/openai.go#L196-L226) | **11.9 %** alloc cum (`json.Unmarshal`) |
| #3 Director re-`Marshal` of `bodyMap`                                                                                                                        | [`pkg/epp/requestcontrol/director.go#L261`](https://github.com/kubernetes-sigs/gateway-api-inference-extension/blob/v1.5.0/pkg/epp/requestcontrol/director.go#L261)                                                                                                       | **7.4 %** alloc cum (`json.Marshal`) |
| #4 `approximateprefix.getUserInputBytes` `json.Marshal` of messages                                                                                          | [`.../approximateprefix/hashing.go#L96-L120`](https://github.com/kubernetes-sigs/gateway-api-inference-extension/blob/v1.5.0/pkg/epp/framework/plugins/requestcontrol/dataproducer/approximateprefix/hashing.go#L96-L120)                                                  | **5.77 %** alloc flat |
| #5 datalayer Collector re-allocating the gzip dictionary every poll                                                                                          | (chain ends in `compress/flate.(*dictDecoder).init`)                                                                                                                                                                                                                     | **~25 %** alloc cum (expfmt + flate) |

All five hot paths reported in the issue against
`llm-d-inference-scheduler` are reproduced byte-for-byte against
plain upstream **`registry.k8s.io/gateway-api-inference-extension/epp:v1.5.0`**.

## One-shot repro

```bash
# Prereqs: kind, kubectl, docker, go 1.25+, helm, curl. istioctl is
# downloaded automatically if not on PATH.
./repro.sh
```

The script:

1. creates a fresh KIND cluster `gie-bench`,
2. installs Gateway API + GIE CRDs `v1.5.0`,
3. installs Istio `1.28.0` with `ENABLE_GATEWAY_API_INFERENCE_EXTENSION=true`,
4. deploys 4× `llm-d-inference-sim` with `--max-model-len=65536`,
5. helm-installs the upstream `inferencepool` chart `v1.5.0`
   (`provider=istio`, default plugin config, metrics auth disabled so
   pprof is reachable),
6. applies a Gateway + HTTPRoute,
7. runs the c=20/60/100/150/200 sweep and a 30 s steady-state c=150 run,
8. snapshots `allocs / heap / mutex` pprof and `/metrics` into `./out/`.

## Caveats / limitations

- **No CPU profile.** GIE v1.5.0's `pkg/common/observability/profiling/pprof.go`
  registers `heap / goroutine / allocs / threadcreate / block / mutex`
  but **not** `/debug/pprof/profile`. CPU time attribution here is
  inferred from `alloc_space` and Prometheus wall-clock counters; it is
  not directly measured.
- **Backend is a CPU sim.** Real prefill/decode would dominate TTFT
  under typical production prompts. This repro intentionally isolates
  the EPP overhead so real-backend latency would stack additively on
  top of the ~1 s baseline measured here.
- **Single EPP replica.** `replicas: 1` mirrors the chart default and
  the parent repro. Scale-out is out of scope.
- **Steady state matters.** The datalayer-Collector allocation share
  only stabilises after several seconds of load — see `c60-baseline.txt`
  vs `c150-steady-30s.txt` for the warm-vs-steady delta.
