#!/usr/bin/env bash
# Per-region latency experiment driver (conditions A, B, C). One attempt per request, low rate.
#
#   rlA_r<N>             A: direct, interleaved across the 3 regions, 1.5 req/s total (0.5 per region)
#   rlB_<region>_r<N>    B: direct, one region, 0.5 req/s
#   rlC_<region>_r<N>    C: via APIM pinned to <region>, 0.5 req/s, no circuit breaker, no retry
#
# Usage: bash scripts/run_region_latency.sh rlA_r1 rlB_uksouth_r1 ...
#        bash scripts/run_region_latency.sh restore      # restore default pool/policy and print it
# PIN_MODE=weights (default, 100/0/0) | priority (pinned_region variable). A discarded run is
# re-run as <id>_x2, <id>_x3. A pinned run whose pinning is not confirmed by Azure Monitor stops the driver.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INFRA_DIR="$REPO_ROOT/infra"
source "$INFRA_DIR/.env"

RATE_TOTAL=1.5; RATE_SINGLE=0.5; DURATION_S=640; WARMUP=20
PIN_MODE="${PIN_MODE:-weights}"
RESULTS="$REPO_ROOT/experiment/results"

# retry3 (watchdog + retry) and readback_config are maintained in run_experiments.sh; reuse them
# without running its experiment loop.
eval "$(sed -n '/^retry3()/,/^}/p' "$REPO_ROOT/scripts/run_experiments.sh")"
eval "$(sed -n '/^readback_config()/,/^}/p' "$REPO_ROOT/scripts/run_experiments.sh")"

tf_apply_pool() {  # args: uk we sc weights, then extra terraform args
  local uk=$1 we=$2 sc=$3; shift 3
  ( cd "$INFRA_DIR" && retry3 terraform apply -auto-approve -input=false -no-color \
      -var "gateway_rpm_limit=10000" -var "circuit_breaker_failure_count=0" -var "circuit_breaker_on_429=false" \
      -var "backend_weight_uksouth=$uk" -var "backend_weight_westeurope=$we" -var "backend_weight_swedencentral=$sc" \
      -var "apim_retry_count=0" -var "apim_retry_interval_s=1" -var "backend_priority_fallback=1" \
      ${@+"$@"} | tail -3 )
}

pin_apply() {
  case "$1" in
    uksouth)       w="100 0 0" ;;
    westeurope)    w="0 100 0" ;;
    swedencentral) w="0 0 100" ;;
    *) echo "bad region $1" >&2; return 1 ;;
  esac
  if [ "$PIN_MODE" = "priority" ]; then
    tf_apply_pool 33 33 34 -var "pinned_region=$1"
  else
    tf_apply_pool $w
  fi
}

run_k6() {  # id mode region rate
  local id=$1 mode=$2 region=$3 rate=$4 start end
  start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  k6 run --quiet \
    -e DEPLOYMENT_ID="$DEPLOYMENT_ID" -e RUN_ID="$id" -e MODE="$mode" -e REGION="$region" \
    -e RATE_PER_S="$rate" -e DURATION_S="$DURATION_S" -e WARMUP_PER_REGION="$WARMUP" \
    -e FOUNDRY_ENDPOINT_UKSOUTH="${FOUNDRY_ENDPOINT_UKSOUTH:-}" -e FOUNDRY_KEY_UKSOUTH="${FOUNDRY_KEY_UKSOUTH:-}" \
    -e FOUNDRY_ENDPOINT_WESTEUROPE="${FOUNDRY_ENDPOINT_WESTEUROPE:-}" -e FOUNDRY_KEY_WESTEUROPE="${FOUNDRY_KEY_WESTEUROPE:-}" \
    -e FOUNDRY_ENDPOINT_SWEDENCENTRAL="${FOUNDRY_ENDPOINT_SWEDENCENTRAL:-}" -e FOUNDRY_KEY_SWEDENCENTRAL="${FOUNDRY_KEY_SWEDENCENTRAL:-}" \
    -e APIM_GATEWAY_URL="${APIM_GATEWAY_URL:-}" -e APIM_SUBSCRIPTION_KEY="${APIM_SUBSCRIPTION_KEY:-}" \
    "$REPO_ROOT/experiment/region_latency_test.js" > "$RESULTS/$id.k6.log" 2>&1 || true
  end=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '{"run_id":"%s","mode":"%s","region":"%s","utc_start":"%s","utc_end":"%s","planned_s":%s}\n' \
    "$id" "$mode" "$region" "$start" "$end" "$DURATION_S" > "$RESULTS/$id.meta.json"
  [ -f "$RESULTS/$id.json" ] || { echo "  k6 produced no summary; see $RESULTS/$id.k6.log" >&2; return 1; }
}

attempt_valid() {  # id -> 0 if the stored run is valid (C: also pin-confirmed)
  local id=$1
  [ -f "$RESULTS/$id.json" ] || return 1
  python3 -I "$REPO_ROOT/scripts/region_latency_tables.py" --check "$id" > /dev/null || return 1
  if [[ "$id" == rlC_* ]]; then
    [ -f "$RESULTS/$id.azmon.json" ] && python3 -I -c "import json,sys;sys.exit(0 if json.load(open(sys.argv[1]))['ok'] else 1)" "$RESULTS/$id.azmon.json"
  fi
}

run_one() {
  local id=$1 cond region try tid
  cond=${id:2:1}
  region=$(echo "$id" | sed -E 's/^rl[ABC]_?([a-z]*)_?r[0-9]+.*/\1/')
  for try in 1 2 3; do
    tid=$id; [ "$try" -gt 1 ] && tid="${id}_x${try}"
    if attempt_valid "$tid"; then echo "DRIVER: skip $tid (done, valid)"; return 0; fi
    [ -f "$RESULTS/$tid.json" ] && { echo "DRIVER: $tid exists but is invalid; next attempt"; continue; }

    echo "DRIVER: === $tid ($(date -u +%H:%M:%SZ)) ==="
    case "$cond" in
      A) sleep 60; run_k6 "$tid" interleaved "" "$RATE_TOTAL" ;;
      B) sleep 60; run_k6 "$tid" single "$region" "$RATE_SINGLE" ;;
      C) sleep 10
         pin_apply "$region"
         retry3 readback_config "$tid"
         echo "  settling 120s for the gateway to pick up the pin..."; sleep 120
         run_k6 "$tid" apim "$region" "$RATE_SINGLE"
         echo "  waiting 240s for Azure Monitor lag and run isolation..."; sleep 240
         if ! RUN_SECONDS="$DURATION_S" PAD_BEFORE_S=0 python3 -I "$REPO_ROOT/scripts/region_pin_check.py" "$tid" "$region"; then
           echo "DRIVER: PIN NOT CONFIRMED for $tid; stopping for investigation" >&2; exit 2
         fi ;;
      *) echo "bad id $id" >&2; exit 1 ;;
    esac
    python3 -I "$REPO_ROOT/scripts/region_latency_tables.py" --check "$tid" || true
    if attempt_valid "$tid"; then return 0; fi
    echo "DRIVER: $tid INVALID; will re-run"
  done
  echo "DRIVER: $id failed validity 3 times" >&2; exit 3
}

if [ "${1:-}" = "restore" ]; then
  ( cd "$INFRA_DIR" && retry3 terraform apply -auto-approve -input=false -no-color | tail -3 )
  retry3 readback_config "rl_restore"
  cat "$RESULTS/rl_restore.config.json"
  exit 0
fi

for id in "$@"; do run_one "$id"; done
echo "DRIVER: done: $*"
