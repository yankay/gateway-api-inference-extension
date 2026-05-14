# EPP large-input perf repro

Reproduces an EPP (gateway-api-inference-extension v1.5.0 derivative) **TTFT
~1.1 s for a single ~220 KB request body** under 60 concurrent clients,
even though the backend is a near-instant mock (`llm-d-inference-sim`).

The bottleneck sits **inside the EPP request path** — not the Scheduler,
not Envoy, not the backend. See `./results/ttft-by-concurrency.md` and
`./profiles/`.

## Layout

```
bench/
  README.md         this file
  repro.sh          end-to-end repro (KIND + EPP + sim + http-bench)
  epp-config.yaml   EPP EndpointPickerConfig used in the run
  http-bench/       Go HTTP load tool (POST /v1/completions, TTFT, P-tiles)
  epp-bench/        Go ext_proc direct client (bypasses Envoy, optional)
  profiles/         pprof/text artifacts collected at concurrency=60
  results/          summary tables
  pure-gie/         pure-upstream-GIE TTFT reproduction (sibling scenario)
  pure-gie-prealloc/  A/B benchmark for EPP request-body prealloc fix
```

## Stack under test

- **EPP image**: `ghcr.io/llm-d/llm-d-inference-scheduler:dev` built from
  `github.com/llm-d/llm-d-inference-scheduler` against
  `sigs.k8s.io/gateway-api-inference-extension v1.5.0`. All hot
  functions in the profiles also exist in upstream GIE v1.5.0 (see the
  GitHub issue body for line-by-line citations).
- **Backend**: `ghcr.io/llm-d/llm-d-inference-sim:v0.8.2` running as
  prefill + decode pods (`vllm-p`, `vllm-d`) with
  `--max-model-len=65536`.
- **Gateway**: Istio + ext_proc (port 9002), NodePort `30080`.
- **Routing**: HTTPRoute with `Host: bench.local`.
- **Cluster**: a single `kind` cluster created by the upstream
  `scripts/kind-dev-env.sh` of the scheduler repo with `DISAGG_P=true`.

## One-shot repro

```bash
# Prerequisites: kind, kubectl, docker, go 1.25+, helm, kustomize
git clone https://github.com/llm-d/llm-d-inference-scheduler
cd llm-d-inference-scheduler

# Use the config in this directory:
cp /path/to/bench/epp-config.yaml deploy/config/bench-pd-epp-config.yaml

EPP_CONFIG=deploy/config/bench-pd-epp-config.yaml DISAGG_P=true \
  ./scripts/kind-dev-env.sh

# Set vllm sim max-model-len so 220K-char prompts are accepted:
kubectl patch deploy vllm-p --type=json -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--max-model-len=65536"}]'
kubectl patch deploy vllm-d --type=json -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--max-model-len=65536"}]'

# Forward the EPP metrics port (for pprof):
kubectl port-forward deploy/bench-model-endpoint-picker 9090:9090 &

# Run the load (defaults match the issue numbers):
cd /path/to/bench/http-bench
go run . \
  --url http://localhost:30080/v1/completions \
  --host bench.local \
  --concurrency 60 \
  --total 450 \
  --input-chars 220000
```

## Profile capture (during a hot run)

```bash
curl -s http://localhost:9090/debug/pprof/allocs    -o http-allocs-conc60.pb.gz
curl -s http://localhost:9090/debug/pprof/mutex     -o http-mutex-conc60.pb.gz
curl -s "http://localhost:9090/debug/pprof/goroutine?debug=1" -o http-goroutine-conc60.txt
curl -s http://localhost:9090/metrics               -o http-metrics-conc60.txt

go tool pprof -top -cum -nodecount=40 http-allocs-conc60.pb.gz \
  > http-allocs-conc60.top.txt
```

> **Note**: GIE v1.5.0's pprof handler at
> `pkg/common/observability/profiling/pprof.go` only registers
> `heap / goroutine / allocs / threadcreate / block / mutex` — there is
> **no `/debug/pprof/profile` (CPU)** handler. To get CPU profiles you
> need to add one. The analysis here is therefore based on `alloc_space`
> + Prometheus wall-clock metrics; CPU attribution is inferred, not
> directly measured.

## Key numbers

See `./results/ttft-by-concurrency.md` for the full table.
Headline at concurrency=60:

- TTFT mean: **1108.77 ms** (P99 1303.30 ms)
- `inference_objective_request_duration` avg: **1508 ms / request**
- `inference_extension_scheduler_e2e_duration` avg: **1.57 ms / request**
- sum of all plugin durations avg: **0.15 ms / request**

→ Scheduler + plugins account for ≈ 0.1% of per-request time.
