#!/usr/bin/env bash
# Run APIM or direct-to-Foundry load-test experiments in sequence.
# Each APIM experiment updates Terraform variables, applies, then runs k6.
# Direct experiments skip Terraform and call Foundry endpoints directly.
#
# Usage:
#   bash scripts/run_experiments.sh                        # run all APIM experiments
#   bash scripts/run_experiments.sh baseline               # run one APIM experiment
#   bash scripts/run_experiments.sh direct_equal           # run a direct experiment
#   bash scripts/run_experiments.sh trip_count_1 sustained_baseline  # run several

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INFRA_DIR="$REPO_ROOT/infra"

source "$INFRA_DIR/.env"

# ---------------------------------------------------------------------------
# run_experiment  id  vus  iter  wt_uk  wt_we  wt_sc  rpm  cb  cb429
#                 apim_retry  apim_retry_s  retry_strategy  max_retries  retry_delay_ms
#
# iter may be an integer (iterations mode) or a duration string e.g. "5m" (duration mode).
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

  # Wait for any prior circuit-breaker trip state to expire before applying.
  # APIM CB state is ephemeral in-memory with PT60S trip duration (set in apim_backends.tf).
  # 60s sleep + terraform apply time (~5-15s) gives a total gap comfortably above PT60S.
  echo "  Waiting 60s for CB state to clear..."
  sleep 60

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
# run_direct_experiment  id  vus  iter  mode  wt_uk  wt_we  wt_sc
#
# Calls direct_test.js (Foundry API key auth, no APIM). No terraform apply needed.
# ---------------------------------------------------------------------------
run_direct_experiment() {
  local id="$1"
  local vus="$2"
  local iter="$3"
  local mode="$4"
  local weight_uk="$5"
  local weight_we="$6"
  local weight_sc="$7"

  echo ""
  echo "========================================"
  echo "  Direct experiment: $id"
  echo "========================================"

  cd "$REPO_ROOT"
  k6 run \
    -e DEPLOYMENT_ID="$DEPLOYMENT_ID" \
    -e FOUNDRY_ENDPOINT_UKSOUTH="$FOUNDRY_ENDPOINT_UKSOUTH" \
    -e FOUNDRY_KEY_UKSOUTH="$FOUNDRY_KEY_UKSOUTH" \
    -e FOUNDRY_ENDPOINT_WESTEUROPE="$FOUNDRY_ENDPOINT_WESTEUROPE" \
    -e FOUNDRY_KEY_WESTEUROPE="$FOUNDRY_KEY_WESTEUROPE" \
    -e FOUNDRY_ENDPOINT_SWEDENCENTRAL="$FOUNDRY_ENDPOINT_SWEDENCENTRAL" \
    -e FOUNDRY_KEY_SWEDENCENTRAL="$FOUNDRY_KEY_SWEDENCENTRAL" \
    -e RUN_ID="$id" \
    -e VUS="$vus" \
    -e ITER="$iter" \
    -e DIRECT_MODE="$mode" \
    -e WEIGHT_UKSOUTH="$weight_uk" \
    -e WEIGHT_WESTEUROPE="$weight_we" \
    -e WEIGHT_SWEDENCENTRAL="$weight_sc" \
    experiment/direct_test.js

  echo "  Done: results written to experiment/results/${id}.json"
}

# ---------------------------------------------------------------------------
# run_adaptive_experiment  id  vus  iter_or_duration  adapt_s  penalty  epsilon
#
# Calls adaptive_test.js (Foundry API key auth, no APIM). Weights start equal
# and are recomputed every adapt_s seconds based on per-VU success/error counts.
# iter_or_duration may be an integer (iterations) or a duration string e.g. "5m".
# ---------------------------------------------------------------------------
run_adaptive_experiment() {
  local id="$1"
  local vus="$2"
  local iter="$3"
  local adapt_s="$4"
  local penalty="$5"
  local epsilon="$6"

  echo ""
  echo "========================================"
  echo "  Adaptive experiment: $id"
  echo "========================================"

  cd "$REPO_ROOT"
  if [[ "$iter" =~ ^[0-9]+[smh]$ ]]; then
    k6 run \
      -e DEPLOYMENT_ID="$DEPLOYMENT_ID" \
      -e FOUNDRY_ENDPOINT_UKSOUTH="$FOUNDRY_ENDPOINT_UKSOUTH" \
      -e FOUNDRY_KEY_UKSOUTH="$FOUNDRY_KEY_UKSOUTH" \
      -e FOUNDRY_ENDPOINT_WESTEUROPE="$FOUNDRY_ENDPOINT_WESTEUROPE" \
      -e FOUNDRY_KEY_WESTEUROPE="$FOUNDRY_KEY_WESTEUROPE" \
      -e FOUNDRY_ENDPOINT_SWEDENCENTRAL="$FOUNDRY_ENDPOINT_SWEDENCENTRAL" \
      -e FOUNDRY_KEY_SWEDENCENTRAL="$FOUNDRY_KEY_SWEDENCENTRAL" \
      -e RUN_ID="$id" \
      -e VUS="$vus" \
      -e DURATION="$iter" \
      -e ADAPT_INTERVAL_S="$adapt_s" \
      -e ERROR_PENALTY="$penalty" \
      -e EPSILON="$epsilon" \
      experiment/adaptive_test.js
  else
    k6 run \
      -e DEPLOYMENT_ID="$DEPLOYMENT_ID" \
      -e FOUNDRY_ENDPOINT_UKSOUTH="$FOUNDRY_ENDPOINT_UKSOUTH" \
      -e FOUNDRY_KEY_UKSOUTH="$FOUNDRY_KEY_UKSOUTH" \
      -e FOUNDRY_ENDPOINT_WESTEUROPE="$FOUNDRY_ENDPOINT_WESTEUROPE" \
      -e FOUNDRY_KEY_WESTEUROPE="$FOUNDRY_KEY_WESTEUROPE" \
      -e FOUNDRY_ENDPOINT_SWEDENCENTRAL="$FOUNDRY_ENDPOINT_SWEDENCENTRAL" \
      -e FOUNDRY_KEY_SWEDENCENTRAL="$FOUNDRY_KEY_SWEDENCENTRAL" \
      -e RUN_ID="$id" \
      -e VUS="$vus" \
      -e ITER="$iter" \
      -e ADAPT_INTERVAL_S="$adapt_s" \
      -e ERROR_PENALTY="$penalty" \
      -e EPSILON="$epsilon" \
      experiment/adaptive_test.js
  fi

  echo "  Done: results written to experiment/results/${id}.json"
}

# ---------------------------------------------------------------------------
# APIM experiment definitions
# Format: "vus iter wt_uk wt_we wt_sc rpm cb cb429 apim_retry apim_retry_s retry_strategy max_retries retry_delay_ms"
# ---------------------------------------------------------------------------

declare -A EXPERIMENTS

# Phase 1 — baseline characterisation
EXPERIMENTS["baseline"]="20 200 33 33 34 10000 0 true 0 1 none 3 500"
EXPERIMENTS["weighted_primary"]="20 200 60 25 15 10000 0 true 0 1 none 3 500"
EXPERIMENTS["circuit_breaker"]="20 200 33 33 34 10000 3 true 0 1 none 3 500"
EXPERIMENTS["gateway_throttle"]="20 200 33 33 34 10 0 true 0 1 none 3 500"
EXPERIMENTS["full_resilience"]="30 300 50 30 20 500 3 true 0 1 none 3 500"
EXPERIMENTS["asymmetric_cb"]="20 200 90 5 5 10000 3 true 0 1 none 3 500"
EXPERIMENTS["cb_5xx_only"]="20 200 33 33 34 10000 3 false 0 1 none 3 500"

# Phase 2a — client-side retry strategies
EXPERIMENTS["retry_immediate"]="20 200 33 33 34 10000 0 true 0 1 immediate 3 500"
EXPERIMENTS["retry_fixed_1s"]="20 200 33 33 34 10000 0 true 0 1 fixed 3 1000"
EXPERIMENTS["retry_backoff"]="20 200 33 33 34 10000 0 true 0 1 backoff 3 500"
EXPERIMENTS["retry_backoff_jitter"]="20 200 33 33 34 10000 0 true 0 1 backoff_jitter 3 500"
EXPERIMENTS["retry_after_header"]="20 200 33 33 34 10000 0 true 0 1 retry_after 3 500"

# Phase 2b — APIM server-side retry
EXPERIMENTS["apim_retry_equal"]="20 200 33 33 34 10000 0 true 3 1 none 3 500"
EXPERIMENTS["apim_retry_cb"]="20 200 33 33 34 10000 3 true 3 1 none 3 500"
EXPERIMENTS["apim_retry_asym"]="20 200 90 5 5 10000 3 true 3 1 none 3 500"

# Phase 3 — optimal configuration candidates
EXPERIMENTS["optimal_equal_client"]="20 200 33 33 34 10000 0 true 0 1 retry_after 3 500"
EXPERIMENTS["optimal_asym_client"]="20 200 90 5 5 10000 3 true 0 1 retry_after 3 500"
EXPERIMENTS["optimal_equal_apim"]="20 200 33 33 34 10000 0 true 3 1 none 3 500"
EXPERIMENTS["optimal_asym_apim"]="20 200 90 5 5 10000 3 true 3 1 none 3 500"
EXPERIMENTS["optimal_combined"]="20 200 90 5 5 10000 3 true 3 1 retry_after 3 500"

# Sustained load — 5-minute duration runs
EXPERIMENTS["sustained_apim_asym"]="20 5m 90 5 5 10000 3 true 3 1 none 3 500"
EXPERIMENTS["sustained_baseline"]="20 5m 33 33 34 10000 0 true 0 1 none 3 500"
EXPERIMENTS["sustained_apim_retry_cb"]="20 5m 33 33 34 10000 3 true 3 1 none 3 500"
EXPERIMENTS["sustained_trip_count_1"]="20 5m 90 5 5 10000 1 true 3 1 none 3 500"
EXPERIMENTS["sustained_cb_only"]="20 5m 33 33 34 10000 3 true 0 1 none 3 500"

# Ablation — winning corner fully decomposed
EXPERIMENTS["asym_retry_no_cb"]="20 200 90 5 5 10000 0 true 3 1 none 3 500"   # skew + retry, CB off
EXPERIMENTS["asym_retry_cb_5xx"]="20 200 90 5 5 10000 3 false 3 1 none 3 500" # skew + retry, CB ignores 429
EXPERIMENTS["weight_70_15_15"]="20 200 70 15 15 10000 3 true 3 1 none 3 500"  # weight sweep
EXPERIMENTS["weight_80_10_10"]="20 200 80 10 10 10000 3 true 3 1 none 3 500"  # weight sweep
EXPERIMENTS["trip_count_1"]="20 200 90 5 5 10000 1 true 3 1 none 3 500"       # CB trips on 1st failure

# ---------------------------------------------------------------------------
# Direct experiment definitions
# Format: "vus iter mode wt_uk wt_we wt_sc"
# ---------------------------------------------------------------------------

declare -A DIRECT_EXPERIMENTS
DIRECT_EXPERIMENTS["direct_sequential"]="20 200 sequential 60 25 15"
DIRECT_EXPERIMENTS["direct_weighted"]="20 200 weighted 60 25 15"
DIRECT_EXPERIMENTS["direct_equal"]="20 200 weighted 33 33 34"   # matched pair with baseline

# ---------------------------------------------------------------------------
# Adaptive experiment definitions
# Format: "vus iter_or_duration adapt_interval_s error_penalty epsilon"
# Weights start equal. Each VU independently adjusts every adapt_interval_s
# seconds based on its own success/error counts (score = success - penalty × errors).
# ---------------------------------------------------------------------------

declare -A ADAPTIVE_EXPERIMENTS
# Burst: 200 iterations. At ~160 goodput the run ends in <2s; the 30s window
# will not fire. This is intentional: it shows cold-start (equal-weight) behaviour
# as the baseline for comparison with the sustained run.
ADAPTIVE_EXPERIMENTS["adaptive_burst"]="20 200 30 5 0.05"
# Sustained: 5 minutes, same adapt interval as burst. Each VU sees ~10 update
# cycles. Compare against sustained_baseline (APIM, equal weights, no CB/retry)
# and direct_equal (static equal weights, direct, burst only).
ADAPTIVE_EXPERIMENTS["adaptive_sustained"]="20 5m 30 5 0.05"

# ---------------------------------------------------------------------------
# Execution
# ---------------------------------------------------------------------------

PHASE1="baseline weighted_primary circuit_breaker gateway_throttle full_resilience asymmetric_cb cb_5xx_only"
PHASE2A="retry_immediate retry_fixed_1s retry_backoff retry_backoff_jitter retry_after_header"
PHASE2B="apim_retry_equal apim_retry_cb apim_retry_asym"
PHASE3="optimal_equal_client optimal_asym_client optimal_equal_apim optimal_asym_apim optimal_combined"
SUSTAINED="sustained_apim_asym sustained_baseline sustained_apim_retry_cb sustained_trip_count_1 sustained_cb_only"
ABLATION="asym_retry_no_cb asym_retry_cb_5xx weight_70_15_15 weight_80_10_10 trip_count_1"
DIRECT="direct_sequential direct_weighted direct_equal"
ADAPTIVE="adaptive_burst adaptive_sustained"

ALL_ORDERED="$PHASE1 $PHASE2A $PHASE2B $PHASE3 $SUSTAINED $ABLATION"

if [ "$#" -gt 0 ]; then
  ORDERED="$*"
else
  ORDERED="$ALL_ORDERED"
fi

for id in $ORDERED; do
  if [ -n "${ADAPTIVE_EXPERIMENTS[$id]+_}" ]; then
    args="${ADAPTIVE_EXPERIMENTS[$id]}"
    read -r vus iter adapt_s penalty epsilon <<< "$args"
    run_adaptive_experiment "$id" "$vus" "$iter" "$adapt_s" "$penalty" "$epsilon"
  elif [ -n "${DIRECT_EXPERIMENTS[$id]+_}" ]; then
    args="${DIRECT_EXPERIMENTS[$id]}"
    read -r vus iter mode wuk wwe wsc <<< "$args"
    run_direct_experiment "$id" "$vus" "$iter" "$mode" "$wuk" "$wwe" "$wsc"
  elif [ -n "${EXPERIMENTS[$id]+_}" ]; then
    args="${EXPERIMENTS[$id]}"
    read -r vus iter wuk wwe wsc rpm cb cb429 apim_retry apim_retry_s retry_strategy max_retries retry_delay_ms <<< "$args"
    run_experiment "$id" "$vus" "$iter" "$wuk" "$wwe" "$wsc" "$rpm" "$cb" \
      "$cb429" "$apim_retry" "$apim_retry_s" "$retry_strategy" "$max_retries" "$retry_delay_ms"
  else
    echo "Unknown experiment id: $id" >&2
    exit 1
  fi
done

echo ""
echo "All experiments complete."
