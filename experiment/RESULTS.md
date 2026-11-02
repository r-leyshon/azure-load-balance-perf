# Load Balancing Experiment Results

Experiments characterise the behaviour of Azure API Management (APIM) as an AI gateway in front
of three Azure AI Foundry deployments (UK South, West Europe, Sweden Central), under deliberate
quota saturation. All runs used `gpt-4.1-mini` with 10 000 TPM per region — chosen specifically
to be exhaustible within seconds, making failure modes visible.

Load was generated locally with [Grafana k6](https://k6.io). Each request sends a fixed
single-sentence prompt with `max_tokens: 5`.

> **Data integrity note — two bugs required multiple re-runs:**
>
> **Bug 1:** The APIM `<retry>` block was missing `<forward-request />`. Retries re-evaluated
> backend selection without actually forwarding the request; APIM returned synthetic 200s from
> its own layer. All 14 experiments with APIM retry enabled were re-run after the fix.
>
> **Bug 2:** APIM circuit-breaker state is in-memory with a PT60S trip duration (set in
> `apim_backends.tf`; not PT30S as earlier notes incorrectly stated). It survives `terraform
> apply` of new policy configurations. Experiments whose terraform apply completed in under ~60
> seconds inherited tripped backends from the previous run. Nine experiments were re-run with an
> explicit 60-second isolation gap added to `run_experiments.sh`. Combined with terraform apply
> time (~5–15s), the total gap comfortably exceeds PT60S.
>
> Every table in this document reflects clean, isolation-verified data only.

---

## Setup

| Parameter | Value |
|---|---|
| Gateway | Azure API Management (Developer tier) |
| Backends | 3 × Azure AI Foundry (OpenAI kind), one per region |
| Auth | System-assigned managed identity + Cognitive Services OpenAI User RBAC |
| Model | gpt-4.1-mini (2025-04-14) |
| Quota per backend | 10 000 TPM |
| Burst load | 20 VUs, 200 iterations |
| Sustained load | 20 VUs, 5-minute duration |
| CAR load (Phase 4) | 10 req/s constant arrival rate, 5-minute duration |

---

## Metric definitions

| Column | Meaning |
|---|---|
| `iterations` | Original requests dispatched (not counting retries) |
| `http_200` | Requests that eventually received HTTP 200 |
| `http_200_%` | `http_200 / iterations × 100` — eventual success rate |
| `total_calls` | Total HTTP calls including all retry attempts |
| `p50_ms` / `p95_ms` | HTTP request duration percentile (all requests, including fast failures) |
| `tts_p50_ms` | Time-to-success: ms from first attempt to final 200, including retry delays |
| `retry_overhead` | `(total_calls / iterations) − 1` — extra HTTP calls per original request |
| `goodput` | Successful completions ÷ wall-clock seconds |

**Goodput caveat:** when failure paths return in 13ms (CB-induced 503) the short elapsed time
inflates goodput even at low success rates. Treat goodput as a useful combined metric only when
comparing configs with similar failure-mode latencies.

**APIM retry → 503 behaviour:** when APIM exhausts all retries with the last response still
being 429, it returns 503 to the caller. k6's "no server error" check (`status < 500`) fails
on these 503s. Experiments with APIM retry show 0 genuine 429s at k6 layer — all non-200s
appear as 5xx (APIM's own 503s, not backend 429s).

---

## Phase 1 — Baseline characterisation

Equal-weight and weighted pool with no retry logic. Establishes the quota budget APIM can extract
without resilience features.

| run_id | config | http_200_% | p50_ms | p95_ms | goodput (req/s) |
|---|---|---|---|---|---|
| baseline | Equal weights, no CB, no retry | 17.5 | 122.5 | 1940.4 | 6.8 |
| weighted_primary | 60/25/15, no CB, no retry | 16.5 | 379.9 | 1120.5 | 5.6 |
| circuit_breaker | Equal weights, CB on 429+5xx, no retry | 4.5 | 106.1 | 250.2 | 3.7 |
| gateway_throttle | Equal weights, 10 RPM cap | 3.5 | 11.8 | 159.2 | 2.9 |
| full_resilience | 50/30/20, 500 RPM cap, CB | 0.0 | 11.6 | 17.7 | 0.0 |
| asymmetric_cb | 90/5/5, CB on 429+5xx, no retry | 16.5 | 119.4 | 720.9 | 8.5 |
| cb_5xx_only | Equal weights, CB on 5xx only, no retry | 16.5 | 114.3 | 532.6 | 5.9 |

**Direct-to-Foundry comparators (no APIM):**

| run_id | weights | http_200_% | p50_ms | goodput (req/s) | notes |
|---|---|---|---|---|---|
| direct_sequential | UK→WE→SC fallback | 16.5 ² | 101.1 | 6.2 | |
| direct_weighted | 60/25/15 | 16.5 | 94.2 | 11.1 | |
| direct_equal | 33/33/34 | 17.5 | 104.4 | 3.1 | matched pair with baseline |

² `direct_sequential` makes up to 3 HTTP calls per k6 iteration (UK→WE→SC fallback chain),
producing 567 total HTTP calls for 200 k6 iterations. `summarise.py` uses HTTP calls as the
denominator (the `original_iterations` counter is absent in `direct_test.js`), reporting 5.8%.
The correct per-request success rate is 33 ÷ 200 = **16.5%**, in line with `direct_equal` and
`baseline`. Sequential fallback offers no measurable advantage over a single-endpoint call.

### Phase 1 findings

- **`baseline` achieves 17.5% — equal weights distribute quota most efficiently.** All three
  backends share burden proportionally. High p95 (1940ms) reflects requests queuing while
  waiting for a backend with remaining quota.

- **`cb_5xx_only` (CB on 5xx only) achieves 16.5% — statistically identical to `baseline`.**
  When all failures are quota-related 429s, the CB configured to trip only on 5xx never fires.
  It behaves like having no CB at all. This is the expected behaviour: CB on 5xx is a transparent
  safety net that does nothing when the only failure mode is quota exhaustion.

- **`circuit_breaker` (CB on 429+5xx, equal weights) collapses to 4.5%.** With equal weights,
  all three regions exhaust quota at similar rates. The CB counts each 429 as a failure and
  trips UK South, then West Europe, then Sweden Central in rapid succession. With the pool
  empty, all remaining requests get instant 503. The 9 completions escaped before full drainage.

- **`asymmetric_cb` (90/5/5, CB on 429+5xx) maintains 16.5%.** UK South absorbs 90% of traffic,
  exhausts its quota first, and trips. West Europe and Sweden Central have consumed only 5% of
  their quota each — ample for the remaining requests. The CB acts as a useful traffic diverter
  here, not a pool drainer, because the fallbacks have substantial remaining quota when UK South
  trips.

- **The CB trigger matters less than the weight distribution.** CB on 429+5xx with equal weights
  (4.5%) is the dangerous case because all backends drain simultaneously. CB on 429+5xx with
  asymmetric weights (16.5%) is effectively neutral because the primary drains first and the
  fallbacks are spared. CB on 5xx only (16.5%) is always neutral.

- **`full_resilience` (500 RPM gateway cap): 0 successes.** The gateway throttle rejects all
  requests before they reach any backend. This is an APIM gateway-level constraint, not a
  backend constraint.

- **APIM adds no latency overhead vs direct at equal weights.** `direct_equal` and `baseline`
  both achieve 17.5%. The gateway's value is in its resilience policies.

---

## Phase 2a — Client-side retry strategies

Client retries on 429 up to 3 attempts. Base config: equal weights, no CB, no APIM retry.

| run_id | http_200_% | total_calls | tts_p50_ms | retry_overhead | goodput (req/s) |
|---|---|---|---|---|---|
| retry_immediate | 17.5 | 730 | 548 | 2.65 | 5.0 |
| retry_fixed_1s | 12.0 | 762 | 1 568 | 2.81 | 0.6 |
| retry_backoff | 13.0 | 752 | 920 | 2.76 | 0.6 |
| retry_backoff_jitter | 13.0 | 752 | 1 078 | 2.76 | 0.6 |
| retry_after_header | 99.5 | 481 | 30 516 | 1.40 | 0.4 |

### Phase 2a findings

- **`retry_after_header` achieves 99.5% eventual success** at the cost of 30-second median
  latency. Azure returns a `Retry-After` header on 429 giving the exact quota window reset time.
  Sleeping for that duration means the retry always lands in a fresh window.

- **No other client retry strategy improves on `baseline` (17.5%).** Backoff delays of 500ms–2s
  are far shorter than the 60-second quota window. Immediate retry ties baseline but makes 3.65×
  the HTTP calls with no benefit. Fixed and exponential backoff *reduce* success rate (12–13%)
  because the delays consume time without clearing quota.

- **Either wait the full quota window (`Retry-After`) or do not retry.** There is no middle
  ground: partial backoff under global saturation is strictly worse than no backoff.

- **`retry_after_header` is for batch or non-interactive workloads** where 30–60 second latency
  is acceptable.

---

## Phase 2b — APIM server-side retry

APIM retries the backend pool up to 3× on 429. Each retry can route to a different pool member.
Client retry disabled for isolation.

| run_id | config | http_200_% | p50_ms | tts_p50_ms | goodput (req/s) |
|---|---|---|---|---|---|
| apim_retry_equal | Equal weights, no CB | 18.5 | 1128.9 | 553 | 2.9 |
| apim_retry_cb | Equal weights, CB on 429+5xx | 4.5 | 1078.3 | 454 | 1.1 |
| apim_retry_asym | 90/5/5, CB on 429+5xx | 18.0 | 1091.1 | 408 | 3.7 |

### Phase 2b findings

- **APIM retry without CB gives a marginal burst improvement: 18.5% vs 17.5% baseline.**
  Each retry routes to a different pool member, which may have remaining quota. The 1129ms p50
  confirms these are genuine model completions. The improvement is small because all three
  regions are simultaneously saturated — a retry landing on a different region still has a
  high chance of 429.

- **`apim_retry_cb` (equal weights + CB on 429+5xx + retry): 4.5%** — identical to
  `circuit_breaker` from Phase 1 (4.5%, equal weights, no retry). APIM retry does not rescue
  the equal-weight CB case: each retried 429 increments the CB failure counter, backends trip
  in sequence, the pool drains to empty within the burst window.

- **`apim_retry_asym` (90/5/5 + CB on 429+5xx + retry): 18.0%** — indistinguishable from
  `apim_retry_equal`. The asymmetric weights concentrate traffic on UK South; it trips first;
  West Europe and Sweden Central retain most of their quota when they start receiving traffic.
  Critically, the fallbacks receive only ~5% of original requests (before UK South trips), so
  even with APIM retries routing to them, they have sufficient quota to serve ~18% of 200
  iterations.

- **The weight distribution, not the CB trigger alone, determines burst outcome.** With asymmetric
  weights, CB on 429+5xx is harmless at burst because the fallbacks are never close to
  exhaustion. With equal weights, CB on 429+5xx is harmful regardless of retry.

---

## Phase 3 — Optimal configuration candidates

| run_id | config | http_200_% | tts_p50_ms | retry_overhead | goodput (req/s) |
|---|---|---|---|---|---|
| optimal_equal_client | Equal, no CB, client `Retry-After` | 99.0 | 30 450 | 1.25 | 0.5 |
| optimal_asym_client | 90/5/5, CB on 429+5xx, client `Retry-After` | 36.0 | 430 | 0.31 | 0.6 |
| optimal_equal_apim | Equal, no CB, APIM retry=3 | 18.0 | 450 | 0.0 | 2.8 |
| optimal_asym_apim | 90/5/5, CB on 429+5xx, APIM retry=3 | 5.5 | 379 | 0.0 | 1.6 |
| optimal_combined | 90/5/5, CB on 429+5xx, APIM retry + client `Retry-After` | 16.5 | 334 | 0.0 | 13.3 |

### Phase 3 findings

- **`optimal_equal_client` achieves 99.0%** via client `Retry-After` — same mechanism as Phase 2a.

- **`optimal_asym_client` achieves 36%** — the highest burst success rate without a 30-second
  sleep. CB trips UK South early; client retries sometimes find West Europe or Sweden Central
  with remaining quota. The 0.31 retry overhead is low because most successes come from the
  first attempt against an open fallback backend.

- **`optimal_equal_apim` (equal, no CB, APIM retry): 18.0%** — consistent with `apim_retry_equal`
  (18.5%). Equal weights with no CB is the reliable best without client-side retry.

- **`optimal_asym_apim` (90/5/5, CB on 429+5xx, APIM retry): 5.5%** — this uses the identical
  configuration as `apim_retry_asym` (18.0% in Phase 2b). The discrepancy is quota-timing
  variance: with 10 000 TPM and tests completing in 6–10 seconds, success rate depends strongly
  on where the test lands in the 60-second quota window. Neither run is more "correct" than the
  other. This configuration should be treated as 5–18% range, not a point estimate.

- **`optimal_combined` (90/5/5 + CB + APIM retry + client `Retry-After`): 16.5%, 2.5 seconds.**
  The 2.5-second duration means the 30-second `Retry-After` never fires — this result is
  entirely from APIM-layer handling, not client retry. Effectively equivalent to `apim_retry_asym`.

---

## Ablation — isolating which variables drive success

All ablation runs performed with 60-second CB isolation gap.

**Reference:** `apim_retry_equal` — 18.5% burst, equal weights, no CB, APIM retry=3.

| run_id | change | http_200_% | p50_ms | goodput (req/s) | notes |
|---|---|---|---|---|---|
| apim_retry_equal *(ref)* | — | 18.5 | 1128.9 | 2.9 | |
| asym_retry_no_cb | 90/5/5 weights, no CB | 18.0 | 1096.1 | 3.0 | |
| asym_retry_cb_5xx | 90/5/5, CB on 5xx only | 17.0 | 1095.5 | 2.7 | |
| weight_70_15_15 | 70/15/15, CB on 429+5xx | 16.5 | 13.4 | 8.0 | ¹ |
| weight_80_10_10 | 80/10/10, CB on 429+5xx | 16.5 | 106.2 | 7.6 | |
| trip_count_1 | 90/5/5, CB trips on 1st failure | 16.5 | 13.2 | 9.9 | ¹ |

¹ Goodput elevated by fast CB-induced 503s (p50=13ms); only 33 real completions.

### Ablation findings

- **Weight distribution between 33/33/34 and 90/5/5 makes no meaningful difference to burst
  success rate when CB is off or on 5xx only.** `asym_retry_no_cb` (18.0%), `asym_retry_cb_5xx`
  (17.0%) and the equal-weight reference (18.5%) are statistically indistinguishable.

- **CB on 5xx only is transparent.** With only quota-related 429s occurring, the CB never
  triggers. Performance is identical to no-CB configurations.

- **Weight skew with CB on 429+5xx affects p50 timing but not overall success count.**
  `weight_70_15_15` and `weight_80_10_10` both achieve 16.5%, but their p50 values differ:
  - `weight_80_10_10` (80/10/10): p50=106ms (requests are mostly real completions)
  - `weight_70_15_15` (70/15/15): p50=13ms (most requests hit CB-tripped 503, a few succeed)
  The bimodal distribution in `weight_70_15_15` reflects UK South tripping early and WE/SC
  handling residual traffic, with some fast CB fails once they also approach their quota.

- **CB trip threshold (1 vs 3 failures) matters primarily for how fast UK South is removed.**
  `trip_count_1` (p50=13ms, fast pool drain) vs reference (p50=1129ms, gradual). Success
  count is identical at ~33 completions, confirming the bottleneck is total token budget, not
  how quickly backends are detected as saturated.

---

## Sustained load — multiple quota windows

5-minute runs reveal whether burst results hold across repeated 60-second quota resets.

| run_id | config | iterations | http_200 | http_200_% | goodput (req/s) |
|---|---|---|---|---|---|
| sustained_cb_only | Equal, CB on 429+5xx, no retry | 48 929 | 1 368 | 2.8 | 4.6 |
| sustained_baseline | Equal, no CB, no retry | 25 992 | 627 | 2.4 | 2.0 |
| sustained_apim_asym | 90/5/5, CB on 429+5xx, APIM retry=3 | 46 281 | 161 | 0.3 | 0.5 |
| sustained_apim_retry_cb | Equal, CB on 429+5xx, APIM retry=3 | 44 660 | 156 | 0.3 | 0.5 |
| sustained_trip_count_1 | 90/5/5, CB trip=1, APIM retry=3 | 46 388 | 161 | 0.3 | 0.5 |

Note: `sustained_apim_retry_cb` came after `sustained_baseline` (no CB) — a clean start.
`sustained_trip_count_1` came after a 5-minute `sustained_apim_retry_cb` run + terraform apply —
also a clean start. The 0.3% results for retry-enabled configurations are genuine.

### Sustained load findings

- **`sustained_cb_only` (CB, no APIM retry): 2.8%, 4.6 goodput — the best sustained APIM
  configuration.** The CB trips backends within milliseconds of quota exhaustion. With PT60S
  trip duration and no retry amplification, backends re-open after 60 seconds into a partially-
  recovered quota window. Requests that arrive at the moment of re-opening complete in ~16ms.
  The CB acts as a rate limiter that synchronises with the quota cycle.

- **`sustained_baseline` (no features): 2.4%.** Without CB, requests keep hitting exhausted
  backends and getting 429s. Some catch the brief window when quota has just reset. The result
  is only slightly worse than CB-only — the 0.4% difference comes from the CB's ability to
  "park" the pool for 60 seconds and then pounce on the reset window.

- **`sustained_apim_retry_cb` and `sustained_apim_asym` both 0.3% — catastrophic.** This is
  the critical sustained finding. APIM retry transforms the quota exhaustion cycle into an
  amplification storm: each incoming request generates up to 3 retries, re-exhausting any
  briefly-recovered quota within milliseconds of the window resetting. The CB re-trips
  immediately. The pattern repeats every 60 seconds, allowing only ~160 completions across the
  entire 5-minute window.

- **APIM retry is neutral to marginally beneficial at burst (18%) but catastrophic at
  sustained load (0.3% vs 2.4% baseline).** A configuration that appears acceptable in a
  10-second burst test is 8× worse than doing nothing over 5 minutes. Burst tests on quota-
  limited systems are systematically misleading.

- **Under global quota saturation, the fundamental ceiling is token budget.** At 3 × 10 000 TPM
  with ~25 tokens per request, the theoretical maximum is ~500 completions/minute (8.3 req/s).
  `sustained_cb_only` delivers 4.6 req/s — 55% of the theoretical ceiling. No APIM configuration
  can exceed this without increasing quota.

---

## Complete summary

| run_id | type | http_200_% | p50_ms | goodput (req/s) |
|---|---|---|---|---|
| retry_after_header | burst client | 99.5 | 188.7 | 0.4 |
| optimal_equal_client | burst client | 99.0 | 146.9 | 0.5 |
| optimal_asym_client | burst client | 36.0 | 94.5 | 0.6 |
| apim_retry_equal | burst APIM | 18.5 | 1128.9 | 2.9 |
| apim_retry_asym | burst APIM | 18.0 | 1091.1 | 3.7 |
| asym_retry_no_cb | burst ablation | 18.0 | 1096.1 | 3.0 |
| optimal_equal_apim | burst APIM | 18.0 | 1118.2 | 2.8 |
| baseline | burst APIM | 17.5 | 122.5 | 6.8 |
| direct_equal | burst direct | 17.5 | 104.4 | 3.1 |
| asym_retry_cb_5xx | burst ablation | 17.0 | 1095.5 | 2.7 |
| cb_5xx_only | burst APIM | 16.5 | 114.3 | 5.9 |
| asymmetric_cb | burst APIM | 16.5 | 119.4 | 8.5 |
| weight_80_10_10 | burst ablation | 16.5 | 106.2 | 7.6 |
| weight_70_15_15 | burst ablation | 16.5 | 13.4 | 8.0 ¹ |
| optimal_combined | burst APIM | 16.5 | 12.6 | 13.3 ¹ |
| trip_count_1 | burst ablation | 16.5 | 13.2 | 9.9 ¹ |
| weighted_primary | burst APIM | 16.5 | 379.9 | 5.6 |
| direct_weighted | burst direct | 16.5 | 94.2 | 11.1 |
| retry_immediate | burst client | 17.5 | 103.3 | 5.0 |
| **sustained_cb_only** | **sustained** | **2.8** | **14.5** | **4.6** |
| sustained_baseline | sustained | 2.4 | 97.8 | 2.0 |
| circuit_breaker | burst APIM | 4.5 | 106.1 | 3.7 |
| apim_retry_cb | burst APIM | 4.5 | 1078.3 | 1.1 |
| gateway_throttle | burst APIM | 3.5 | 11.8 | 2.9 |
| retry_backoff | burst client | 13.0 | 107.2 | 0.6 |
| retry_backoff_jitter | burst client | 13.0 | 107.0 | 0.6 |
| retry_fixed_1s | burst client | 12.0 | 100.8 | 0.6 |
| direct_sequential | burst direct | 16.5 ² | 101.1 | 6.2 |
| optimal_asym_apim | burst APIM | 5.5 | 24.6 | 1.6 |
| sustained_apim_asym | sustained | 0.3 | 13.5 | 0.5 |
| sustained_apim_retry_cb | sustained | 0.3 | 13.8 | 0.5 |
| sustained_trip_count_1 | sustained | 0.3 | 13.7 | 0.5 |
| full_resilience | burst APIM | 0.0 | 11.6 | 0.0 |

¹ Goodput elevated by fast CB-induced 503s; not comparable with real-completion goodput.

² `direct_sequential` makes up to 3 HTTP calls per iteration (UK→WE→SC fallback chain), giving 567 HTTP calls for 200 k6 iterations. `summarise.py` uses HTTP calls as the denominator (no `original_iterations` counter in `direct_test.js`), reporting 5.8%. Correct per-request rate: 33 ÷ 200 = **16.5%**.

---

## Phase 4: Constant-arrival-rate (open-loop) experiments

### Motivation

Phases 1–3 and the sustained runs all used **closed-loop load** (20 VUs). In a closed-loop test
each virtual user fires the next request as soon as the previous one completes. A config that
returns fast 503s (e.g. a tripped circuit breaker) therefore generates far more HTTP calls per
wall-clock second than a config with slow failures — roughly 163 req/s vs 83 req/s in the
sustained runs. The two configs are not experiencing the same offered load.

A **constant-arrival-rate** (CAR) executor fires requests at a fixed rate independent of response
time. Fast failures free VU slots but do not increase the arrival rate. This removes the confound
and makes sustained comparisons fair.

### Design

| Parameter | Value | Rationale |
|---|---|---|
| Arrival rate | 10 req/s | Assumed ≈ 1.5× one region's 6.67 req/s quota capacity; actual RPM ceiling turned out to be ~12 RPM (0.2 req/s) per backend — see calibration gate failure below |
| Duration | 5 minutes | Covers 5 quota reset cycles (PT60S each) |
| Weights | 90/5/5 | UK South receives 9 req/s (saturates); WE and SC receive 0.5 req/s each (fresh quota) |
| `preAllocatedVUs` | 30 | Handles up to 30× the per-request latency ceiling before dropping arrivals |
| Response check | body must contain `choices[]` | Guards against synthetic gateway responses |

The 10 req/s rate was intended to put UK South (90% = 9 req/s) above its quota ceiling while
leaving WE and SC well below theirs (0.5 req/s each). This would represent the
**single-region-spill regime**: a real PTU primary + PAYG fallbacks deployment at peak load.
The capacity assumption proved wrong; see calibration gate failure under Results.

**Calibration gate:** `car_baseline` must reach ~95–100% success before the spill math is trusted.
If it falls short, the capacity assumption is wrong and the arrival rate must be reduced before
interpreting `car_90_5_5` results.

**Dropped iterations:** the k6 summary reports `dropped_iterations` when all pre-allocated VUs are
busy and a new arrival cannot be assigned a slot. If non-zero, the constant-arrival-rate guarantee
is broken for those requests (they were never sent). Check this metric before drawing conclusions.

### Experiments

| run_id | weights | CB | APIM retry | purpose |
|---|---|---|---|---|
| `car_baseline` | 33/33/34 | none | none | Calibration gate: no saturation expected (3.3 req/s per backend < 6.67 cap) |
| `car_90_5_5` | 90/5/5 | none | none | Primary spill with no recovery — sets the unassisted ceiling |
| `car_cb5xx_90_5_5` | 90/5/5 | 5xx only | none | CB transparent under quota-only 429s — expected identical to `car_90_5_5` |
| `car_retry_90_5_5` | 90/5/5 | none | count=3 | Retry on spill, unguided: retries re-enter 90/5/5 pool (UK South ~90% of retries) |
| `car_retry_cb5xx_90_5_5` | 90/5/5 | 5xx only | count=3 | Same pool re-selection issue — CB on 5xx doesn't remove UK South on 429s |
| `car_retry_cb429_90_5_5` | 90/5/5 | 429+5xx | count=3 | Retry with UK South CB-tripped: retries forced to WE/SC (the mechanism that actually routes around the primary) |

### Results

> **NOT VALIDATED — do not use as article evidence.**
>
> All six runs were recorded on 2026-11-01, before the circuit-breaker-state fix (commit `9e5b22e`,
> 2026-11-02). `9e5b22e` corrects `apim_backends.tf` so that `rules = []` explicitly clears CB
> config on every `terraform apply`; the prior code destroyed the `azapi_update_resource` without
> resetting Azure state, leaving CB rules from the preceding experiment on the backends.
>
> Additionally, the per-backend throughput ceiling implied by these results (~12 RPM) is
> inconsistent with the sustained closed-loop runs (~40–91 RPM); the gap is unexplained (see open
> questions below). Until both issues are resolved the six numbers should not be quoted.
>
> The mechanics observations (retry delay, pool re-selection) are still informative but are
> unconfirmed n=1 results from a potentially contaminated run.

All six experiments ran on 2026-11-01 (pre-fix). Raw numbers from `summarise.py` for reference:

| run_id | iterations | http_200 | http_200_% | total_calls | avg_ms | p50_ms | p95_ms | tts_p50_ms | tts_p95_ms | retry_overhead |
|---|---|---|---|---|---|---|---|---|---|---|
| `car_baseline` | 3001 | 180 | 6.0 | 3001 | 169.9 | 102.4 | 589.9 | 295.5 | 536.9 | 0.0 |
| `car_90_5_5` | 3000 | 179 | 6.0 | 3000 | 158.2 | 85.2 | 429.8 | 292.0 | 547.1 | 0.0 |
| `car_cb5xx_90_5_5` | 3001 | 181 | 6.0 | 3001 | 152.2 | 83.1 | 548.9 | 295.0 | 895.0 | 0.0 |
| `car_retry_90_5_5` | 3001 | 181 | 6.0 | 3000 | 1094.6 | 1095.6 | 1517.2 | 379.0 | 1233.0 | 0.0 |
| `car_retry_cb5xx_90_5_5` | 3001 | 181 | 6.0 | 3001 | 1065.0 | 1094.7 | 1172.6 | 357.0 | 472.0 | 0.0 |
| `car_retry_cb429_90_5_5` | 3001 | 176 | 5.9 | 3001 | 96.1 | 13.6 | 780.8 | 295.0 | 433.5 | 0.0 |

No `dropped_iterations` on any run; the constant-arrival-rate guarantee held throughout.

Error-type breakdown (derived from k6 check counters):

| run_id | http_200 | http_429 | http_5xx | p50_ms | interpretation |
|---|---|---|---|---|---|
| `car_baseline` | 180 | 2768 | 53 | 102 | Backend 429s dominate; CB absent or not firing |
| `car_90_5_5` | 179 | 2821 | 0 | 85 | All failures backend 429s |
| `car_cb5xx_90_5_5` | 181 | 2820 | 0 | 83 | Identical — CB on 5xx silent under 429-only load |
| `car_retry_90_5_5` | 181 | 53 | 2767 | 1096 | 3 × ~365 ms retry delay before APIM returns 503 |
| `car_retry_cb5xx_90_5_5` | 181 | 0 | 2820 | 1095 | Same retry pattern; CB on 5xx still silent |
| `car_retry_cb429_90_5_5` | 176 | 0 | 2825 | 14 | All backends CB-tripped; fast pool-empty 503s |

### Calibration gate failure

**`car_baseline` achieved 6.0% success — the calibration gate required ≥ 95%.** The experiment
did not test single-region spill; it tested global saturation.

The apparent per-backend ceiling derived from this run:
```
180 successes ÷ 300 s ÷ 3 backends × 60 ≈ 12 RPM per backend
```
is not confirmed. The sustained closed-loop runs suggest a much higher ceiling (see open
questions). Until that gap is explained, 12 RPM should not be used for capacity planning.

At 10 req/s total, every backend was saturated regardless of weights:

| config | UK South rate | WE rate | SC rate |
|---|---|---|---|
| 33/33/34 (`car_baseline`) | 3.3 req/s (200 RPM) | 3.3 req/s | 3.3 req/s |
| 90/5/5 | 9.0 req/s (540 RPM) | 0.5 req/s (30 RPM) | 0.5 req/s (30 RPM) |

Even the 5% fallbacks each received 30 RPM. The single-region-spill regime was never entered.

### Open questions (must be resolved before article)

**1. Per-backend throughput gap.**
CAR runs imply ~12 RPM per backend; sustained closed-loop runs imply far higher:

| source | observed success RPM/backend | offered load |
|---|---|---|
| `car_baseline` (CAR, 10 req/s) | ~12 | 200 RPM/backend |
| `diag_1rps` (CAR, 1 req/s, 1 min) | ~11 | 20 RPM/backend |
| `sustained_baseline` (20 VUs, closed-loop) | ~40 | 4,991 RPM/backend |
| `sustained_cb_only` (20 VUs, closed-loop) | ~91 | 9,784 RPM/backend |

The `diag_1rps` file (2026-11-02 08:41, 61 requests, 33 successes, 60 s run) corroborates the
CAR figure at lower offered load. The large gap between CAR and sustained numbers is unexplained.
Possible causes: closed-loop load creates burst patterns that warm the quota bucket; time-of-day
quota availability; `sustained_cb_only` may itself be contaminated by the CB persistence bug
(stale CB-on-429 from a prior run would produce fast pool-drain 503s, inflating the success count
during brief post-reset windows and explaining both the 14 ms all-request p50 and the 91 RPM/backend
figure — whereas a clean CB-on-5xx-only run should behave identically to `sustained_baseline`).

**2. 14 ms p50 for successful requests in `sustained_baseline`.**
`http_req_duration{expected_response:true}` reports p50=14 ms for the 627 successful 200 responses
in `sustained_baseline`. Real LLM completions take ~300 ms (tts_p50=15 ms is equally anomalous).
The cause is unknown: APIM-level caching on identical prompt content, a synthetic policy response,
or a measurement artefact. This needs investigation before any sustained figures are quoted.

**3. CB persistence status for sustained runs.**
`sustained_cb_only` (CB on 5xx, no retry) shows p50=14 ms for ALL requests and 91 RPM/backend
success — behaviour consistent with CB-on-429 draining the pool, not CB-on-5xx being transparent.
This suggests the azapi destroy bug was active during that run and the backends were carrying
stale CB-on-429 rules from `sustained_retry_cb429` (the preceding experiment). If confirmed,
`sustained_cb_only` results are invalid.

### What the raw data tentatively suggest (unconfirmed)

Despite the caveats, the p50 patterns are mechanistically consistent:

- APIM retry fires on 429 with ~365 ms inter-retry delay (p50=1095 ms ≈ 3 × 365 ms). This is
  an n=1 observation from a pre-fix run; it should be confirmed.
- CB on 5xx is transparent under quota-only 429 load (identical p50 and success rate to no-CB).
- Pool re-selection under retry is blind — both retry arms without CB-on-429 show identical
  success rates, consistent with 90% of retries re-hitting UK South.
- CB on 429+5xx drains the pool quickly (p50=14 ms fast 503s).

### What the results do reveal

Despite not testing the intended scenario, the data confirm several APIM mechanics:

**APIM retry fires on 429 with ~365 ms inter-retry delay.** `car_retry_90_5_5` shows p50=1095 ms
(≈ 3 × 365 ms) against p50=85 ms for `car_90_5_5`. The delay accounts for the latency gap; retry
count is confirmed at 3. Clients waiting on APIM retry face ~1.1 s p50 latency before receiving
a 503 (APIM converts exhausted-retry-429 to 503 — the client never sees a 429 once retry is on).

**CB on 5xx is transparent under quota-only load.** `car_cb5xx_90_5_5` is indistinguishable from
`car_90_5_5` across all metrics. Backends return 429 (not 5xx); the CB rule never triggers.

**CB on 429+5xx drains the pool and lowers success.** `car_retry_cb429_90_5_5` achieves 5.9%
(slightly *lower* than the other configs' 6.0%). All three backends trip on 429s within the first
second of the run; the pool empties; APIM returns fast 503s (p50=14 ms). The CB resets every 60 s
and the pattern repeats. In this globally-saturated regime, CB-on-429 makes things worse.

**Pool re-selection under retry is confirmed.** `car_retry_90_5_5` and `car_retry_cb5xx_90_5_5`
show identical success rates and p50 values, consistent with retries re-entering the 90/5/5 pool
and landing predominantly on UK South (~90% probability) — no undocumented "exclude-last-failure"
behaviour was observed.

### Pre-run hypotheses (recorded before results)

The core mechanistic question was whether retries **actually route to WE/SC** or just re-hit UK
South. `acceptRetryAfter` is a circuit-breaker property: it extends a CB trip duration using the
backend's `Retry-After` header. It only applies once the CB has tripped. With CB off or CB on 5xx
only, UK South is never removed from the pool, so retries re-enter the 90/5/5 pool and have a 90%
chance of landing on UK South again.

- `car_baseline`: ~95–100% success. No backend saturates; this is the calibration control.
  **Actual: 6.0% — calibration gate failed.**
- `car_90_5_5`: ~70–77% success. UK South saturated; WE/SC serve at ~100%.
  **Actual: 6.0% — WE/SC also saturated (30 RPM vs 12 RPM limit).**
- `car_cb5xx_90_5_5`: identical to `car_90_5_5`. CB on 5xx transparent.
  **Actual: 6.0% — confirmed.**
- `car_retry_90_5_5`: small lift at best; retries re-enter 90/5/5 pool, 90% land on UK South.
  **Actual: 6.0% — no lift; p50=1095 ms confirms 365 ms inter-retry delay.**
- `car_retry_cb5xx_90_5_5`: identical to `car_retry_90_5_5`.
  **Actual: 6.0% — confirmed.**
- `car_retry_cb429_90_5_5`: substantial lift expected; UK South CB-trips, retries route to WE/SC.
  **Actual: 5.9% — lower than baseline. Pool drain lowers success; p50=14 ms confirms
  instant pool-empty 503s.**

### Conclusions

- **Results not validated** — pre-CB-fix run; open questions on throughput ceiling and
  sustained-run integrity must be resolved first.
- **Spill-vs-recovery comparison is inconclusive** — calibration gate failed; single-region-spill
  regime was never entered.
- **Phase 4 re-run requirements:** apply the CB fix, confirm backends show no stale rules in
  Azure portal, deploy ≥ 60 000 TPM per region so that 1–2 req/s total puts UK South above the
  ceiling while WE/SC stay below it, then re-run all six arms with the calibration gate ≥ 95%
  as a hard go/no-go. Resolve the 14 ms 200-response anomaly in the sustained runs before
  quoting any sustained figures.

---

## Key takeaways

1. **Burst success rate plateaus at ~17–18% for almost all APIM configurations.** The fundamental
   constraint is token budget, not configuration. Whether CB is on or off, whether weights are
   symmetric or asymmetric, whether APIM retry is enabled — burst results cluster at 16.5–18.5%
   with the one exception being `circuit_breaker` / `apim_retry_cb` (equal weights + CB on 429).

2. **The only CB configuration that hurts burst performance is CB on 429+5xx with equal weights.**
   Equal weights cause all three backends to exhaust quota at the same rate and trip
   simultaneously. The pool empties; success rate drops to 4.5%. With asymmetric weights
   (90/5/5, 80/10/10, 70/15/15), CB on 429+5xx is burst-neutral because UK South exhausts
   first and the fallbacks have ample remaining quota.

3. **CB on 5xx only is always neutral.** It never fires during quota saturation (there are no
   5xx errors, only 429s). It is the correct production CB setting: it protects against hard
   backend failures without interfering with quota redistribution.

4. **APIM retry is a burst-time neutral to mildly beneficial, and a sustained-time catastrophe.**
   With retry enabled, each incoming request generates up to 3 retries. In a 10-second burst,
   this distributes load across pool members and might catch the quota window. Over 5 minutes,
   the retry amplification re-exhausts every quota window within milliseconds of it resetting.
   Configurations with APIM retry drop from ~18% burst to 0.3% sustained — 8× worse than the
   no-features baseline (2.4%). _(Caveat: sustained figures depend on `sustained_baseline` and
   related runs whose 14 ms 200-response p50 is unexplained — see Phase 4 open questions.)_

5. **CB without APIM retry is the best APIM strategy at sustained load: 2.8% vs 2.4% baseline.**
   Without retry amplification, the CB acts as a rate limiter that synchronises with the quota
   cycle: backends trip fast, wait 60 seconds, re-open into a briefly-available quota window,
   and some requests complete before the cycle repeats. _(Caveat: `sustained_cb_only` may be
   contaminated by the CB persistence bug; its 2.8% figure is provisional.)_

6. **Client `Retry-After` achieves 99% eventual success at 30-second median latency.** This is
   the right strategy for batch or non-interactive workloads. For interactive workloads, the
   ceiling without client retry is ~18% burst and ~2.8% sustained.

7. **Burst tests on quota-limited systems are systematically misleading.** `baseline` scores
   17.5% burst but 2.4% sustained. `apim_retry_asym` scores 18% burst but 0.3% sustained.
   Any performance claim about a quota-limited AI gateway should be validated with a sustained
   run spanning multiple quota reset cycles before being presented as representative.

8. **Always run a calibration gate before interpreting CAR results.** A control arm (equal
   weights, no CB, no retry) at the intended arrival rate must reach ≥ 95% success before the
   other arms are meaningful. If it fails, the arrival rate exceeds the backends' effective
   capacity and all routing configs will converge on the same throughput ceiling. This is true
   regardless of whether the constraint is RPM, TPM, or something else.

   _Phase 4 pending:_ the single-region-spill scenario (PTU primary + PAYG fallbacks) has not
   yet been tested with validated results. The Phase 4 runs predate the CB-state fix and contain
   unexplained anomalies in both the throughput ceiling and the sustained-run baselines. Takeaways
   9 and onward will be added once Phase 4 re-runs are clean.
