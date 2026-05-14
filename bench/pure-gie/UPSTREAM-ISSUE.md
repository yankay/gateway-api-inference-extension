# EPP request path adds ~1s of overhead on large-input requests (Scheduler is only ~27µs)

## Summary

On a clean install of upstream `kubernetes-sigs/gateway-api-inference-extension`
v1.5.0 with the default `EndpointPickerConfig`, TTFT (time-to-first-token)
climbs past 1 s once concurrency reaches ~150 with a 220 KB chat-completion
prompt. The Scheduler and every plugin combined account for ~0.003 % of the
per-request latency; the remaining ~1.05 s is spent in EPP code paths outside
the Scheduler (request parsing, body re-marshalling, prefix-cache input
hashing, and the datalayer metrics collector).

This reproduction uses only upstream components — no llm-d, no custom
plugins, no `disagg-*` config — to isolate the issue to GIE itself.

## Environment

| Component | Version |
|---|---|
| GIE EPP image | `registry.k8s.io/gateway-api-inference-extension/epp:v1.5.0` |
| GIE chart | `inferencepool` v1.5.0 (default `EndpointPickerConfig`) |
| Gateway | Istio 1.28.0 (`ENABLE_GATEWAY_API_INFERENCE_EXTENSION=true`) |
| Gateway API CRDs | v1.2.1 |
| Backend | 4× `ghcr.io/llm-d/llm-d-inference-sim:v0.8.2`, `--max-model-len=65536` |
| Cluster | KIND, kindest/node v1.31.0 |
| Client | `http-bench`, 220 KB prompt, streaming chat-completion |

## Reproduction

Full automated repro (KIND + CRDs + Istio + GIE + sim + sweep + pprof):

https://github.com/yankay/gateway-api-inference-extension/blob/perf/epp-large-input-repro-pure-gie/bench/pure-gie/repro.sh

Stack, manifests, results, and profiles:

https://github.com/yankay/gateway-api-inference-extension/tree/perf/epp-large-input-repro-pure-gie/bench/pure-gie

## Results

TTFT mean vs concurrency, 220 KB prompt:

| Concurrency | TTFT mean | Throughput |
|---:|---:|---:|
| 20  | 158 ms  | ~125 req/s |
| 60  | 426 ms  | ~129 req/s |
| 100 | 723 ms  | ~129 req/s |
| 150 | **1141 ms** (4000 reqs, 31 s steady) | ~131 req/s |
| 200 | 1473 ms | ~130 req/s |

Throughput plateaus at ~130 req/s past c=60, so the curve is
queueing-dominated and EPP is the bottleneck — not the backend.

At steady c=150, EPP `/metrics`:

```
inference_objective_request_duration_seconds    avg = 1055 ms
inference_extension_scheduler_e2e_duration_seconds avg =   27 us
sum of every plugin duration                    avg = ~12 us
```

→ Scheduler + plugins ≈ **0.003 %** of per-request latency.

## Hot paths (alloc_space top, 21.4 GB total at c=150)

All file:line references are against upstream v1.5.0.

1. **48.4 %** — `pkg/epp/handlers.(*StreamingServer).Process`
   ([handlers/server.go](https://github.com/kubernetes-sigs/gateway-api-inference-extension/blob/v1.5.0/pkg/epp/handlers/server.go))
   accumulates the full request body in a `[]byte` per request without
   preallocation; for a 220 KB prompt this is the dominant allocator.
2. **~25 %** — datalayer Collector
   (`prometheus/common/expfmt` + `compress/flate`,
   [pkg/epp/datalayer/metrics/collector.go](https://github.com/kubernetes-sigs/gateway-api-inference-extension/blob/v1.5.0/pkg/epp/datalayer/metrics/collector.go))
   re-parses and re-encodes per-pod `/metrics` on every scrape cycle.
3. **11.9 %** — `encoding/json.Unmarshal` in the OpenAI request parser
   ([pkg/epp/handlers/request.go](https://github.com/kubernetes-sigs/gateway-api-inference-extension/blob/v1.5.0/pkg/epp/handlers/request.go)).
   The full body is decoded into a generic `map[string]any`.
4. **7.4 %** — `encoding/json.Marshal` in the request-control director
   ([pkg/epp/requestcontrol/director.go](https://github.com/kubernetes-sigs/gateway-api-inference-extension/blob/v1.5.0/pkg/epp/requestcontrol/director.go))
   re-marshals the same body before forwarding.
5. **5.8 %** — `approximateprefix.getUserInputBytes`
   ([pkg/epp/scheduling/framework/plugins/profile/approximateprefix](https://github.com/kubernetes-sigs/gateway-api-inference-extension/tree/v1.5.0/pkg/epp/scheduling/framework/plugins/profile/approximateprefix))
   does a third `json.Marshal` of the user messages just to hash them for
   the approximate prefix cache.

So the body of a single 220 KB request is fully allocated and serialized
**at least three times** before it ever reaches the backend.

Top of `pprof -alloc_space`:

https://github.com/yankay/gateway-api-inference-extension/blob/perf/epp-large-input-repro-pure-gie/bench/pure-gie/profiles/allocs-c150-steady.top30.txt

Raw profiles (allocs / heap / mutex) and the full `/metrics` snapshot are
in the same directory.

## Caveats

- v1.5.0 ships pprof on the metrics server but omits `/debug/pprof/profile`,
  so CPU attribution is inferred from alloc_space + mutex + the per-plugin
  duration metrics. A CPU profile would make the attribution direct; happy
  to rebuild EPP with the CPU endpoint enabled if useful.
- vllm-sim is a stand-in for a real vLLM backend; it isolates EPP overhead
  cleanly but does not reproduce real prefill cost. The conclusion
  (Scheduler ≪ 1 % of TTFT) is a property of EPP, not of the backend.

## Suggested direction

The five hot paths above are all on the request-handling fast path and look
addressable independently:

1. Preallocate the request-body buffer in `StreamingServer.Process` from the
   `Content-Length` header.
2. Cache or rate-limit the datalayer Collector scrape pipeline.
3. Parse the OpenAI request once into a typed struct, keep the original
   `[]byte`, and reuse it everywhere downstream (eliminates hot paths 3, 4,
   and 5).

Happy to put up a PoC PR for (1) and (3) if maintainers agree on direction.
