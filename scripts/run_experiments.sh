#!/usr/bin/env bash
# Run APIM load-test experiments in sequence.
# Each experiment updates Terraform variables, applies, then runs k6.
#
# Usage:
#   bash scripts/run_experiments.sh                       # run all
#   bash scripts/run_experiments.sh gateway_throttle      # run one
#   bash scripts/run_experiments.sh asymmetric_cb cb_5xx_only   # run several

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INFRA_DIR="$REPO_ROOT/infra"

source "$INFRA_DIR/.env"

# ---------------------------------------------------------------------------
# run_experiment  id  vus  iter  wt_uk  wt_we  wt_sc  rpm  cb  cb429
#                 apim_retry  apim_retry_s  retry_strategy  max_retries  retry_delay_ms
#
# Positional args 9-14 are optional; defaults shown below.
# ---------------------------------------------------------------------------
run_experiment() {
  local id="$1"
  local vus="$2"
  local iter="$3"
  local weight_uk="$4"
  local weight_we="$5"
  local weight_sc="$6"
  local rpm="$7"
  local cb="$8"
  local cb429="${9:-true}"
  local apim_retry="${10:-0}"
  local apim_retry_s="${11:-1}"
  local retry_strategy="${12:-none}"
  local max_retries="${13:-3}"
  local retry_delay_ms="${14:-500}"

  echo ""
  echo "========================================"
  echo "  Experiment: $id"
  echo "========================================"

  cd "$INFRA_DIR"
  terraform apply -auto-approve \
    -var "gateway_rpm_limit=$rpm" \
    -var "circuit_breaker_failure_count=$cb" \
    -var "circuit_breaker_on_429=$cb429" \
    -var "backend_weight_uksouth=$weight_uk" \
    -var "backend_weight_westeurope=$weight_we" \
    -var "backend_weight_swedencentral=$weight_sc" \
    -var "apim_retry_count=$apim_retry" \
    -var "apim_retry_interval_s=$apim_retry_s" \
    | tail -5

  cd "$REPO_ROOT"
  # If iter looks like a duration string (e.g. "5m", "300s") use DURATION mode.
  if [[ "$iter" =~ ^[0-9]+[smh]$ ]]; then
    k6 run \
      -e APIM_GATEWAY_URL="$APIM_GATEWAY_URL" \
      -e APIM_SUBSCRIPTION_KEY="$APIM_SUBSCRIPTION_KEY" \
      -e DEPLOYMENT_ID="$DEPLOYMENT_ID" \
      -e RUN_ID="$id" \
      -e VUS="$vus" \
      -e DURATION="$iter" \
      -e RETRY_STRATEGY="$retry_strategy" \
      -e MAX_RETRIES="$max_retries" \
      -e RETRY_DELAY_MS="$retry_delay_ms" \
      experiment/load_test.js
  else
    k6 run \
      -e APIM_GATEWAY_URL="$APIM_GATEWAY_URL" \
      -e APIM_SUBSCRIPTION_KEY="$APIM_SUBSCRIPTION_KEY" \
      -e DEPLOYMENT_ID="$DEPLOYMENT_ID" \
      -e RUN_ID="$id" \
      -e VUS="$vus" \
      -e ITER="$iter" \
      -e RETRY_STRATEGY="$retry_strategy" \
      -e MAX_RETRIES="$max_retries" \
      -e RETRY_DELAY_MS="$retry_delay_ms" \
      experiment/load_test.js
  fi

  echo "  Done: results written to experiment/results/${id}.json"
}

# ---------------------------------------------------------------------------
# Experiment definitions
# Format: "vus iter wt_uk wt_we wt_sc rpm cb cb429 apim_retry apim_retry_s retry_strategy max_retries retry_delay_ms"
# ---------------------------------------------------------------------------

declare -A EXPERIMENTS

# --- Phase 1: baseline characterisation (already run) ---
EXPERIMENTS["baseline"]="20 200 33 33 34 10000 0 true 0 1 none 3 500"
EXPERIMENTS["weighted_primary"]="20 200 60 25 15 10000 0 true 0 1 none 3 500"
EXPERIMENTS["circuit_breaker"]="20 200 33 33 34 10000 3 true 0 1 none 3 500"
EXPERIMENTS["gateway_throttle"]="20 200 33 33 34 10 0 true 0 1 none 3 500"
EXPERIMENTS["full_resilience"]="30 300 50 30 20 500 3 true 0 1 none 3 500"
EXPERIMENTS["asymmetric_cb"]="20 200 90 5 5 10000 3 true 0 1 none 3 500"
EXPERIMENTS["cb_5xx_only"]="20 200 33 33 34 10000 3 false 0 1 none 3 500"

# --- Phase 2a: client-side retry strategies (equal weights, no CB, no APIM retry) ---
# retry_strategy controls k6 behaviour on 429. max_retries=3, base delay=500ms.
EXPERIMENTS["retry_immediate"]="20 200 33 33 34 10000 0 true 0 1 immediate 3 500"
EXPERIMENTS["retry_fixed_1s"]="20 200 33 33 34 10000 0 true 0 1 fixed 3 1000"
EXPERIMENTS["retry_backoff"]="20 200 33 33 34 10000 0 true 0 1 backoff 3 500"
EXPERIMENTS["retry_backoff_jitter"]="20 200 33 33 34 10000 0 true 0 1 backoff_jitter 3 500"
EXPERIMENTS["retry_after_header"]="20 200 33 33 34 10000 0 true 0 1 retry_after 3 500"

# --- Phase 2b: APIM server-side retry (client retry disabled) ---
# apim_retry=3 means APIM retries the backend pool up to 3× before surfacing error to client.
EXPERIMENTS["apim_retry_equal"]="20 200 33 33 34 10000 0 true 3 1 none 3 500"
EXPERIMENTS["apim_retry_cb"]="20 200 33 33 34 10000 3 true 3 1 none 3 500"
EXPERIMENTS["apim_retry_asym"]="20 200 90 5 5 10000 3 true 3 1 none 3 500"

# --- Phase 3: optimal configuration candidates (filled after Phase 2 results) ---
# Placeholder values — update wt_*, retry_strategy, apim_retry based on Phase 2 winners.
# Phase 3: best client strategy = retry_after (winner of Phase 2a)
# optimal_equal_apim and optimal_asym_apim already captured by apim_retry_equal / apim_retry_asym
EXPERIMENTS["optimal_equal_client"]="20 200 33 33 34 10000 0 true 0 1 retry_after 3 500"
EXPERIMENTS["optimal_asym_client"]="20 200 90 5 5 10000 3 true 0 1 retry_after 3 500"
EXPERIMENTS["optimal_equal_apim"]="20 200 33 33 34 10000 0 true 3 1 none 3 500"
EXPERIMENTS["optimal_asym_apim"]="20 200 90 5 5 10000 3 true 3 1 none 3 500"
# Combined: client retry_after on top of the already-100% APIM+CB stack
EXPERIMENTS["optimal_combined"]="20 200 90 5 5 10000 3 true 3 1 retry_after 3 500"

# Execution order (Phase 1 runs are already complete; listed here for reference).
PHASE1="baseline weighted_primary circuit_breaker gateway_throttle full_resilience asymmetric_cb cb_5xx_only"
PHASE2A="retry_immediate retry_fixed_1s retry_backoff retry_backoff_jitter retry_after_header"
PHASE2B="apim_retry_equal apim_retry_cb apim_retry_asym"
# --- Sustained load: 5 min duration covers 5 × 60s quota windows ---
# Tests CB trip-reset cycle and whether apim_retry_asym holds up beyond a single burst.
EXPERIMENTS["sustained_apim_asym"]="20 5m 90 5 5 10000 3 true 3 1 none 3 500"

PHASE3="optimal_equal_client optimal_asym_client optimal_equal_apim optimal_asym_apim optimal_combined"
SUSTAINED="sustained_apim_asym"

ALL_ORDERED="$PHASE1 $PHASE2A $PHASE2B $PHASE3"

if [ "$#" -gt 0 ]; then
  ORDERED="$*"
else
  ORDERED="$ALL_ORDERED"
fi

for id in $ORDERED; do
  if [ -z "${EXPERIMENTS[$id]+_}" ]; then
    echo "Unknown experiment id: $id" >&2
    exit 1
  fi
  args="${EXPERIMENTS[$id]}"
  read -r vus iter wuk wwe wsc rpm cb cb429 apim_retry apim_retry_s retry_strategy max_retries retry_delay_ms <<< "$args"

  if [ "$retry_strategy" = "PLACEHOLDER" ]; then
    echo "Skipping $id — Phase 3 placeholder not yet filled in." >&2
    continue
  fi

  run_experiment "$id" "$vus" "$iter" "$wuk" "$wwe" "$wsc" "$rpm" "$cb" \
    "$cb429" "$apim_retry" "$apim_retry_s" "$retry_strategy" "$max_retries" "$retry_delay_ms"
done

echo ""
echo "All experiments complete."
