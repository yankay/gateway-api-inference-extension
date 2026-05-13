#!/usr/bin/env bash
# One-shot reproduction for the EPP large-input TTFT regression.
#
# Requires: kind, kubectl, docker, go 1.25+, helm, kustomize.
#
# Run from the root of a fresh clone of llm-d/llm-d-inference-scheduler:
#   git clone https://github.com/llm-d/llm-d-inference-scheduler
#   cd llm-d-inference-scheduler
#   /path/to/bench/repro.sh
#
# The script:
#   1. installs the bundled EPP config (PD + approx-prefix-cache + always-disagg)
#   2. brings up a KIND cluster with prefill/decode sim backends
#   3. patches the sim deployments to accept 65K-token prompts
#   4. waits for everything to be Ready
#   5. starts a port-forward to the EPP metrics port (for pprof)
#   6. runs the HTTP bench at concurrency=60 and prints TTFT P-tiles
#   7. captures pprof allocs/mutex/goroutine + /metrics into ./out/

set -euo pipefail

BENCH_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${BENCH_DIR}/out"
mkdir -p "${OUT_DIR}"

echo "[1/6] copy EPP config into scheduler repo"
mkdir -p deploy/config
cp "${BENCH_DIR}/epp-config.yaml" deploy/config/bench-pd-epp-config.yaml

echo "[2/6] bring up KIND cluster + PD"
EPP_CONFIG=deploy/config/bench-pd-epp-config.yaml DISAGG_P=true \
  ./scripts/kind-dev-env.sh

echo "[3/6] patch vllm sims to allow 65K-token prompts"
for dep in vllm-p vllm-d; do
  kubectl patch deploy "${dep}" --type=json \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--max-model-len=65536"}]'
done
kubectl rollout status deploy/vllm-p --timeout=180s
kubectl rollout status deploy/vllm-d --timeout=180s

echo "[4/6] wait for EPP pod"
kubectl rollout status deploy/bench-model-endpoint-picker --timeout=180s

echo "[5/6] port-forward EPP metrics on :9090"
kubectl port-forward deploy/bench-model-endpoint-picker 9090:9090 >/tmp/pf.log 2>&1 &
PF_PID=$!
trap 'kill ${PF_PID} 2>/dev/null || true' EXIT
sleep 3

echo "[6/6] run HTTP bench (concurrency=60, 450 requests, 220K-char prompts)"
pushd "${BENCH_DIR}/http-bench" >/dev/null
go run . \
  --url http://localhost:30080/v1/completions \
  --host bench.local \
  --concurrency 60 \
  --total 450 \
  --input-chars 220000 \
  | tee "${OUT_DIR}/http-bench-conc60.txt"
popd >/dev/null

echo "[+] capture pprof + metrics"
curl -s http://localhost:9090/debug/pprof/allocs    -o "${OUT_DIR}/http-allocs-conc60.pb.gz"
curl -s http://localhost:9090/debug/pprof/mutex     -o "${OUT_DIR}/http-mutex-conc60.pb.gz"
curl -s "http://localhost:9090/debug/pprof/goroutine?debug=1" -o "${OUT_DIR}/http-goroutine-conc60.txt"
curl -s http://localhost:9090/metrics               -o "${OUT_DIR}/http-metrics-conc60.txt"

go tool pprof -top -cum -nodecount=40 \
  "${OUT_DIR}/http-allocs-conc60.pb.gz" > "${OUT_DIR}/http-allocs-conc60.top.txt"

echo "Done. Artifacts written to ${OUT_DIR}"
