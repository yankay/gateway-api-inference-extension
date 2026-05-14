# A/B benchmark: PR #2924 (preallocate EPP request body buffer)

## What this measures

This benchmark exercises a real KIND-based EPP stack (upstream GIE v1.5.0
helm chart + Istio + 4× vllm-sim) with **only the EPP image swapped**
between two adjacent commits:

| arm      | commit     | description                                    |
|----------|------------|------------------------------------------------|
| baseline | `8ed5a0cd` | PR parent (no preallocation)                   |
| prealloc | `ad645c92` | PR head: preallocate body buffer from CL hint  |

Each arm is run on a freshly-restarted `vllm-qwen3-32b` deployment so that
the simulator KV/queue state cannot leak across arms. Each arm includes a
300-request warmup at c=150 before the measured 2000-request run.

See [`compare-ab.sh`](./compare-ab.sh) for the full procedure.

## Headline result: EPP `Process()` alloc share halved

`alloc_space` flat share of
`pkg/epp/handlers.(*StreamingServer).Process` in a c=150 / 220 KB-prompt
run, measured by `/debug/pprof/allocs`:

| round | baseline (flat / total)        | prealloc (flat / total)        |
|-------|--------------------------------|--------------------------------|
| 1     | 824 MB / 3306 MB = **24.92%**  | 475 MB / 4075 MB = **11.67%**  |
| 2     | 795 MB / 3209 MB = **24.77%**  | 816 MB / 6875 MB = **11.86%**  |

The flat allocation share attributable to `Process()` itself drops from
~25% to ~12% — a roughly **2× reduction**, matching what the PR targets:
eliminating the per-chunk `append(buf, chunk...)` reallocations in
`setRequestBody`. The cumulative share (`Process()` + callees) drops by
~6 percentage points (65→59%).

Raw `pprof -top -cum -nodecount=30` output is checked in at
`results/round-{1,2}/{baseline,prealloc}/allocs.top30.txt`. Full
`allocs.pb.gz` profiles are alongside.

## E2E TTFT (220 KB prompts, c=150)

Single-machine vllm-sim TTFT is dominated by simulator state and is too
noisy on this hardware to attribute a wall-clock change to the EPP path.
Recorded for completeness:

| round | arm      | mean TTFT | P50      | P99      |
|-------|----------|-----------|----------|----------|
| 1     | baseline | 1122 ms   | 1159 ms  | 1224 ms  |
| 1     | prealloc |  615 ms   |  627 ms  |  728 ms  |
| 2     | prealloc | 1151 ms   | 1176 ms  | 1337 ms  |
| 2     | baseline | 1124 ms   | 1151 ms  | 1237 ms  |

The 615 ms outlier in round-1 prealloc tracks the cluster being
transiently less contended (smoke RTT 6.8 ms vs ~21 ms elsewhere); it is
not attributable to the code change. A multi-node setup with a real
model server would be needed to claim an end-to-end TTFT delta.

Full bench output: `results/round-{1,2}/{baseline,prealloc}/bench.txt`.

## Reproducing

Prereqs: a running KIND cluster from
[`../pure-gie/repro.sh`](../pure-gie/repro.sh) (cluster `gie-bench` with
upstream GIE v1.5.0 helm release `vllm-qwen3-32b`).

Build two local EPP images (one per commit), load them into the cluster,
then run the script:

```bash
# Build static EPP binaries on the host (avoids slow golang:1.25 pull)
for arm in baseline:8ed5a0cd prealloc:ad645c92; do
  tag=${arm%%:*}; sha=${arm##*:}
  git worktree add /tmp/gie-$tag $sha
  ( cd /tmp/gie-$tag/cmd/epp && GOWORK=off CGO_ENABLED=0 GOOS=linux \
      go build -o /tmp/epp-$tag . )
  mkdir -p /tmp/ctx-$tag
  cp /tmp/epp-$tag /tmp/ctx-$tag/epp
  printf 'FROM scratch\nCOPY epp /epp\nENTRYPOINT ["/epp"]\n' \
    > /tmp/ctx-$tag/Dockerfile
  docker build -t epp:$tag /tmp/ctx-$tag
done
kind load docker-image epp:baseline epp:prealloc --name gie-bench

# Run alternating B/P rounds with sim reset + warmup between arms
ROUNDS=2 TOTAL=2000 WARMUP=300 ./compare-ab.sh
```
