#!/usr/bin/env bash
# A/B benchmark for PR kubernetes-sigs/gateway-api-inference-extension#2924
# (preallocate EPP request body buffer).
#
# Compares two adjacent commits on the same KIND cluster + same vllm-sim
# backends, swapping only the EPP image:
#
#   baseline = 8ed5a0cd  (PR parent)
#   prealloc = ad645c92  (PR head)
#
# The cluster, vllm-sim deployments, Gateway, HTTPRoute and inferencepool
# helm release are expected to already exist (see ../pure-gie/repro.sh).
# This script just:
#   1. helm upgrade EPP image to baseline
#   2. run an HTTP bench (c=150, 220 KB prompts, 4000 reqs)
#   3. snapshot pprof allocs/heap + EPP /metrics
#   4. repeat for prealloc
#
# Usage:
#   bench/pure-gie-prealloc/compare-ab.sh
#
# Outputs land in ./results/<arm>/.

set -euo pipefail

BENCH_DIR="$(cd "$(dirname "$0")" && pwd)"
HTTP_BENCH_SRC="$(cd "${BENCH_DIR}/../http-bench" && pwd)"
RESULTS_DIR="${BENCH_DIR}/results"
CHART_DIR="${CHART_DIR:-/tmp/opencode/gie-v1.5.0/config/charts/inferencepool}"
RELEASE="${RELEASE:-vllm-qwen3-32b}"
EPP_DEPLOY="${EPP_DEPLOY:-vllm-qwen3-32b-epp}"

CONCURRENCY="${CONCURRENCY:-150}"
TOTAL="${TOTAL:-2000}"
WARMUP="${WARMUP:-300}"
INPUT_CHARS="${INPUT_CHARS:-220000}"
ROUNDS="${ROUNDS:-2}"            # number of B/P alternations
SIM_DEPLOY="${SIM_DEPLOY:-vllm-qwen3-32b}"

BIN="${BENCH_DIR}/.bin/http-bench"
mkdir -p "$(dirname "${BIN}")"
echo "[+] build http-bench"
( cd "${HTTP_BENCH_SRC}" && GOWORK=off go build -o "${BIN}" . )

ensure_pf() {
  if ! ss -tln 2>/dev/null | grep -q ':8080 '; then
    nohup kubectl port-forward svc/inference-gateway-istio 8080:80 \
      >/tmp/pf-gw.log 2>&1 </dev/null & disown
  fi
  if ! ss -tln 2>/dev/null | grep -q ':9090 '; then
    nohup kubectl port-forward "svc/${EPP_DEPLOY}" 9090:9090 \
      >/tmp/pf-epp.log 2>&1 </dev/null & disown
  fi
  sleep 3
}

reset_sim() {
  echo "[reset] restart ${SIM_DEPLOY} to clear backend state"
  kubectl rollout restart "deploy/${SIM_DEPLOY}" >/dev/null
  kubectl rollout status  "deploy/${SIM_DEPLOY}" --timeout=180s
  sleep 5
}

run_arm() {
  local arm="$1" tag="$2" round="$3"
  local out="${RESULTS_DIR}/round-${round}/${arm}"
  mkdir -p "${out}"
  echo "================================================================"
  echo "[round=${round} arm=${arm}] helm upgrade EPP -> epp:${tag}"
  echo "================================================================"
  helm upgrade "${RELEASE}" "${CHART_DIR}" --reuse-values \
    --set inferenceExtension.image.registry=docker.io/library \
    --set inferenceExtension.image.repository=epp \
    --set inferenceExtension.image.tag="${tag}" \
    --set inferenceExtension.image.pullPolicy=Never >/dev/null
  kubectl rollout status "deploy/${EPP_DEPLOY}" --timeout=120s

  # Reset backend so each arm sees a clean sim
  reset_sim

  # Restart port-forwards (pod IPs changed)
  pkill -f "kubectl port-forward" 2>/dev/null || true
  sleep 2
  ensure_pf

  # Smoke
  curl -sf -o /dev/null -w "smoke: %{http_code} time=%{time_total}\n" \
    --max-time 30 http://localhost:8080/v1/completions \
    -H 'Host: bench.local' -H 'Content-Type: application/json' \
    -d '{"model":"Qwen/Qwen3-32B","prompt":"hi","max_tokens":2}' \
    | tee "${out}/smoke.txt"

  # Warmup
  echo "[warmup] ${WARMUP} reqs at c=${CONCURRENCY}"
  "${BIN}" \
    --url http://localhost:8080/v1/completions \
    --host bench.local --model Qwen/Qwen3-32B \
    --concurrency "${CONCURRENCY}" --total "${WARMUP}" \
    --input-chars "${INPUT_CHARS}" --timeout 120s \
    > "${out}/warmup.txt" 2>&1

  # Reset metrics baseline by snapshotting
  curl -s -o "${out}/metrics-before.txt" http://localhost:9090/metrics

  # Bench in background, sample pprof mid-run
  ( "${BIN}" \
      --url http://localhost:8080/v1/completions \
      --host bench.local --model Qwen/Qwen3-32B \
      --concurrency "${CONCURRENCY}" --total "${TOTAL}" \
      --input-chars "${INPUT_CHARS}" --timeout 120s \
      > "${out}/bench.txt" 2>&1 ) &
  local pid=$!
  sleep 8
  curl -s -o "${out}/allocs.pb.gz" http://localhost:9090/debug/pprof/allocs
  curl -s -o "${out}/heap.pb.gz"   http://localhost:9090/debug/pprof/heap
  wait "${pid}"
  curl -s -o "${out}/metrics-after.txt" http://localhost:9090/metrics

  go tool pprof -top -cum -nodecount=30 \
    "${out}/allocs.pb.gz" > "${out}/allocs.top30.txt" 2>/dev/null || true

  echo "[round=${round} arm=${arm}] done"
  awk '/^--- TTFT/,/^--- Total/' "${out}/bench.txt"
}

ensure_pf
for r in $(seq 1 "${ROUNDS}"); do
  # Alternate order each round to balance any residual ordering bias
  if (( r % 2 == 1 )); then
    run_arm baseline baseline "$r"
    run_arm prealloc prealloc "$r"
  else
    run_arm prealloc prealloc "$r"
    run_arm baseline baseline "$r"
  fi
done

echo
echo "=== summary (TTFT block per arm per round) ==="
for f in "${RESULTS_DIR}"/round-*/*/bench.txt; do
  echo "### $f"
  awk '/^--- TTFT/,/^--- Total/' "$f"
done
