#!/usr/bin/env bash
# Pure upstream Gateway-API-Inference-Extension (GIE) reproduction for the
# EPP large-input TTFT regression. Mirrors ../repro.sh but uses *only*
# upstream GIE v1.5.0 components — no llm-d-inference-scheduler, no
# disagg P/D plugins, no custom EPP config.
#
# What this proves: the heavy lifting (~1 s of TTFT at concurrency=150 with
# a 220 KB prompt) is present in upstream GIE itself, not in any downstream
# fork. The five alloc-space hot spots reported in the issue all resolve
# to functions under sigs.k8s.io/gateway-api-inference-extension.
#
# Requires: kind, kubectl, docker, go 1.25+, helm, curl, istioctl 1.28+.
#
# Run from anywhere:
#   /path/to/bench/pure-gie/repro.sh
#
# The script:
#   1. creates a fresh KIND cluster (gie-bench)
#   2. installs Gateway API + GIE CRDs (v1.5.0)
#   3. installs Istio 1.28 with ENABLE_GATEWAY_API_INFERENCE_EXTENSION=true
#   4. deploys 4x vllm-sim with --max-model-len=65536
#   5. installs the upstream GIE inferencepool helm chart (provider=istio,
#      default plugin config, metrics auth disabled for pprof access)
#   6. applies Gateway + HTTPRoute
#   7. runs an HTTP bench sweep (c=20/60/100/150/200) at 220 KB prompts
#   8. captures pprof allocs/heap/mutex + /metrics into ./out/

set -euo pipefail

BENCH_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${BENCH_DIR}/out"
HTTP_BENCH_DIR="$(cd "${BENCH_DIR}/../http-bench" && pwd)"
mkdir -p "${OUT_DIR}"

CLUSTER="${CLUSTER:-gie-bench}"
GIE_VERSION="${GIE_VERSION:-v1.5.0}"
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.2.1}"
ISTIO_VERSION="${ISTIO_VERSION:-1.28.0}"
NODE_IMAGE="${NODE_IMAGE:-kindest/node:v1.31.0}"

echo "[1/8] create KIND cluster ${CLUSTER}"
if ! kind get clusters | grep -qx "${CLUSTER}"; then
  kind create cluster --name "${CLUSTER}" --image "${NODE_IMAGE}" --wait 120s
fi
kubectl config use-context "kind-${CLUSTER}"

echo "[2/8] install Gateway API + GIE CRDs (${GIE_VERSION})"
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
kubectl apply --server-side \
  -k "github.com/kubernetes-sigs/gateway-api-inference-extension/config/crd?ref=${GIE_VERSION}"

echo "[3/8] install Istio ${ISTIO_VERSION} with GIE inference extension enabled"
if ! command -v istioctl >/dev/null; then
  echo "  istioctl not on PATH; downloading to /tmp/istio-${ISTIO_VERSION}"
  curl -L "https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/istio-${ISTIO_VERSION}-linux-amd64.tar.gz" \
    | tar xz -C /tmp
  export PATH="/tmp/istio-${ISTIO_VERSION}/bin:${PATH}"
fi
istioctl install -y \
  --set values.pilot.env.ENABLE_GATEWAY_API_INFERENCE_EXTENSION=true

echo "[4/8] deploy vllm-sim model server (4 replicas, --max-model-len=65536)"
kubectl apply -f "${BENCH_DIR}/manifests/sim-deployment.yaml"
kubectl rollout status deploy/vllm-qwen3-32b --timeout=180s

echo "[5/8] install upstream GIE EPP via helm chart (provider=istio, default plugins)"
CHART_DIR="$(mktemp -d)/inferencepool"
git clone --depth 1 --branch "${GIE_VERSION}" \
  https://github.com/kubernetes-sigs/gateway-api-inference-extension.git \
  "${CHART_DIR}/.."
helm dependency build "${CHART_DIR}/../config/charts/inferencepool"
helm install vllm-qwen3-32b "${CHART_DIR}/../config/charts/inferencepool" \
  --set provider.name=istio \
  --set inferencePool.modelServers.matchLabels.app=vllm-qwen3-32b \
  --set inferenceExtension.replicas=1 \
  --set inferenceExtension.resources.requests.cpu=2 \
  --set inferenceExtension.resources.requests.memory=4Gi \
  --set inferenceExtension.monitoring.prometheus.auth.enabled=false
kubectl rollout status deploy/vllm-qwen3-32b-epp --timeout=180s

echo "[6/8] apply Gateway + HTTPRoute"
kubectl apply -f "${BENCH_DIR}/manifests/gateway-route.yaml"
sleep 5

echo "[7/8] port-forward Gateway:80 and EPP metrics:9090"
# Detach completely so the script does not hold the port-forward FDs.
setsid -f kubectl port-forward svc/inference-gateway-istio 8080:80 \
  </dev/null >"${OUT_DIR}/pf-gw.log" 2>&1 &
setsid -f kubectl port-forward svc/vllm-qwen3-32b-epp 9090:9090 \
  </dev/null >"${OUT_DIR}/pf-epp.log" 2>&1 &
sleep 3
trap 'pkill -f "kubectl port-forward" 2>/dev/null || true' EXIT

# smoke check
curl -sf -o /dev/null -w "smoke: %{http_code} time=%{time_total}\n" \
  http://localhost:8080/v1/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen3-32B","prompt":"hi","max_tokens":2}'

echo "[8/8] run concurrency sweep (220 KB prompts, c=20/60/100/150/200)"
pushd "${HTTP_BENCH_DIR}" >/dev/null
go build -o "${OUT_DIR}/http-bench" .
popd >/dev/null

for c in 20 60 100 150 200; do
  echo "===== concurrency=${c} ====="
  "${OUT_DIR}/http-bench" \
    --url http://localhost:8080/v1/completions \
    --host bench.local --model Qwen/Qwen3-32B \
    --concurrency "${c}" --total "$((c * 8))" --input-chars 220000 \
    --timeout 120s
  echo
done | tee "${OUT_DIR}/sweep.txt"

echo "[+] capture steady-state pprof during a long c=150 run"
( "${OUT_DIR}/http-bench" \
    --url http://localhost:8080/v1/completions \
    --host bench.local --model Qwen/Qwen3-32B \
    --concurrency 150 --total 4000 --input-chars 220000 \
    --timeout 120s > "${OUT_DIR}/c150-steady-30s.txt" 2>&1 ) &
BENCH_PID=$!
sleep 10  # let the bench reach steady-state, then snapshot
curl -s -o "${OUT_DIR}/allocs-c150-steady.pb.gz"  http://localhost:9090/debug/pprof/allocs
curl -s -o "${OUT_DIR}/heap-c150-steady.pb.gz"   http://localhost:9090/debug/pprof/heap
curl -s -o "${OUT_DIR}/mutex-c150-steady.pb.gz"  http://localhost:9090/debug/pprof/mutex
wait "${BENCH_PID}"

curl -s -o "${OUT_DIR}/epp-metrics-steady.txt"   http://localhost:9090/metrics
go tool pprof -top -cum -nodecount=30 \
  "${OUT_DIR}/allocs-c150-steady.pb.gz" > "${OUT_DIR}/allocs-c150-steady.top30.txt"

echo "Done. Artifacts written to ${OUT_DIR}"
