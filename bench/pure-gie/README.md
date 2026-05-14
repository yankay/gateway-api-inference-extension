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

The model server is **[`llm-d-inference-sim`](https://github.com/llm-d/llm-d-inference-sim)**
(`ghcr.io/llm-d/llm-d-inference-sim:v0.8.2`) — a CPU-only, sleep-based
vLLM-API-compatible stand-in. We use it deliberately: it returns
near-instantly so backend prefill/decode cost is removed from TTFT,
isolating EPP's request-path overhead as the only variable. The
**only** llm-d component in this stack is the sim (used purely as a
stub backend); the EPP, helm chart, CRDs and plugins are all upstream
GIE.

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
  stable-1s.sh             stable TTFT>1s reproducer (warmup + N rounds + median + assertion)
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

## Stable TTFT>1s reproducer (`stable-1s.sh`)

`repro.sh` is one-shot: it builds the cluster and runs a single sweep.
For *repeatedly* confirming that EPP still ingests a 220 KB request body
in more than 1 s — e.g. as a regression gate before/after a candidate
fix — use `stable-1s.sh` instead.

It assumes the stack from `repro.sh` is already up (KIND cluster
`gie-bench`, helm release for the inferencepool, model server pods).
It does **not** require pre-existing `kubectl port-forward` processes —
the script manages its own forwards (and cleans them up on exit), so
restarting the EPP pod between runs is fine.

### Ports

`stable-1s.sh` opens two local port-forwards. **By default both local
ports are randomly picked free TCP ports in the ephemeral range
(32768–60999)** — verified against `ss -ltn` before use. This avoids
every kind of collision (Prometheus on 9090, leftover forward from a
previous run, another dev server on 8080) without any per-host tuning.

| Target (in-cluster)             | Used for                  | Env var to pin the host port |
|---|---|---|
| `svc/inference-gateway-istio:80`   | sending bench traffic     | `GATEWAY_LOCAL_PORT`    |
| `svc/vllm-qwen3-32b-epp:9090`      | scraping `/metrics`/pprof | `METRICS_LOCAL_PORT`    |

`GATEWAY_LOCAL_PORT=0` / `METRICS_LOCAL_PORT=0` (the defaults) mean
"pick a random free port". Set them to a fixed number if you want a
stable URL to curl by hand, e.g. `GATEWAY_LOCAL_PORT=18080`. The actual
ports chosen for any given run are printed in the `[stable-1s] config`
banner and also recorded in `summary.txt`.

If you already have your own port-forwards running, pass `GATEWAY_URL`
/ `METRICS_URL` directly and they take precedence over the random
picker (the script will then just re-use the existing listeners).

What makes it "stable":

1. Parameters fixed in the regime where TTFT&nbsp;>&nbsp;1 s is known to
   hold (`c=150`, 220 KB body, upstream v1.5.0 default plugins).
2. A **warmup** phase whose results are discarded — avoids the
   cold-start outlier (`Min ~79 ms` in `c150-steady-30s.txt`) pulling
   the round mean down.
3. **N independent measurement rounds**; the script reports per-round
   mean TTFT and the **median across rounds** as the headline figure.
4. A hard **assertion** on the median: exits non-zero if the median
   round-mean TTFT drops below `${THRESHOLD_MS}` (default 900 ms,
   leaving a margin under the observed ~1108 ms). Suitable as a CI
   gate.

Usage:

```bash
# defaults: c=150, 220KB, 300 warmup reqs, 3 rounds x 1500 reqs, threshold 900 ms
./stable-1s.sh

# tighter gate, more rounds:
ROUNDS=5 THRESHOLD_MS=1000 ./stable-1s.sh

# point at a different gateway/metrics endpoint (e.g. you already have
# your own port-forwards running):
GATEWAY_URL=http://localhost:30080/v1/completions \
  METRICS_URL=http://localhost:9090/metrics \
  ./stable-1s.sh

# or pin the local port the script will forward to (default 0 = random):
GATEWAY_LOCAL_PORT=18080 METRICS_LOCAL_PORT=19090 ./stable-1s.sh
```

Tunables (env vars): `CONCURRENCY`, `INPUT_CHARS`, `WARMUP_REQS`,
`ROUND_REQS`, `ROUNDS`, `THRESHOLD_MS`, `GATEWAY_LOCAL_PORT`,
`METRICS_LOCAL_PORT`, `GATEWAY_URL`, `METRICS_URL`, `MODEL`, `HOST`,
`OUT_DIR`.

Artifacts written to `out/stable-1s/`:

```
warmup.txt              raw http-bench output for the discarded warmup
round-{1..N}.txt        raw http-bench output for each measurement round
epp-metrics-final.txt   /metrics snapshot at the end of the last round
summary.txt             machine-readable summary (per-round means + median)
http-bench              the compiled load tool
pf-gateway.log          kubectl port-forward log (gateway), if the script started one
pf-metrics.log          kubectl port-forward log (EPP metrics), same condition
```

Exit code:

- `0` — median round-mean TTFT &ge; `THRESHOLD_MS` (repro confirmed).
- `1` — median below threshold (regression — *good news* if a fix was applied).
- `2` — gateway / port-forward not reachable (run `repro.sh` first, or check `pf-*.log`).
- `3` — failed to parse TTFT mean from `http-bench` output.

### Tuning to your host

The default `THRESHOLD_MS=900` is calibrated against the historical run
captured in `results/c150-steady-30s.txt`, which was taken on a
particular KIND host where a single EPP replica (2 vCPU request /
4 GiB) bottlenecked at ~130 req/s under c=150 + 220 KB. On a
significantly faster host the *same* EPP image will not reach that
bottleneck — c=150 may sustain hundreds of req/s and TTFT stays well
under 1 s. That is real behaviour, not a script bug.

If your host is too fast for the default regime, raise the load until
EPP saturates. Cheap knobs (try in order):

```bash
# 1. more concurrency
CONCURRENCY=300 ./stable-1s.sh

# 2. fatter bodies (linear cost in the body-allocation hot path)
INPUT_CHARS=440000 CONCURRENCY=300 ./stable-1s.sh
```

#### Known-good preset (verified to reproduce TTFT > 1 s)

A preset that reliably puts EPP into the congested regime on a fast
multi-core host without changing EPP's resources, verified end-to-end
against `registry.k8s.io/gateway-api-inference-extension/epp:v1.5.0`
(the unfixed upstream image; equivalent to the `main` branch for the
hot paths called out in the issue):

```bash
# leave EPP with its chart defaults (requests: cpu=2; no CPU limit)
CONCURRENCY=1200 WARMUP_REQS=300 ROUND_REQS=1500 ROUNDS=3 \
  THRESHOLD_MS=1100 ./stable-1s.sh
```

Observed 3 rounds × 1500 reqs, 220 KB body, on this repo's KIND host:

```
per_round_ttft_mean_ms:  1249.86  1264.86  1405.74   (median 1264.86)
throughput per round:    698.81   683.45   655.35   req/s  (EPP-bound)
TTFT P99 per round:      2068     2125     2212     ms
0 errors, 1500/1500 successful per round
```

All three rounds put round-mean TTFT comfortably over 1 s with low
round-to-round variance, while throughput stays well below the
unsaturated rate observed at lower concurrency (~880 req/s at c=300)
— confirming EPP is the bottleneck, not the `llm-d-inference-sim`
backend. The exact
`CONCURRENCY` to use will depend on your host; tune it upward until
throughput plateaus and TTFT crosses 1 s.

The reverse case is informative too: if you run `stable-1s.sh` against
a **fixed** EPP build (e.g. the prealloc patch on
`fix/epp-request-body-prealloc`) the script is expected to **FAIL**
under the same parameters that previously PASSed. That is the intended
use as a regression gate.

## Caveats / limitations

- **No CPU profile.** GIE v1.5.0's `pkg/common/observability/profiling/pprof.go`
  registers `heap / goroutine / allocs / threadcreate / block / mutex`
  but **not** `/debug/pprof/profile`. CPU time attribution here is
  inferred from `alloc_space` and Prometheus wall-clock counters; it is
  not directly measured.
- **Backend is `llm-d-inference-sim`, a CPU stub.** Real prefill/decode
  would dominate TTFT under typical production prompts. This repro
  intentionally uses the sim so the backend contributes ~0 ms — any
  real-backend latency would stack additively on top of the ~1 s EPP
  baseline measured here.
- **Single EPP replica.** `replicas: 1` mirrors the chart default and
  the parent repro. Scale-out is out of scope.
- **Steady state matters.** The datalayer-Collector allocation share
  only stabilises after several seconds of load — see `c60-baseline.txt`
  vs `c150-steady-30s.txt` for the warm-vs-steady delta.
