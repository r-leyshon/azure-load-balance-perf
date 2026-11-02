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
> apply` of new policy configurations. The pre-fix code destroyed the `azapi_update_resource`
> without clearing Azure backend state, so a CB-off experiment that ran immediately after a CB-on
> experiment inherited the prior rules. The isolation gap (60-second sleep + terraform apply)
> ensures the CB trip duration has expired, but it does **not** reset the rules when CB is being
> turned off — that required the Bug 3 fix below. Three "no CB" burst runs that followed CB-on
> runs may be contaminated: `apim_retry_equal`, `asym_retry_no_cb`, `optimal_equal_apim` (see
> pending re-runs below). The six client-retry runs, `gateway_throttle`, and `sustained_baseline`
> show zero 5xx and are likely unaffected.
>
> **Bug 3:** `azapi_update_resource` with `circuitBreaker.rules = []` was rejected by the Azure
> ARM API with ValidationError ("at least one rule should be defined"). The resource was updated to
> use `circuitBreaker = null` instead, which explicitly clears CB config on every `terraform apply`.
> Phase 4 CAR runs (2026-11-02) used this fix. Prior Phases did not have access to it; the three
> runs named above are pending re-verification (A2).
>
> **Not all tables are fully clean.** The three runs in A2 are marked ⚠ pending re-run. All other
> tables reflect isolation-verified data.

---

## Setup

| Parameter | Value |
|---|---|
| Gateway | Azure API Management (Developer tier) |
| Backends | 3 × Azure AI Foundry (OpenAI kind), one per region |
| Auth | System-assigned managed identity + Cognitive Services OpenAI User RBAC |
| Model | gpt-4.1-mini (2025-04-14) |
| Quota per backend | 10 000 TPM (Phases 1–3 and sustained); 60 000 TPM (Phase 4) |
| Burst load | 20 VUs, 200 iterations |
| Sustained load | 20 VUs, 5-minute duration |
| CAR load (Phase 4) | 1 req/s calibration / 2 req/s spill, constant arrival rate, 5-minute duration |

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

Run order by file timestamp (2026-11-01): `sustained_baseline` (09:45), `sustained_cb_only`
(10:00), then burst APIM runs, then `sustained_apim_asym` (14:29), `sustained_apim_retry_cb`
(14:34), `sustained_trip_count_1` (14:39). Each had the 60-second CB isolation gap.
`sustained_cb_only` ran immediately after `sustained_baseline` (no CB), so no inherited CB rules.
`sustained_apim_asym` and the two that follow ran after CB-on burst runs — the Bug 2 isolation
gap clears trip state, but the Bug 3 fix was not yet in place; any prior CB-off-to-CB-on
transition within the afternoon block was in the correct direction (adding rules, not clearing
them) and is not affected.

⚠ **`sustained_baseline` and `sustained_cb_only` are pending re-run** (see A1 below): both lack
the body check that `car_test.js` has, so their reported 200 counts may include synthetic
gateway responses. See Sustained load findings for the impact on takeaways.

### Sustained load findings

⚠ **These findings are provisional pending A1 re-runs.** `sustained_baseline` and
`sustained_cb_only` lack body validation; their 200 counts include any synthetic responses.
The 14 ms median for successful 200s is inconsistent with real LLM completions (~300–400 ms in
all validated runs). The 0.3% retry-enabled results are more reliable (those runs show p50 ~285 ms
for 200s, consistent with real completions; n=3 runs). The sustained narrative below reflects the
raw data; confidence levels are noted per claim.

- **`sustained_cb_only` reports 2.8%, 4.6 req/s goodput — nominally the best sustained
  configuration, but unvalidated.** The 14 ms p50 for 200s suggests some or all of the 1 368
  successes may be synthetic. One hypothesis: CB trips and re-opens synchronise with the quota
  window so a brief burst of real completions occurs at each re-open, but the 14 ms figure is
  unexplained. **Pending A1 re-run.**

- **`sustained_baseline` reports 2.4%, also unvalidated.** 627 successes at 14 ms p50.
  **Pending A1 re-run.**

- **`sustained_apim_retry_cb` and `sustained_apim_asym` both 0.3% — more credible.** These
  show p50 ~285 ms for their 161 successes, consistent with real completions. The pattern is
  consistent across three independent runs. The proposed mechanism — retry amplification
  re-exhausts quota windows within milliseconds of reset — is plausible and internally
  consistent, but is a hypothesis, not a directly measured mechanism.

- **APIM retry appears to worsen sustained throughput vs baseline (0.3% vs 2.4%), if the
  baseline figure is real.** The 8× ratio should be treated as an order-of-magnitude estimate
  until A1 resolves the baseline validation.

- **Under global quota saturation, the measured throughput ceiling (not theoretical) is the
  relevant limit.** Phase 4 CAR runs establish ~12 RPM per backend at 10 000 TPM (~36 RPM
  total). `sustained_cb_only` at 4.6 req/s = 276 RPM total is 7.7× that ceiling — another
  signal that its 200 counts are inflated. No APIM configuration can exceed the quota ceiling
  without increasing quota.

---

## Complete summary

| run_id | type | http_200_% | p50_ms | goodput (req/s) |
|---|---|---|---|---|
| retry_after_header | burst client | 99.5 | 188.7 | 0.4 |
| optimal_equal_client | burst client | 99.0 | 146.9 | 0.5 |
| optimal_asym_client | burst client | 36.0 | 94.5 | 0.6 |
| apim_retry_equal ⚠ | burst APIM | 18.5 | 1128.9 | 2.9 |
| apim_retry_asym | burst APIM | 18.0 | 1091.1 | 3.7 |
| asym_retry_no_cb ⚠ | burst ablation | 18.0 | 1096.1 | 3.0 |
| optimal_equal_apim ⚠ | burst APIM | 18.0 | 1118.2 | 2.8 |
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
| **car_retry_cb429_90_5_5** | **CAR Phase 4** | **98.0** | **328** | — |
| car_baseline | CAR Phase 4 | 100.0 | 374 | — |
| car_90_5_5 | CAR Phase 4 | 70.4 | 288 | — |
| car_cb5xx_90_5_5 | CAR Phase 4 | 69.9 | 281 | — |
| car_retry_90_5_5 | CAR Phase 4 | 68.2 | 361 | — |
| car_retry_cb5xx_90_5_5 | CAR Phase 4 | 68.2 | 389 | — |

¹ Goodput elevated by fast CB-induced 503s; not comparable with real-completion goodput.

² `direct_sequential` denominator is HTTP calls (567), not iterations (200), because `direct_test.js`
lacked `original_iterations` before commit `[fix pending]`. Correct per-request rate: 33 ÷ 200 = **16.5%**.

⚠ Pending re-run: may carry leftover CB rules from a prior CB-on experiment (Bug 2 isolation gap
clears trip state but did not reset rules before the Bug 3 fix). Three runs affected:
`apim_retry_equal`, `asym_retry_no_cb`, `optimal_equal_apim`.

---

## Pending re-runs

| label | runs | reason | blocker |
|---|---|---|---|
| A1 | `sustained_baseline`, `sustained_cb_only` (+ one pool-retry sustained) | No body check in `load_test.js`; 14 ms p50 on 200s suggests synthetic responses | `load_test.js` body-check fix landed; re-run when quota is active |
| A2 | `apim_retry_equal`, `asym_retry_no_cb`, `optimal_equal_apim` | May carry stale CB rules from prior CB-on run (Bug 2 gap cleared trip state, Bug 3 fix not yet in place) | Verify no CB rules in Azure portal, then re-run |
| A3 | `car_90_5_5`, `car_retry_90_5_5`, `car_retry_cb429_90_5_5` (×3 each) | n=1 CAR spill arms; 68% vs 70% difference is within noise; 98% needs a spread | Re-run at 60 000 TPM, 2 req/s |
| A4 | `car_direct_spill` (new) | No no-gateway baseline at 2 req/s / 90/5/5 for comparison with `car_retry_cb429_90_5_5` | Add direct-to-Foundry CAR arm to `run_experiments.sh` |

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
| Quota per backend | 60 000 TPM | CAR ceiling ≈ 72 RPM per backend (see calibration below) |
| Calibration arrival rate | 1 req/s | ~20 RPM/backend (28% utilisation); must reach ≥ 95% to validate capacity |
| Spill arrival rate | 2 req/s | UK South: 1.8 req/s = 108 RPM (saturates); WE/SC: 0.1 req/s = 6 RPM (fresh) |
| Duration | 5 minutes | Covers 5 quota reset cycles (PT60S each) |
| Weights | 90/5/5 | PTU primary + PAYG fallbacks: primary saturates, fallbacks idle |
| `preAllocatedVUs` | 30 | Handles up to 30× the per-request latency ceiling before dropping arrivals |
| Response check | body must contain `choices[]` | Guards against synthetic gateway responses |

The 2 req/s rate puts UK South (90% = 1.8 req/s = 108 RPM) above its quota ceiling (~72 RPM)
while leaving WE and SC well below theirs (0.1 req/s = 6 RPM each). This is the
**single-region-spill regime**: a PTU primary saturated at normal load with PAYG fallbacks idle.

**Calibration gate:** `car_baseline` must reach ≥ 95% success before the spill arms are trusted.
If it falls short, the capacity assumption is wrong and the arrival rate must be reduced.

**Dropped iterations:** non-zero `dropped_iterations` means the CAR guarantee broke for those
requests (they were never sent). None were observed in any Phase 4 run.

### Experiments

| run_id | weights | CB | APIM retry | purpose |
|---|---|---|---|---|
| `car_baseline` | 33/33/34 | none | none | Calibration gate: no saturation expected (~20 RPM/backend < 72 cap) |
| `car_90_5_5` | 90/5/5 | none | none | Primary spill with no recovery — sets the unassisted ceiling |
| `car_cb5xx_90_5_5` | 90/5/5 | 5xx only | none | CB transparent under quota-only 429s — expected identical to `car_90_5_5` |
| `car_retry_90_5_5` | 90/5/5 | none | count=3 | Retry on spill, unguided: retries re-enter 90/5/5 pool (UK South ~90% of retries) |
| `car_retry_cb5xx_90_5_5` | 90/5/5 | 5xx only | count=3 | Same pool re-selection issue — CB on 5xx doesn't remove UK South on 429s |
| `car_retry_cb429_90_5_5` | 90/5/5 | 429+5xx | count=3 | Retry with UK South CB-tripped: retries forced to WE/SC (the mechanism that actually routes around the primary) |

### Results (2026-11-02, validated)

All six runs used the `circuitBreaker = null` fix (commit `ee87a8b`) and 60 000 TPM per backend.
No `dropped_iterations` on any run.

| run_id | iterations | http_200 | http_200_% | p50_req_ms | p50_success_ms |
|---|---|---|---|---|---|
| `car_baseline` | 301 | 301 | **100.0** | 374 | 381 |
| `car_90_5_5` | 601 | 423 | 70.4 | 288 | 326 |
| `car_cb5xx_90_5_5` | 601 | 420 | 69.9 | 281 | 312 |
| `car_retry_90_5_5` | 601 | 410 | 68.2 | 361 | 342 |
| `car_retry_cb5xx_90_5_5` | 600 | 409 | 68.2 | 389 | 358 |
| `car_retry_cb429_90_5_5` | 600 | 588 | **98.0** | 328 | 333 |

All p50 values are in the 280–390 ms range — consistent with real LLM completions. Body
validation (`choices[]` check) confirmed all `http_200` counts as real model responses.

### Calibration gate

**`car_baseline` achieved 100% — calibration gate passed.** The 1 req/s rate (20 RPM/backend)
is well under the effective ceiling.

The per-backend ceiling can be derived from the spill arms (no recovery, equal offered load):

```
70% success at 108 RPM offered → ceiling ≈ 0.70 × 108 ≈ 72–76 RPM per backend
```

This is consistent with 60 000 TPM × (12 RPM per 10 000 TPM) = 72 RPM — confirming the
CAR-mode ceiling scales linearly with TPM. The ~12 RPM per backend figure at 10 000 TPM is
supported by two independent CAR observations: the pre-fix Phase 4 car_baseline (2026-11-01,
10 req/s, 10 000 TPM, 6.0% success → ~12 RPM per backend) and a diagnostic run diag_1rps
(2026-11-02 08:41, 1 req/s, 10 000 TPM, equal weights, 61 iterations, 33 successes → ~11 RPM
per backend).

The gap between the CAR ceiling (~12 RPM at 10 000 TPM) and the sustained closed-loop figures
(627–1 368 successes in 5 minutes, implying 40–91 RPM per backend) is not yet explained. The
sustained figures are unvalidated (see A1); the gap may largely disappear once they are re-run
with body validation. The "burst quota bucket" hypothesis is untested and should not be cited
as a finding.

| config | UK South (offered) | WE (offered) | SC (offered) | expected success |
|---|---|---|---|---|
| 33/33/34 (calibration) | 0.33 req/s (20 RPM) | 0.33 req/s | 0.33 req/s | ~100% ✓ |
| 90/5/5 (spill) | 1.8 req/s (108 RPM) | 0.1 req/s (6 RPM) | 0.1 req/s (6 RPM) | ~70% ✓ |

### Phase 4 findings

- **Unassisted spill: 70%.** Without any recovery mechanism, UK South saturates at 108 RPM
  offered (ceiling ~72 RPM). WE and SC serve all their requests at 100%. Overall success is
  0.9 × (72/108) + 0.05 × 1.0 + 0.05 × 1.0 ≈ 70%. The 30% failure rate is the cost of
  routing 90% of traffic to a quota-limited primary.

- **CB on 5xx only: 70%.** Indistinguishable from `car_90_5_5`. No 5xx errors occur in a
  quota-saturation scenario (backends return 429, not 5xx); the CB never fires.

- **APIM retry without CB: 68% — slightly worse than no retry.** The slight decrease vs no-retry
  (70%) may be noise or a small amplification effect on the already-saturated primary. The
  proposed mechanism — retries re-enter the 90/5/5 pool and ~90% re-hit UK South — is derived
  from the pool weights, not measured directly (no per-backend counters in these runs; the
  x-ms-region header was not logged). The additional ~365 ms per retry (p50=361 ms vs 288 ms for
  no-retry) confirms the inter-retry delay. **Pending A3 repeats and A4 comparison.**

- **APIM retry + CB on 5xx: 68%.** Same as retry without CB. CB on 5xx is silent under
  429-only failures; the retry pool selection is identical.

- **APIM retry + CB on 429+5xx: 98%.** The decisive winner. UK South receives 429s, trips the
  CB, and is removed from the pool. APIM retries are then forced to WE and SC — both under 10%
  of their quota ceiling — and succeed at ~100%. The two-percentage-point shortfall from 100%
  reflects the brief window before UK South trips (first few requests land on UK South and fail
  before the CB threshold is reached).

  This is the mechanism that makes weighted routing useful in the quota-saturation regime:
  **CB on 429 is necessary for APIM retry to actually route to fallbacks.** Without it, retry
  is unguided and returns to the saturated primary.

### Historical record (2026-11-01, pre-fix, not for article use)

All six experiments ran on 2026-11-01 at 10 req/s with 10 000 TPM — before the CB-state fix.
The calibration gate failed at 6.0% (global saturation; no spill scenario). Retained for audit.

| run_id | iterations | http_200 | http_200_% | p50_ms | notes |
|---|---|---|---|---|---|
| `car_baseline` | 3001 | 180 | 6.0 | 102 | All backends saturated at 10 req/s |
| `car_90_5_5` | 3000 | 179 | 6.0 | 85 | Same; fallbacks also over ceiling |
| `car_cb5xx_90_5_5` | 3001 | 181 | 6.0 | 83 | CB on 5xx silent under 429-only load |
| `car_retry_90_5_5` | 3001 | 181 | 6.0 | 1096 | 3 × ~365 ms retry delay confirmed |
| `car_retry_cb5xx_90_5_5` | 3001 | 181 | 6.0 | 1095 | Retry pattern identical |
| `car_retry_cb429_90_5_5` | 3001 | 176 | 5.9 | 14 | All backends CB-tripped; fast 503s |

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

4. **APIM retry appears catastrophic at sustained load (0.3% vs ~2% baseline), but the
   baseline figure is pending validation.** Three independent retry-enabled sustained runs
   converge at 0.3% with realistic completion latencies (~285 ms p50). The baseline and CB-only
   figures (2.4% and 2.8%) lack body validation and may be inflated by synthetic 200s. The
   proposed mechanism — retry amplification re-exhausting quota windows on reset — is a
   consistent hypothesis, not a confirmed finding. _(Pending A1 re-runs.)_

5. **CB without APIM retry is nominally the best sustained APIM strategy (2.8%), but this single
   run is unvalidated.** The claim that CB "synchronises with the quota cycle" is a hypothesis
   consistent with the pattern but not directly measured. _(Pending A1 re-run.)_

6. **Client `Retry-After` achieves 99% eventual success at 30-second median latency.** This is
   the right strategy for batch or non-interactive workloads. For interactive workloads, the
   burst ceiling without client retry is ~18%.

7. **Burst tests on quota-limited systems are potentially misleading — sustained validation is
   required.** `baseline` scores 17.5% burst but ~2% sustained (pending validation).
   `apim_retry_asym` scores 18% burst but 0.3% sustained. Any performance claim about a
   quota-limited AI gateway should be validated with a sustained run spanning multiple quota
   reset cycles before being presented as representative.

8. **Always run a calibration gate before interpreting CAR results.** A control arm (equal
   weights, no CB, no retry) at the intended arrival rate must reach ≥ 95% success before the
   other arms are meaningful. If it fails, the arrival rate exceeds the backends' effective
   capacity and all routing configs will converge on the same throughput ceiling. This is true
   regardless of whether the constraint is RPM, TPM, or something else.
   _Phase 4 calibration gate: 100% at 1 req/s, 60 000 TPM._

9. **CB on 429 is the essential ingredient for APIM retry to route around a saturated primary.**
   In the single-region-spill regime (PTU primary at 108 RPM offered, fallbacks at 6 RPM),
   n=1 CAR run (A3 repeats pending):
   - No recovery: 70% (UK South caps at ~72 RPM; 30% of requests fail)
   - CB on 5xx / retry without CB: 68–70% — no improvement or slight regression
   - CB on 429 + retry: **98%** — UK South trips, retries forced to WE/SC, near-perfect recovery

   The proposed mechanism (retries without CB re-enter the 90/5/5 pool and ~90% re-hit UK South)
   is derived from pool weights, not measured. A direct-to-Foundry comparison at the same 2 req/s
   is pending (A4) to establish the no-gateway baseline.

10. **The CAR-mode throughput ceiling scales linearly with TPM.** At 10 000 TPM the ceiling is
    ~12 RPM per backend (supported by two independent CAR observations); at 60 000 TPM it is
    ~72 RPM — a 6× increase. The gap between CAR ceilings and the unvalidated sustained figures
    (40–91 RPM at 10 000 TPM) is unexplained pending A1 re-runs. For quota-saturation experiments,
    CAR mode at steady rate is more conservative and more reproducible than closed-loop load.
