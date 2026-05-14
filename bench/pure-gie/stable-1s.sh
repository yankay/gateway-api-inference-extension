#!/usr/bin/env bash
# stable-1s.sh — stably reproduce TTFT > 1 s against an upstream GIE EPP.
#
# Assumes the cluster from ./repro.sh is already up (KIND cluster
# gie-bench, 4x vllm-sim, upstream inferencepool helm release, Gateway +
# HTTPRoute). The script manages its OWN `kubectl port-forward`
# processes (on randomly picked free local ports by default) and cleans
# them up on exit, so you do NOT need to leave a `:8080`/`:9090`
# port-forward running between runs — that was the historic footgun
# (stale forward on :9090 left over from a previous EPP pod) and is the
# reason the defaults below pick a random free port instead.
#
# What "stable" means here:
#   1. Fixed parameters in the regime where TTFT>1s has been observed
#      historically (c=150, 220 KB body, upstream v1.5.0 default plugins).
#   2. A warmup phase whose results are discarded — avoids the cold-start
#      outlier (Min~79 ms seen in c150-steady-30s.txt) pulling the mean down.
#   3. N independent measurement rounds; the script reports per-round mean
#      and the **median across rounds** as the stable value.
#   4. A hard assertion on the median: exit non-zero if the median mean TTFT
#      drops below ${THRESHOLD_MS}. Suitable as a CI gate / regression guard.
#
# Tunables (env vars):
#   CONCURRENCY         default 150
#   INPUT_CHARS         default 220000
#   WARMUP_REQS         default 300   (discarded)
#   ROUND_REQS          default 1500  (per measurement round, ~12 s at 130 req/s)
#   ROUNDS              default 3
#   THRESHOLD_MS        default 900   (median-of-means must be >= this)
#   GATEWAY_LOCAL_PORT  default 0     (0 = pick a random free port; host -> svc inference-gateway-istio:80)
#   METRICS_LOCAL_PORT  default 0     (0 = pick a random free port; host -> svc vllm-qwen3-32b-epp:9090)
#   GATEWAY_URL         default http://localhost:${GATEWAY_LOCAL_PORT}/v1/completions
#   METRICS_URL         default http://localhost:${METRICS_LOCAL_PORT}/metrics
#   MODEL               default Qwen/Qwen3-32B
#   HOST                default bench.local
#   OUT_DIR             default ./out/stable-1s

set -euo pipefail

BENCH_DIR="$(cd "$(dirname "$0")" && pwd)"
HTTP_BENCH_DIR="$(cd "${BENCH_DIR}/../http-bench" && pwd)"

CONCURRENCY="${CONCURRENCY:-150}"
INPUT_CHARS="${INPUT_CHARS:-220000}"
WARMUP_REQS="${WARMUP_REQS:-300}"
ROUND_REQS="${ROUND_REQS:-1500}"
ROUNDS="${ROUNDS:-3}"
THRESHOLD_MS="${THRESHOLD_MS:-900}"
# Local ports used by kubectl port-forward. EPP pod-side port is always
# 9090 (and gateway svc port is 80) — these two vars control the *host*
# side. Default `0` means "pick a random free port" — avoids every kind
# of collision (Prometheus on 9090, leftover forward from a previous
# run, another dev server on 8080, etc.). Set to a non-zero value to
# pin the port instead (useful if you want to curl it by hand).
GATEWAY_LOCAL_PORT="${GATEWAY_LOCAL_PORT:-0}"
METRICS_LOCAL_PORT="${METRICS_LOCAL_PORT:-0}"
# GATEWAY_URL / METRICS_URL are only honoured if explicitly set; otherwise
# they are derived after port selection below.
MODEL="${MODEL:-Qwen/Qwen3-32B}"
HOST="${HOST:-bench.local}"
OUT_DIR="${OUT_DIR:-${BENCH_DIR}/out/stable-1s}"

mkdir -p "${OUT_DIR}"

# Pick a random free TCP port in the Linux ephemeral range. Uses `ss`
# (iproute2, default everywhere) to verify the port isn't already in
# LISTEN state. Retries a handful of times to handle races. Echoes the
# chosen port on stdout.
pick_free_port() {
  local listening port
  listening="$(ss -ltn 2>/dev/null | awk 'NR>1 { n=split($4,a,":"); print a[n] }' | sort -u)"
  for _ in $(seq 1 32); do
    # ephemeral range 32768..60999 (default net.ipv4.ip_local_port_range)
    port=$(( 32768 + RANDOM % (60999 - 32768 + 1) ))
    if ! grep -qx "${port}" <<<"${listening}"; then
      echo "${port}"
      return 0
    fi
  done
  echo "ERROR: could not find a free local port after 32 tries" >&2
  return 1
}

if [[ "${GATEWAY_LOCAL_PORT}" == "0" ]]; then
  GATEWAY_LOCAL_PORT="$(pick_free_port)" || exit 2
fi
if [[ "${METRICS_LOCAL_PORT}" == "0" ]]; then
  METRICS_LOCAL_PORT="$(pick_free_port)" || exit 2
  # In the unlikely event the two picks collided.
  while [[ "${METRICS_LOCAL_PORT}" == "${GATEWAY_LOCAL_PORT}" ]]; do
    METRICS_LOCAL_PORT="$(pick_free_port)" || exit 2
  done
fi

GATEWAY_URL="${GATEWAY_URL:-http://localhost:${GATEWAY_LOCAL_PORT}/v1/completions}"
METRICS_URL="${METRICS_URL:-http://localhost:${METRICS_LOCAL_PORT}/metrics}"

echo "[stable-1s] config:"
echo "  concurrency=${CONCURRENCY} input_chars=${INPUT_CHARS}"
echo "  warmup=${WARMUP_REQS} round=${ROUND_REQS} rounds=${ROUNDS}"
echo "  threshold=${THRESHOLD_MS} ms (median-of-means mean TTFT must be >=)"
echo "  gateway=${GATEWAY_URL} (local port ${GATEWAY_LOCAL_PORT} -> svc inference-gateway-istio:80)"
echo "  metrics=${METRICS_URL} (local port ${METRICS_LOCAL_PORT} -> svc vllm-qwen3-32b-epp:9090)"
echo "  out=${OUT_DIR}"
echo

# Self-managed kubectl port-forwards: if the local port is not currently
# answering, start a fresh port-forward, track its PID, and clean up on
# exit. Avoids the classic "EPP pod restarted, my old :9090 forward is a
# zombie and the new one EADDRINUSE-s on 9090" footgun.
PF_PIDS=()
cleanup_pf() {
  for pid in "${PF_PIDS[@]:-}"; do
    [[ -n "${pid}" ]] && kill "${pid}" 2>/dev/null || true
  done
}
trap cleanup_pf EXIT

ensure_pf() {
  # $1 = local port, $2 = svc target (e.g. svc/foo 8088:80), $3 = log file
  local local_port="$1" target="$2" logf="$3"
  if curl -sf -o /dev/null --max-time 2 "http://localhost:${local_port}/" \
      || curl -sf -o /dev/null --max-time 2 "http://localhost:${local_port}/metrics" \
      || nc -z localhost "${local_port}" 2>/dev/null; then
    echo "  port ${local_port} already answering -> reusing existing forward"
    return 0
  fi
  echo "  port ${local_port} not answering -> starting kubectl port-forward (${target})"
  # shellcheck disable=SC2086 # target intentionally word-split
  # --address localhost ensures kubectl binds BOTH 127.0.0.1 and [::1];
  # without it kubectl picks one family and curl/nc on the other side
  # silently misses the listener (observed: bind to [::1] only, while
  # `nc -z localhost` resolves to 127.0.0.1 and reports the port dead).
  kubectl port-forward --address localhost ${target} </dev/null >"${logf}" 2>&1 &
  PF_PIDS+=("$!")
  # Wait up to 10s for the forward to come up.
  for _ in $(seq 1 20); do
    sleep 0.5
    if nc -z localhost "${local_port}" 2>/dev/null; then
      return 0
    fi
  done
  echo "ERROR: port-forward on :${local_port} did not come up; see ${logf}" >&2
  return 1
}

echo "[stable-1s] preflight: ensure port-forwards on :${GATEWAY_LOCAL_PORT} (gateway) and :${METRICS_LOCAL_PORT} (EPP metrics)"
ensure_pf "${GATEWAY_LOCAL_PORT}" \
  "svc/inference-gateway-istio ${GATEWAY_LOCAL_PORT}:80" \
  "${OUT_DIR}/pf-gateway.log" || exit 2
ensure_pf "${METRICS_LOCAL_PORT}" \
  "svc/vllm-qwen3-32b-epp ${METRICS_LOCAL_PORT}:9090" \
  "${OUT_DIR}/pf-metrics.log" || exit 2

echo "[stable-1s] preflight: gateway + EPP metrics reachable?"
if ! curl -sf -o /dev/null -w "  gateway smoke: HTTP %{http_code} t=%{time_total}s\n" \
       "${GATEWAY_URL}" -H "Host: ${HOST}" -H 'Content-Type: application/json' \
       -d "{\"model\":\"${MODEL}\",\"prompt\":\"hi\",\"max_tokens\":2}"; then
  echo "ERROR: gateway not reachable at ${GATEWAY_URL}." >&2
  echo "       Make sure ./repro.sh has been run and the cluster is up." >&2
  exit 2
fi
if ! curl -sf -o /dev/null -w "  metrics smoke: HTTP %{http_code}\n" "${METRICS_URL}"; then
  echo "WARNING: EPP metrics not reachable at ${METRICS_URL} (continuing anyway)." >&2
fi
echo

echo "[stable-1s] build http-bench"
pushd "${HTTP_BENCH_DIR}" >/dev/null
# http-bench is a standalone module; the repo-level go.work would otherwise
# fail the build ("-mod may only be set to readonly or vendor in workspace
# mode"). Disable workspace mode for this build only.
GOWORK=off go build -o "${OUT_DIR}/http-bench" .
popd >/dev/null

run_bench() {
  # $1 = label, $2 = total reqs, $3 = output file
  local label="$1" total="$2" out="$3"
  "${OUT_DIR}/http-bench" \
    --url "${GATEWAY_URL}" \
    --host "${HOST}" \
    --model "${MODEL}" \
    --concurrency "${CONCURRENCY}" \
    --total "${total}" \
    --input-chars "${INPUT_CHARS}" \
    --metrics "${METRICS_URL}" \
    --timeout 180s \
    > "${out}" 2>&1
}

# Extract "Mean:  1141.41ms" from the TTFT section. http-bench prints two
# "Mean:" lines: the first is TTFT, the second is total latency. We want
# the first one. Returns milliseconds as a float string.
extract_ttft_mean_ms() {
  awk '
    /--- TTFT \/ first response byte ---/ { ttft=1; next }
    ttft && /^Mean:/ {
      # "Mean:  1141.41ms" -> 1141.41
      gsub(/[^0-9.]/, "", $2)
      print $2
      exit
    }
  ' "$1"
}

echo "[stable-1s] warmup (${WARMUP_REQS} reqs, discarded)"
run_bench warmup "${WARMUP_REQS}" "${OUT_DIR}/warmup.txt"
warmup_mean="$(extract_ttft_mean_ms "${OUT_DIR}/warmup.txt" || true)"
echo "  warmup TTFT mean: ${warmup_mean:-n/a} ms (discarded)"
echo

means=()
for r in $(seq 1 "${ROUNDS}"); do
  echo "[stable-1s] round ${r}/${ROUNDS}: ${ROUND_REQS} reqs at c=${CONCURRENCY}"
  out="${OUT_DIR}/round-${r}.txt"
  run_bench "round-${r}" "${ROUND_REQS}" "${out}"
  m="$(extract_ttft_mean_ms "${out}" || true)"
  if [[ -z "${m}" ]]; then
    echo "ERROR: could not parse TTFT mean from ${out}" >&2
    exit 3
  fi
  echo "  round ${r} TTFT mean: ${m} ms"
  means+=("${m}")
done
echo

# Median across rounds.
median_ms="$(printf '%s\n' "${means[@]}" | sort -g | awk -v n="${#means[@]}" '
  { a[NR]=$1 }
  END {
    if (n % 2 == 1) { print a[(n+1)/2] }
    else            { printf "%.2f\n", (a[n/2] + a[n/2+1])/2 }
  }
')"

# Snapshot EPP metrics at the end for evidence.
if curl -sf -o "${OUT_DIR}/epp-metrics-final.txt" "${METRICS_URL}"; then
  echo "  saved EPP metrics snapshot -> ${OUT_DIR}/epp-metrics-final.txt"
fi

# Summary file (machine-readable + human-readable).
{
  echo "stable-1s summary"
  echo "  concurrency=${CONCURRENCY}"
  echo "  input_chars=${INPUT_CHARS}"
  echo "  warmup_reqs=${WARMUP_REQS}"
  echo "  round_reqs=${ROUND_REQS}"
  echo "  rounds=${ROUNDS}"
  echo "  threshold_ms=${THRESHOLD_MS}"
  echo "  gateway_local_port=${GATEWAY_LOCAL_PORT}"
  echo "  metrics_local_port=${METRICS_LOCAL_PORT}"
  echo "  per_round_ttft_mean_ms: ${means[*]}"
  echo "  median_ttft_mean_ms: ${median_ms}"
} | tee "${OUT_DIR}/summary.txt"
echo

# Assertion. Disable -e for the check so we can branch on the exit code.
set +e
awk -v m="${median_ms}" -v t="${THRESHOLD_MS}" \
  'BEGIN { exit !(m+0 >= t+0) }'
rc=$?
set -e
if [[ ${rc} -eq 0 ]]; then
  echo "[stable-1s] PASS: median TTFT mean ${median_ms} ms >= threshold ${THRESHOLD_MS} ms"
  exit 0
else
  echo "[stable-1s] FAIL: median TTFT mean ${median_ms} ms < threshold ${THRESHOLD_MS} ms" >&2
  exit 1
fi
