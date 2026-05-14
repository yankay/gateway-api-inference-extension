#!/usr/bin/env bash
# A/B benchmark for kubernetes-sigs/gateway-api-inference-extension PR #2924
# (preallocate EPP request body buffer).
#
# Compares two adjacent commits on the same KIND cluster + same vllm-sim
# backends, swapping ONLY the EPP image:
#
#   baseline = 8ed5a0cd  (PR parent)
#   prealloc = ad645c92  (PR head)
#
# Differences vs. the earlier version of this script:
#
#   1. Random ephemeral local ports (like stable-1s.sh) instead of hardcoded
#      :8080 / :9090 — eliminates the "leftover forward / Prometheus on 9090"
#      footgun that could route /debug/pprof/allocs to the wrong process.
#   2. Port-forwards are tracked by PID; cleanup never uses `pkill -f
#      "kubectl port-forward"` (which kills the user's unrelated forwards).
#   3. After every helm upgrade we explicitly verify the running EPP pod's
#      image actually matches the tag we asked for, before measuring.
#   4. After `kubectl rollout restart` of the sim, we poll EPP /metrics for
#      a non-zero `inference_pool_ready_pods` (or fall back to readiness
#      checks) instead of sleeping a fixed 5 s.
#   5. allocs are taken as a DELTA: snapshot before the measured run and
#      after, then `pprof -base before after` so warmup allocations don't
#      pollute the attribution.
#   6. Multiple measurement rounds per arm with median-of-means, plus a
#      hard assertion that baseline saturated TTFT >= TTFT_THRESHOLD_MS
#      (otherwise the A/B is invalid and we exit 5).
#   7. Per-arm metrics.json with machine-readable headline numbers, plus
#      a compare.md summary table at the end.
#
# Required environment:
#   - kind cluster `gie-bench` from ../pure-gie/repro.sh
#   - helm release `vllm-qwen3-32b` (upstream inferencepool chart v1.5.0)
#   - two EPP images loaded into the cluster:
#       docker.io/library/epp:baseline  (built from PR parent 8ed5a0cd)
#       docker.io/library/epp:prealloc  (built from PR head   ad645c92)
#     See ./README.md for the build steps.
#
# Tunables (env vars):
#   ROUNDS                default 2     number of B/P alternations
#   ROUND_REQS            default 1500  per measurement round
#   WARMUP_REQS           default 300
#   CONCURRENCY           default 1200  (calibrated for fast multi-core host)
#   INPUT_CHARS           default 220000
#   TTFT_THRESHOLD_MS     default 1100  baseline median TTFT must clear this
#   BASELINE_TAG          default baseline
#   PREALLOC_TAG          default prealloc
#   RELEASE               default vllm-qwen3-32b
#   EPP_DEPLOY            default vllm-qwen3-32b-epp
#   SIM_DEPLOY            default vllm-qwen3-32b
#   CHART_DIR             default auto-clone v1.5.0 to /tmp/gie-chart-cache
#   MODEL                 default Qwen/Qwen3-32B
#   HOST                  default bench.local
#   GIE_VERSION           default v1.5.0
#   SKIP_IMAGE_PRECHECK   default unset (set to skip "image exists in kind" check)
#
# Exit codes:
#   0  A/B completed, verdict written to compare.md
#   2  preflight failed (cluster / helm / images / chart missing)
#   3  port-forward could not be started
#   4  pod image tag after helm upgrade does not match requested tag
#   5  baseline did not saturate TTFT (>= TTFT_THRESHOLD_MS) — A/B invalid
#   6  TTFT parse failure

set -euo pipefail

BENCH_DIR="$(cd "$(dirname "$0")" && pwd)"
HTTP_BENCH_SRC="$(cd "${BENCH_DIR}/../http-bench" && pwd)"
LIB_DIR="$(cd "${BENCH_DIR}/../lib" && pwd)"
# shellcheck disable=SC1091
source "${LIB_DIR}/common.sh"

ROUNDS="${ROUNDS:-2}"
ROUND_REQS="${ROUND_REQS:-1500}"
WARMUP_REQS="${WARMUP_REQS:-300}"
CONCURRENCY="${CONCURRENCY:-1200}"
INPUT_CHARS="${INPUT_CHARS:-220000}"
TTFT_THRESHOLD_MS="${TTFT_THRESHOLD_MS:-1100}"
BASELINE_TAG="${BASELINE_TAG:-baseline}"
PREALLOC_TAG="${PREALLOC_TAG:-prealloc}"
RELEASE="${RELEASE:-vllm-qwen3-32b}"
EPP_DEPLOY="${EPP_DEPLOY:-vllm-qwen3-32b-epp}"
SIM_DEPLOY="${SIM_DEPLOY:-vllm-qwen3-32b}"
MODEL="${MODEL:-Qwen/Qwen3-32B}"
HOST="${HOST:-bench.local}"
GIE_VERSION="${GIE_VERSION:-v1.5.0}"
CHART_DIR="${CHART_DIR:-}"
CHART_CACHE_DIR="${CHART_CACHE_DIR:-/tmp/gie-chart-cache-${GIE_VERSION}}"

RESULTS_ROOT="${BENCH_DIR}/results"
RUN_TS="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="${RESULTS_ROOT}/run-${RUN_TS}"
mkdir -p "${RUN_DIR}"

# Pick host ports up front so we can put them in the config banner.
GATEWAY_LOCAL_PORT="$(pick_free_port)" || exit 3
METRICS_LOCAL_PORT="$(pick_free_port)" || exit 3
while [[ "${METRICS_LOCAL_PORT}" == "${GATEWAY_LOCAL_PORT}" ]]; do
  METRICS_LOCAL_PORT="$(pick_free_port)" || exit 3
done

GATEWAY_URL="http://localhost:${GATEWAY_LOCAL_PORT}/v1/completions"
METRICS_BASE="http://localhost:${METRICS_LOCAL_PORT}"

BIN="${BENCH_DIR}/.bin/http-bench"
mkdir -p "$(dirname "${BIN}")"

cleanup() { stop_all_pf; }
trap cleanup EXIT

log() { printf '[compare-ab] %s\n' "$*"; }

# -----------------------------------------------------------------------------
# Preflight.
# -----------------------------------------------------------------------------

preflight() {
  log "preflight: kind cluster + helm release + EPP images + chart dir"

  local current_ctx
  current_ctx="$(kubectl config current-context 2>/dev/null || true)"
  if [[ "${current_ctx}" != "kind-gie-bench" ]]; then
    log "WARN: current kube-context is '${current_ctx}', expected 'kind-gie-bench'"
    log "      attempting to switch"
    kubectl config use-context kind-gie-bench >/dev/null || {
      log "ERROR: kube-context kind-gie-bench not found" >&2
      exit 2
    }
  fi

  if ! helm list -f "^${RELEASE}\$" -q | grep -qx "${RELEASE}"; then
    log "ERROR: helm release '${RELEASE}' not found (run ../pure-gie/repro.sh first)" >&2
    exit 2
  fi

  if [[ -z "${SKIP_IMAGE_PRECHECK:-}" ]]; then
    local missing=()
    local node="gie-bench-control-plane"
    local in_kind
    in_kind="$(docker exec "${node}" crictl images 2>/dev/null | awk '/^docker\.io\/library\/epp/ { print $2 }' | sort -u)"
    grep -qx "${BASELINE_TAG}" <<<"${in_kind}" || missing+=("epp:${BASELINE_TAG}")
    grep -qx "${PREALLOC_TAG}" <<<"${in_kind}" || missing+=("epp:${PREALLOC_TAG}")
    if (( ${#missing[@]} > 0 )); then
      log "ERROR: required EPP images not loaded into kind node '${node}': ${missing[*]}" >&2
      log "       see ./README.md for the build + 'kind load docker-image' steps" >&2
      exit 2
    fi
  fi

  if [[ -z "${CHART_DIR}" ]]; then
    CHART_DIR="${CHART_CACHE_DIR}/config/charts/inferencepool"
    if [[ ! -d "${CHART_DIR}" ]]; then
      log "chart cache miss; cloning ${GIE_VERSION} into ${CHART_CACHE_DIR}"
      rm -rf "${CHART_CACHE_DIR}"
      git clone --depth 1 --branch "${GIE_VERSION}" \
        https://github.com/kubernetes-sigs/gateway-api-inference-extension.git \
        "${CHART_CACHE_DIR}" >/dev/null
      helm dependency build "${CHART_DIR}" >/dev/null
    fi
  fi
  if [[ ! -d "${CHART_DIR}" ]]; then
    log "ERROR: chart dir '${CHART_DIR}' does not exist" >&2
    exit 2
  fi

  log "build http-bench"
  ( cd "${HTTP_BENCH_SRC}" && GOWORK=off go build -o "${BIN}" . )
}

write_config_txt() {
  {
    echo "run_ts=${RUN_TS}"
    echo "host_kernel=$(uname -srm)"
    echo "host_cpus=$(nproc)"
    echo "kube_context=$(kubectl config current-context)"
    echo "helm_release=${RELEASE}"
    echo "epp_deploy=${EPP_DEPLOY}"
    echo "sim_deploy=${SIM_DEPLOY}"
    echo "chart_dir=${CHART_DIR}"
    echo "baseline_tag=${BASELINE_TAG}"
    echo "prealloc_tag=${PREALLOC_TAG}"
    echo "concurrency=${CONCURRENCY}"
    echo "input_chars=${INPUT_CHARS}"
    echo "warmup_reqs=${WARMUP_REQS}"
    echo "round_reqs=${ROUND_REQS}"
    echo "rounds=${ROUNDS}"
    echo "ttft_threshold_ms=${TTFT_THRESHOLD_MS}"
    echo "gateway_local_port=${GATEWAY_LOCAL_PORT}"
    echo "metrics_local_port=${METRICS_LOCAL_PORT}"
    echo "git_head_sha=$(git -C "${BENCH_DIR}" rev-parse HEAD)"
  } > "${RUN_DIR}/config.txt"
}

# -----------------------------------------------------------------------------
# Per-arm operations.
# -----------------------------------------------------------------------------

# Restart EPP port-forwards. Used after helm upgrade (pod IP changed).
refresh_port_forwards() {
  stop_all_pf
  sleep 1
  start_pf "${GATEWAY_LOCAL_PORT}" \
    "svc/inference-gateway-istio ${GATEWAY_LOCAL_PORT}:80" \
    "${RUN_DIR}/pf-gateway.log" || exit 3
  start_pf "${METRICS_LOCAL_PORT}" \
    "svc/${EPP_DEPLOY} ${METRICS_LOCAL_PORT}:9090" \
    "${RUN_DIR}/pf-metrics.log" || exit 3
}

verify_pod_image_tag() {
  # $1 = expected tag
  # Robust against varying label conventions (chart label may be
  # `app=vllm-qwen3-32b-epp`, `inferencepool=...`, or
  # `app.kubernetes.io/instance=...`). Read from the Deployment spec
  # (always present) AND verify the most recent running pod's image
  # matches the same tag.
  local want="$1" deploy_image pod_image pod_name
  deploy_image="$(kubectl get deploy "${EPP_DEPLOY}" \
                    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  if [[ "${deploy_image}" != *":${want}" ]]; then
    log "ERROR: deploy/${EPP_DEPLOY} image is '${deploy_image}', expected tag '${want}'" >&2
    exit 4
  fi
  # Find any running pod owned by this deployment.
  pod_name="$(kubectl get pod \
                -l "inferencepool=${EPP_DEPLOY}" \
                -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}' \
                2>/dev/null | head -1)"
  if [[ -z "${pod_name}" ]]; then
    # Fall back to deployment-driven pod lookup via owner reference.
    pod_name="$(kubectl get pod \
                  -o jsonpath="{range .items[?(@.metadata.ownerReferences[0].kind=='ReplicaSet')]}{.metadata.name} {.spec.containers[0].image}{\"\n\"}{end}" \
                  2>/dev/null | awk -v want=":${want}\$" '$2 ~ want { print $1; exit }')"
  fi
  if [[ -z "${pod_name}" ]]; then
    log "  WARN: could not locate a running EPP pod to confirm image; deploy spec OK"
    return 0
  fi
  pod_image="$(kubectl get pod "${pod_name}" \
                  -o jsonpath='{.spec.containers[0].image}' 2>/dev/null || true)"
  if [[ "${pod_image}" != *":${want}" ]]; then
    log "ERROR: pod ${pod_name} image is '${pod_image}', expected tag '${want}'" >&2
    exit 4
  fi
  log "  EPP image verified: ${pod_image} (pod ${pod_name})"
}

reset_sim_and_wait() {
  # Restart the sim deployment so each arm sees a clean backend, then wait
  # until all sim pods are Ready and EPP /metrics reports a populated pool.
  log "reset sim ${SIM_DEPLOY} (rollout restart)"
  kubectl rollout restart "deploy/${SIM_DEPLOY}" >/dev/null
  kubectl rollout status  "deploy/${SIM_DEPLOY}" --timeout=180s >/dev/null

  # Wait for EPP to (re)discover the sim endpoints. Upstream v1.5.0 EPP
  # does NOT expose `inference_pool_ready_pods`; instead it exports
  # per-pod gauges (e.g. `inference_pool_per_pod_queue_size{...,
  # model_server_pod="..."}`). Treat "at least one such labelled sample
  # for SIM_DEPLOY" as discovery confirmation.
  local i metrics expected_replicas seen
  expected_replicas="$(kubectl get deploy "${SIM_DEPLOY}" \
                         -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 1)"
  for i in $(seq 1 30); do
    metrics="$(curl -s --max-time 3 "${METRICS_BASE}/metrics" 2>/dev/null || true)"
    seen="$(grep -cE "^inference_pool_per_pod_queue_size\{[^}]*model_server_pod=\"${SIM_DEPLOY}-" \
              <<<"${metrics}" || true)"
    if [[ "${seen:-0}" -ge "${expected_replicas:-1}" ]]; then
      log "  EPP sees ${seen} ${SIM_DEPLOY} endpoints (>= ${expected_replicas}; after ~${i}s)"
      return 0
    fi
    sleep 1
  done
  log "  WARN: EPP only sees ${seen:-0}/${expected_replicas} ${SIM_DEPLOY} endpoints after 30s; continuing"
}

run_bench() {
  # $1 = total reqs, $2 = output file
  "${BIN}" \
    --url "${GATEWAY_URL}" \
    --host "${HOST}" \
    --model "${MODEL}" \
    --concurrency "${CONCURRENCY}" \
    --total "$1" \
    --input-chars "${INPUT_CHARS}" \
    --metrics "${METRICS_BASE}/metrics" \
    --timeout 180s \
    > "$2" 2>&1
}

run_arm() {
  # $1 = arm label (baseline|prealloc), $2 = image tag, $3 = round index
  local arm="$1" tag="$2" round="$3"
  local out="${RUN_DIR}/round-${round}/${arm}"
  mkdir -p "${out}"

  log ""
  log "================================================================"
  log "round=${round} arm=${arm}: helm upgrade EPP -> epp:${tag}"
  log "================================================================"

  helm upgrade "${RELEASE}" "${CHART_DIR}" --reuse-values \
    --set inferenceExtension.image.registry=docker.io/library \
    --set inferenceExtension.image.repository=epp \
    --set inferenceExtension.image.tag="${tag}" \
    --set inferenceExtension.image.pullPolicy=Never \
    --wait \
    --timeout 3m >/dev/null
  kubectl rollout status "deploy/${EPP_DEPLOY}" --timeout=180s >/dev/null

  # New EPP pod -> new pod IP -> existing port-forward is stale.
  refresh_port_forwards
  verify_pod_image_tag "${tag}"

  # Capture pod yaml for forensic trail (best-effort: don't fail the
  # whole run if labels differ in some chart fork).
  {
    kubectl get pod -l "inferencepool=${EPP_DEPLOY}" -o yaml 2>/dev/null \
      || kubectl get pod -l "app.kubernetes.io/instance=${RELEASE}" -o yaml 2>/dev/null \
      || kubectl get deploy "${EPP_DEPLOY}" -o yaml 2>/dev/null \
      || true
  } > "${out}/pod.yaml"

  # Reset backend, wait for EPP to see it.
  reset_sim_and_wait
  # Sim deployment rollout = pod-IP churn = EPP rewires its
  # endpoint slice; the gateway side is unchanged but be defensive.
  refresh_port_forwards
  verify_pod_image_tag "${tag}"

  log "smoke check"
  curl -sf -o /dev/null -w "  smoke: HTTP %{http_code} time=%{time_total}s\n" \
    --max-time 30 "${GATEWAY_URL}" \
    -H "Host: ${HOST}" -H 'Content-Type: application/json' \
    -d "{\"model\":\"${MODEL}\",\"prompt\":\"hi\",\"max_tokens\":2}" \
    | tee "${out}/smoke.txt"

  log "warmup (${WARMUP_REQS} reqs, discarded)"
  run_bench "${WARMUP_REQS}" "${out}/warmup.txt"

  # Allocation profile snapshots: BEFORE the measured run (i.e. after
  # warmup), then AFTER the measured run. The delta is everything
  # attributable to the measured window only.
  curl -s -o "${out}/allocs-before.pb.gz" "${METRICS_BASE}/debug/pprof/allocs"
  curl -s -o "${out}/metrics-before.txt"  "${METRICS_BASE}/metrics"

  # N measurement rounds.
  local means=() r m
  for r in $(seq 1 "${ROUNDS}"); do
    log "round ${r}/${ROUNDS} (arm=${arm}): ${ROUND_REQS} reqs at c=${CONCURRENCY}"
    run_bench "${ROUND_REQS}" "${out}/round-${r}.txt"
    m="$(extract_ttft_mean_ms "${out}/round-${r}.txt" || true)"
    if [[ -z "${m}" ]]; then
      log "ERROR: could not parse TTFT mean from ${out}/round-${r}.txt" >&2
      exit 6
    fi
    log "  round ${r} TTFT mean: ${m} ms"
    means+=("${m}")
  done

  curl -s -o "${out}/allocs-after.pb.gz" "${METRICS_BASE}/debug/pprof/allocs"
  curl -s -o "${out}/heap-after.pb.gz"   "${METRICS_BASE}/debug/pprof/heap"
  curl -s -o "${out}/metrics-after.txt"  "${METRICS_BASE}/metrics"

  # pprof DELTA: subtract the before snapshot. This attributes allocs to
  # the measured window only, not the warmup.
  go tool pprof -top -cum -nodecount=30 \
    -base "${out}/allocs-before.pb.gz" \
    "${out}/allocs-after.pb.gz" \
    > "${out}/allocs-delta.top30.txt" 2>/dev/null || true
  # Also render the absolute "after" profile, for direct comparison against
  # the historical results/round-{1,2} which used the absolute profile.
  go tool pprof -top -cum -nodecount=30 \
    "${out}/allocs-after.pb.gz" \
    > "${out}/allocs-after.top30.txt" 2>/dev/null || true

  # Compute headline numbers for the compare report.
  local median
  median="$(median_float "${means[@]}")"

  # Parse "(*StreamingServer).Process" flat% and cum% from the absolute profile.
  # Format from pprof -top:
  #   "    3.39GB 15.82% 35.30% 10.37GB 48.39%  sigs.k8s.io/.../handlers.(*StreamingServer).Process"
  # The columns are: flat  flat%  sum%  cum  cum%  name.
  local process_line process_flat_pct process_cum_pct total_after_mb
  process_line="$(grep -E '\(\*StreamingServer\)\.Process$' "${out}/allocs-after.top30.txt" \
                  | head -1 || true)"
  process_flat_pct=""; process_cum_pct=""
  if [[ -n "${process_line}" ]]; then
    process_flat_pct="$(awk '{ for (i=1;i<=NF;i++) if ($i ~ /%$/) { print $i; exit } }' \
                       <<<"${process_line}" | tr -d %)"
    # cum% is the 5th token (flat, flat%, sum%, cum, cum%, name…)
    process_cum_pct="$(awk '{ print $5 }' <<<"${process_line}" | tr -d %)"
  fi
  total_after_mb="$(awk '/Total: / { print $2; exit }' "${out}/allocs-after.top30.txt" \
                   | sed -E 's/GB/*1024/; s/MB//' | bc -l 2>/dev/null || echo "")"
  # If sed/bc failed (e.g. profile in kB) just leave it as the raw string from pprof.
  if [[ -z "${total_after_mb}" || "${total_after_mb}" == "0" ]]; then
    total_after_mb="$(awk '/Total: / { print $2; exit }' "${out}/allocs-after.top30.txt")"
  fi

  {
    echo "arm=${arm}"
    echo "image_tag=${tag}"
    echo "round_index=${round}"
    echo "ttft_means_ms: ${means[*]}"
    echo "ttft_median_ms: ${median}"
    echo "process_flat_pct: ${process_flat_pct:-unknown}"
    echo "process_cum_pct: ${process_cum_pct:-unknown}"
    echo "total_alloc_after: ${total_after_mb}"
  } | tee "${out}/summary.txt"

  # Echo a single TSV line into the run-wide table.
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "${round}" "${arm}" "${tag}" "${median}" \
    "${process_flat_pct:-NA}" "${process_cum_pct:-NA}" "${total_after_mb}" \
    >> "${RUN_DIR}/per_arm.tsv"
}

# -----------------------------------------------------------------------------
# Driver.
# -----------------------------------------------------------------------------

preflight

# Initial port-forwards (will be refreshed after each helm upgrade).
start_pf "${GATEWAY_LOCAL_PORT}" \
  "svc/inference-gateway-istio ${GATEWAY_LOCAL_PORT}:80" \
  "${RUN_DIR}/pf-gateway.log" || exit 3
start_pf "${METRICS_LOCAL_PORT}" \
  "svc/${EPP_DEPLOY} ${METRICS_LOCAL_PORT}:9090" \
  "${RUN_DIR}/pf-metrics.log" || exit 3

write_config_txt

log "config:"
log "  rounds=${ROUNDS} round_reqs=${ROUND_REQS} warmup=${WARMUP_REQS}"
log "  concurrency=${CONCURRENCY} input_chars=${INPUT_CHARS}"
log "  ttft_threshold_ms=${TTFT_THRESHOLD_MS} (baseline must clear this or A/B is invalid)"
log "  gateway=${GATEWAY_URL}"
log "  metrics=${METRICS_BASE}/metrics"
log "  out=${RUN_DIR}"

# Header for the TSV.
printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
  round arm tag ttft_median_ms process_flat_pct process_cum_pct total_alloc \
  > "${RUN_DIR}/per_arm.tsv"

# Alternate order each round to balance ordering bias.
for r in $(seq 1 "${ROUNDS}"); do
  if (( r % 2 == 1 )); then
    run_arm baseline "${BASELINE_TAG}" "${r}"
    run_arm prealloc "${PREALLOC_TAG}" "${r}"
  else
    run_arm prealloc "${PREALLOC_TAG}" "${r}"
    run_arm baseline "${BASELINE_TAG}" "${r}"
  fi
done

# -----------------------------------------------------------------------------
# Summarise.
# -----------------------------------------------------------------------------

log ""
log "=== final summary ==="

# Aggregate per arm across rounds: collect each arm's TTFT medians and
# process_flat_pct into arrays, then report cross-round median of those.
aggregate_arm() {
  # $1 = arm label
  awk -v arm="$1" '
    NR == 1 { next }                       # skip header
    $2 == arm {
      ttfts[++nt] = $4
      flats[++nf] = $5
      cums[++nc]  = $6
    }
    END {
      asort(ttfts); asort(flats); asort(cums)
      # median
      med = (nt % 2 == 1) ? ttfts[(nt+1)/2] : (ttfts[nt/2] + ttfts[nt/2+1]) / 2
      medf = (nf == 0) ? "NA" : ((nf % 2 == 1) ? flats[(nf+1)/2] : (flats[nf/2] + flats[nf/2+1]) / 2)
      medc = (nc == 0) ? "NA" : ((nc % 2 == 1) ? cums[(nc+1)/2]  : (cums[nc/2]  + cums[nc/2+1])  / 2)
      printf "%s %s %s\n", med, medf, medc
    }
  ' "${RUN_DIR}/per_arm.tsv"
}

read -r baseline_ttft baseline_flat baseline_cum < <(aggregate_arm baseline)
read -r prealloc_ttft prealloc_flat prealloc_cum < <(aggregate_arm prealloc)

# Compute deltas (use awk for float math; tolerate "NA").
delta_pct() {
  # $1 = baseline value, $2 = new value; returns "(b - n) / b * 100" formatted.
  awk -v b="$1" -v n="$2" 'BEGIN {
    if (b == "NA" || n == "NA" || b+0 == 0) { print "NA"; exit }
    printf "%.1f%%\n", (b - n) / b * 100
  }'
}

flat_drop="$(delta_pct "${baseline_flat}" "${prealloc_flat}")"
cum_drop="$(delta_pct  "${baseline_cum}"  "${prealloc_cum}")"
ttft_drop="$(delta_pct "${baseline_ttft}" "${prealloc_ttft}")"

# Verdict logic:
#   FAIL_INVALID  if baseline TTFT median below threshold.
#   PASS          if process_flat_pct dropped by >= 30%.
#   INCONCLUSIVE  otherwise.
verdict="UNKNOWN"
verdict_reason=""
if awk -v b="${baseline_ttft}" -v t="${TTFT_THRESHOLD_MS}" \
     'BEGIN { exit !(b+0 < t+0) }'; then
  verdict="INVALID"
  verdict_reason="baseline median TTFT ${baseline_ttft} ms < threshold ${TTFT_THRESHOLD_MS} ms — A/B is not interpretable; saturate EPP harder (raise CONCURRENCY/INPUT_CHARS) and re-run."
elif [[ "${flat_drop}" == "NA" ]]; then
  verdict="INCONCLUSIVE"
  verdict_reason="could not parse process_flat_pct from one or both arms; check allocs-after.top30.txt"
else
  drop_value="${flat_drop%\%}"
  if awk -v d="${drop_value}" 'BEGIN { exit !(d+0 >= 30.0) }'; then
    verdict="PASS"
    verdict_reason="(*StreamingServer).Process flat alloc share dropped by ${flat_drop} (>=30%)."
  else
    verdict="INCONCLUSIVE"
    verdict_reason="(*StreamingServer).Process flat alloc share dropped by ${flat_drop} (<30% threshold)."
  fi
fi

{
  echo "# A/B benchmark: PR #2924 (preallocate EPP request body buffer)"
  echo
  echo "Run timestamp: \`${RUN_TS}\` (UTC)"
  echo "Run directory: \`results/run-${RUN_TS}/\`"
  echo
  echo "## Configuration"
  echo
  echo "| key | value |"
  echo "|---|---|"
  echo "| concurrency      | ${CONCURRENCY} |"
  echo "| input_chars      | ${INPUT_CHARS} |"
  echo "| warmup_reqs      | ${WARMUP_REQS} |"
  echo "| round_reqs       | ${ROUND_REQS} |"
  echo "| rounds (B/P alt) | ${ROUNDS} |"
  echo "| baseline tag     | epp:${BASELINE_TAG} |"
  echo "| prealloc tag     | epp:${PREALLOC_TAG} |"
  echo "| ttft_threshold_ms| ${TTFT_THRESHOLD_MS} |"
  echo "| host_cpus        | $(nproc) |"
  echo
  echo "## Headline (median across rounds, per arm)"
  echo
  echo "| metric | baseline | prealloc | drop (baseline - prealloc) |"
  echo "|---|---:|---:|---:|"
  echo "| TTFT median-of-round-means (ms)            | ${baseline_ttft} | ${prealloc_ttft} | ${ttft_drop} |"
  echo "| Process() flat alloc share (%)             | ${baseline_flat} | ${prealloc_flat} | ${flat_drop} |"
  echo "| Process() cum  alloc share (%)             | ${baseline_cum}  | ${prealloc_cum}  | ${cum_drop} |"
  echo
  echo "## Verdict: **${verdict}**"
  echo
  echo "${verdict_reason}"
  echo
  echo "## Per-round raw"
  echo
  echo '```'
  cat "${RUN_DIR}/per_arm.tsv"
  echo '```'
  echo
  echo "## Notes"
  echo
  echo "- Allocation deltas (\`allocs-delta.top30.txt\`) attribute only the"
  echo "  measured window (after warmup); absolute profiles"
  echo "  (\`allocs-after.top30.txt\`) are kept too for direct comparability"
  echo "  with the historical \`results/historical/round-{1,2}/\` numbers."
  echo "- Single-machine vllm-sim TTFT is dominated by simulator state and"
  echo "  EPP request-path overhead; PR #2924 specifically targets the"
  echo "  request-body \`append\` hotspot, so the strongest signal is the"
  echo "  Process() flat alloc share, not TTFT itself."
} > "${RUN_DIR}/compare.md"

log "compare.md written: ${RUN_DIR}/compare.md"
log "verdict: ${verdict}"

case "${verdict}" in
  INVALID)      exit 5 ;;
  PASS)         exit 0 ;;
  INCONCLUSIVE) exit 0 ;;  # still produced a report; non-zero would mask it
  *)            exit 0 ;;
esac
