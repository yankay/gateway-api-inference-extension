#!/usr/bin/env bash
# Shared helpers for bench/ shell scripts.
#
# Source this file from another bash script:
#   BENCH_LIB="$(cd "$(dirname "$0")/../lib" && pwd)/common.sh"
#   # shellcheck disable=SC1090
#   source "${BENCH_LIB}"
#
# Provides:
#   pick_free_port            echo a random free TCP port in the ephemeral range
#   start_pf  <local> <target...> <logfile>   start a kubectl port-forward, record PID
#   stop_all_pf               kill only the port-forwards started via start_pf
#   wait_port  <local_port>   wait up to ~10s for a port to LISTEN+answer
#   extract_ttft_mean_ms <bench-output-file>  echo TTFT mean (ms) as float, or empty
#   median_float <floats...>  echo median of the inputs (float-aware)
#
# Conventions:
#   - All port-forwards are started with `--address localhost` so they bind
#     both 127.0.0.1 and ::1 (kubectl otherwise picks ONE family, and the
#     other side silently fails to connect).
#   - The list of port-forward PIDs is kept in the bash array __PF_PIDS,
#     populated by start_pf and drained by stop_all_pf. We never `pkill -f`
#     to avoid killing unrelated user port-forwards on shared hosts.
#   - extract_ttft_mean_ms asserts the unit is "ms" (returns empty if seconds
#     or anything else) to catch silent regressions in http-bench output.

# Globals.
__PF_PIDS=()

pick_free_port() {
  # Pick a random free TCP port in the Linux ephemeral range (32768..60999).
  # Uses `ss` to verify the port is not currently in LISTEN state. Retries a
  # handful of times to handle the (small) race between check and use.
  local listening port
  listening="$(ss -ltn 2>/dev/null | awk 'NR>1 { n=split($4,a,":"); print a[n] }' | sort -u)"
  for _ in $(seq 1 32); do
    port=$(( 32768 + RANDOM % (60999 - 32768 + 1) ))
    if ! grep -qx "${port}" <<<"${listening}"; then
      echo "${port}"
      return 0
    fi
  done
  echo "ERROR: pick_free_port: could not find a free local port after 32 tries" >&2
  return 1
}

wait_port() {
  # $1 = local port. Returns 0 if it answers (TCP connect) within ~10s.
  local local_port="$1"
  for _ in $(seq 1 20); do
    sleep 0.5
    if nc -z 127.0.0.1 "${local_port}" 2>/dev/null \
        || nc -z ::1 "${local_port}" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

start_pf() {
  # $1 = local port (chosen by caller)
  # $2 = target spec, e.g. "svc/inference-gateway-istio 8080:80"
  #      (will be word-split into kubectl args; the local port should
  #      already be embedded in the spec).
  # $3 = log file
  local local_port="$1" target="$2" logf="$3"
  # Bind both v4 and v6 explicitly so callers using either 127.0.0.1 or
  # ::1 will hit the listener.
  # shellcheck disable=SC2086 # target intentionally word-split
  kubectl port-forward --address localhost ${target} \
    </dev/null >"${logf}" 2>&1 &
  __PF_PIDS+=("$!")
  if ! wait_port "${local_port}"; then
    echo "ERROR: start_pf: port-forward on :${local_port} did not come up; see ${logf}" >&2
    return 1
  fi
}

stop_all_pf() {
  local pid
  for pid in "${__PF_PIDS[@]:-}"; do
    [[ -n "${pid}" ]] && kill "${pid}" 2>/dev/null || true
  done
  __PF_PIDS=()
}

extract_ttft_mean_ms() {
  # Pull "Mean: 1141.41ms" from the TTFT section of an http-bench run.
  # Echoes the value in milliseconds (float). Echoes empty string and
  # returns non-zero on parse failure OR if the unit is not "ms".
  awk '
    /--- TTFT \/ first response byte ---/ { ttft=1; next }
    ttft && /^Mean:/ {
      # Expect e.g. "Mean:  1141.41ms" or "Mean: 1.14s"
      raw=$2
      if (raw ~ /ms$/) {
        sub(/ms$/, "", raw)
        if (raw+0 == raw) { print raw; exit 0 }
      } else if (raw ~ /s$/) {
        # Seconds — explicitly reject; safer to fail loud than to mis-attribute.
        print "" > "/dev/stderr"
        print "extract_ttft_mean_ms: WARN: TTFT printed in seconds, not ms: " $0 > "/dev/stderr"
        exit 2
      }
      print "" > "/dev/stderr"
      print "extract_ttft_mean_ms: WARN: unrecognised TTFT format: " $0 > "/dev/stderr"
      exit 3
    }
  ' "$1"
}

median_float() {
  # Echoes the median of the float args. For even count, averages the two
  # middle values with %.2f formatting.
  printf '%s\n' "$@" | sort -g | awk -v n="$#" '
    { a[NR]=$1 }
    END {
      if (n == 0) { exit 1 }
      if (n % 2 == 1) { print a[(n+1)/2] }
      else            { printf "%.2f\n", (a[n/2] + a[n/2+1])/2 }
    }
  '
}
