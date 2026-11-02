# Load Balancing Experiment Results

Experiments characterise the behaviour of Azure API Management (APIM) as an AI gateway in front
of three Azure AI Foundry deployments (UK South, West Europe, Sweden Central), under deliberate
quota saturation. Phases 1–3 and sustained original runs used `gpt-4.1-mini` with **10 000 TPM**
per region — chosen specifically to be exhaustible within seconds, making failure modes visible.
Phase 4 CAR runs and A1/A2 re-runs used **60 000 TPM** per region.

Load was generated locally with [Grafana k6](https://k6.io). Each request sends a fixed
single-sentence prompt with `max_tokens: 5`.

> **Data integrity note — three bugs required multiple re-runs:**
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
> runs may be contaminated: `apim_retry_equal`, `asym_retry_no_cb`, `optimal_equal_apim`. Their
> original results (18.0–18.5%) are indistinguishable from the 17.5% baseline, suggesting
> contamination was absent or minor. Re-runs were conducted at 60 000 TPM (A2, see below).
>
> **Bug 3:** `azapi_update_resource` with `circuitBreaker.rules = []` was rejected by the Azure
> ARM API with ValidationError ("at least one rule should be defined"). The resource was updated to
> use `circuitBreaker = null` instead, which explicitly clears CB config on every `terraform apply`.
> Phase 4 CAR runs and all A1–A4 re-runs used this fix.
>
> **A1–A4 re-runs completed 2026-11-02 at 60 000 TPM** with the Bug 3 fix in place.
> A1 (sustained re-runs) and A2 (burst re-runs) ran at 60 000 TPM; results annotated in their
> sections. A3 (CAR spill repeats ×3) and A4 (direct-to-Foundry CAR comparison) completed;
> results in Phase 4. All tables now reflect validated data.

---

## Setup

| Parameter | Value |
|---|---|
| Gateway | Azure API Management (Developer tier) |
| Backends | 3 × Azure AI Foundry (OpenAI kind), one per region |
| Auth | System-assigned managed identity + Cognitive Services OpenAI User RBAC |
| Model | gpt-4.1-mini (2025-04-14) |
| Quota per backend | 10 000 TPM (Phases 1–3 and sustained original); 60 000 TPM (Phase 4 + A1/A2 re-runs) |
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
| `p50_succ_ms` | Median duration for requests that succeeded (body-validated) |
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

- **For no-retry configurations, weight distribution modulates CB impact.** CB on 429+5xx with
  equal weights (4.5%) is the dangerous case because all backends drain simultaneously. CB on
  429+5xx with asymmetric weights (16.5%) is effectively neutral because the primary drains first
  and the fallbacks are spared. CB on 5xx only (16.5%) is always neutral. When APIM retry is
  enabled (Phase 2b/ablation), weight distribution becomes secondary — the presence or absence of
  CB on 429 determines outcome far more than the weight split.

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

APIM retries the backend pool up to 3× on 429. Without CB, each retry re-enters the same
weighted pool — it can select any member, including the one that just returned 429.
Client retry disabled for isolation. Original runs at 10 000 TPM.

| run_id | config | http_200_% | p50_ms | tts_p50_ms | goodput (req/s) |
|---|---|---|---|---|---|
| apim_retry_equal ¹ | Equal weights, no CB | 18.5 | 1128.9 | 553 | 2.9 |
| apim_retry_cb | Equal weights, CB on 429+5xx | 4.5 | 1078.3 | 454 | 1.1 |
| apim_retry_asym | 90/5/5, CB on 429+5xx | 18.0 | 1091.1 | 408 | 3.7 |

¹ May carry stale CB rules (Bug 2). The result (18.5%) is indistinguishable from the 17.5% baseline,
suggesting contamination was absent or had minimal impact on this run.

**A2 re-run at 60 000 TPM (2026-11-02, Bug 3 fix applied, body-validated):**

| run_id | config | iterations | http_200 | http_200_% | p50_ms | p50_succ_ms |
|---|---|---|---|---|---|---|
| apim_retry_equal_r2 | Equal weights, no CB, APIM retry=3 | 200 | 193 | **96.5** | 358 | 365 |

At 60 000 TPM the 200-iteration burst achieves 96.5%. The exact quota mechanism that permits this
is not fully characterised: the measured CAR ceiling of ~72 RPM would, if applied directly to the
burst rate, predict fewer successes — suggesting the RPM limit operates differently under short
burst conditions than under sustained CAR load (see open question in TK11). Empirically, APIM
retry without CB is highly effective when backends have quota available. The key variable is quota
saturation level, not CB state.

### Phase 2b findings

- **At 10 000 TPM: APIM retry without CB gives marginal burst improvement (18.5% vs 17.5%
  baseline).** All three backends are simultaneously quota-exhausted; a retry to a different pool
  member still lands in a depleted environment ~80% of the time. The p50 of 1129 ms confirms
  genuine model completions, but the overall success rate barely exceeds the no-retry baseline.

- **At 60 000 TPM: APIM retry without CB achieves 96.5%.** When backends have quota headroom,
  retries find fresh capacity and succeed at near-100%. The TPM level is the binding variable:
  APIM retry is a low-cost resilience feature that scales with available quota.

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

- **At 10K TPM with APIM retry, CB state is the key variable — weight distribution is
  secondary.** With CB off: equal weights (18.5%) ≈ 90/5/5 (18.0%) — weights are
  indistinguishable. With CB on 429+5xx: equal weights (4.5%) is disastrous, asymmetric
  (18.0%) is not — here weights modulate CB's impact, but only because CB is the active
  mechanism. Turning CB off removes the sensitivity to weights entirely.

---

## Phase 3 — Optimal configuration candidates

| run_id | config | http_200_% | tts_p50_ms | retry_overhead | goodput (req/s) |
|---|---|---|---|---|---|
| optimal_equal_client | Equal, no CB, client `Retry-After` | 99.0 | 30 450 | 1.25 | 0.5 |
| optimal_asym_client | 90/5/5, CB on 429+5xx, client `Retry-After` | 36.0 | 430 | 0.31 | 0.6 |
| optimal_equal_apim ¹ | Equal, no CB, APIM retry=3 | 18.0 | 450 | 0.0 | 2.8 |
| optimal_asym_apim | 90/5/5, CB on 429+5xx, APIM retry=3 | 5.5 | 379 | 0.0 | 1.6 |
| optimal_combined | 90/5/5, CB on 429+5xx, APIM retry + client `Retry-After` | 16.5 | 334 | 0.0 | 13.3 |

¹ May carry stale CB rules. A2 re-run: `optimal_equal_apim_r2` at 60 000 TPM = **90.5%** (181/200,
p50=349 ms, p50_succ=360 ms) — consistent with `apim_retry_equal_r2` (96.5%), confirming the
60K-TPM APIM-retry-without-CB result is robust.

### Phase 3 findings

- **`optimal_equal_client` achieves 99.0%** via client `Retry-After` — same mechanism as Phase 2a.

- **`optimal_asym_client` achieves 36%** — the highest burst success rate without a 30-second
  sleep. CB trips UK South early; client retries sometimes find West Europe or Sweden Central
  with remaining quota. The 0.31 retry overhead is low because most successes come from the
  first attempt against an open fallback backend.

- **`optimal_equal_apim` (equal, no CB, APIM retry): 18.0% at 10K TPM** — consistent with
  `apim_retry_equal` (18.5%). Equal weights with no CB at 10K TPM is the reliable best without
  client-side retry under global quota saturation. At 60K TPM the same config (r2) achieves 90.5%.

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

All ablation runs performed with 60-second CB isolation gap. Original runs at 10 000 TPM.

**Reference:** `apim_retry_equal` — 18.5% burst at 10 000 TPM, equal weights, no CB, APIM retry=3. ¹

| run_id | change | http_200_% | p50_ms | goodput (req/s) | notes |
|---|---|---|---|---|---|
| apim_retry_equal *(ref)* ¹ | — | 18.5 | 1128.9 | 2.9 | |
| asym_retry_no_cb ¹ | 90/5/5 weights, no CB | 18.0 | 1096.1 | 3.0 | |
| asym_retry_cb_5xx | 90/5/5, CB on 5xx only | 17.0 | 1095.5 | 2.7 | |
| weight_70_15_15 | 70/15/15, CB on 429+5xx | 16.5 | 13.4 | 8.0 | ² |
| weight_80_10_10 | 80/10/10, CB on 429+5xx | 16.5 | 106.2 | 7.6 | |
| trip_count_1 | 90/5/5, CB trips on 1st failure | 16.5 | 13.2 | 9.9 | ² |

¹ Possibly contaminated by stale CB rules (Bug 2). Results (18.0–18.5%) match the 17.5% baseline —
indicates contamination was absent or negligible.

² Goodput elevated by fast CB-induced 503s (p50=13ms); only 33 real completions.

**A2 re-run at 60 000 TPM (2026-11-02, Bug 3 fix applied, body-validated):**

| run_id | change | iterations | http_200 | http_200_% | p50_ms | p50_succ_ms |
|---|---|---|---|---|---|---|
| asym_retry_no_cb_r2 | 90/5/5 weights, no CB, APIM retry=3 | 200 | 190 | **95.0** | 353 | 362 |

At 60K TPM, 90/5/5 weights with no CB achieves 95.0% — consistent with equal-weight no-CB at
60K TPM (96.5%). Weight distribution (90/5/5 vs 33/33/34) makes negligible difference to burst
success when CB is off and quota is available.

### Ablation findings

- **Weight distribution between 33/33/34 and 90/5/5 makes no meaningful difference to burst
  success rate when CB is off or on 5xx only, at both 10K and 60K TPM.** At 10K TPM:
  `asym_retry_no_cb` (18.0%) and the equal-weight reference (18.5%) are statistically
  indistinguishable. At 60K TPM: `asym_retry_no_cb_r2` (95.0%) and `apim_retry_equal_r2`
  (96.5%) are also indistinguishable. The weights shape which backend saturates first; when
  APIM retry has fresh backends to route to, the weights are a second-order concern.

- **CB on 5xx only is transparent.** With only quota-related 429s occurring, the CB never
  triggers. Performance is identical to no-CB configurations.

- **Weight skew with CB on 429+5xx affects p50 timing but not overall success count.**
  `weight_80_10_10` (80/10/10): p50=106ms (requests are mostly real completions);
  `weight_70_15_15` (70/15/15): p50=13ms (most requests hit CB-tripped 503, a few succeed).
  The bimodal distribution in `weight_70_15_15` reflects UK South tripping early and WE/SC
  handling residual traffic, with some fast CB fails once they also approach their quota.

- **CB trip threshold (1 vs 3 failures) matters primarily for how fast UK South is removed.**
  `trip_count_1` (p50=13ms, fast pool drain) vs reference (p50=1129ms, gradual). Success
  count is identical at ~33 completions, confirming the bottleneck is total token budget, not
  how quickly backends are detected as saturated.

---

## Sustained load — multiple quota windows

5-minute runs reveal whether burst results hold across repeated 60-second quota resets.

**Original runs at 10 000 TPM (unvalidated — body check absent):**

| run_id | config | iterations | http_200 | http_200_% | goodput (req/s) |
|---|---|---|---|---|---|
| sustained_cb_only ⚠ | Equal, CB on 429+5xx, no retry | 48 929 | 1 368 | 2.8 | 4.6 |
| sustained_baseline ⚠ | Equal, no CB, no retry | 25 992 | 627 | 2.4 | 2.0 |
| sustained_apim_asym | 90/5/5, CB on 429+5xx, APIM retry=3 | 46 281 | 161 | 0.3 | 0.5 |
| sustained_apim_retry_cb | Equal, CB on 429+5xx, APIM retry=3 | 44 660 | 156 | 0.3 | 0.5 |
| sustained_trip_count_1 | 90/5/5, CB trip=1, APIM retry=3 | 46 388 | 161 | 0.3 | 0.5 |

⚠ `sustained_baseline` and `sustained_cb_only` lack body validation. p50 ≈ 14 ms for their
reported 200s is inconsistent with real LLM completions (~300–400 ms); counts are likely inflated
by synthetic gateway responses. The three retry-enabled runs show p50 ~285 ms for their 200s —
consistent with real completions and considered reliable.

Run order by file timestamp (2026-11-01): `sustained_baseline` (09:45), `sustained_cb_only`
(10:00), then burst APIM runs, then `sustained_apim_asym` (14:29), `sustained_apim_retry_cb`
(14:34), `sustained_trip_count_1` (14:39). Each had the 60-second CB isolation gap.

**Validated re-runs at 60 000 TPM (2026-11-02, Bug 3 fix + body validation):**

| run_id | config | iterations | http_200 | http_200_% | p50_ms | p50_succ_ms | goodput (req/s) |
|---|---|---|---|---|---|---|---|
| sustained_baseline_r2 | Equal, no CB, no retry | 23 228 | 1 079 | 4.6 | 115 | 329 | 3.6 |
| sustained_cb_only_r2 | Equal, CB on 429+5xx, no retry | 46 063 | 1 030 | 2.2 | 15 | 342 | 3.4 |
| sustained_apim_retry_60k | Equal, no CB, APIM retry=3 | 5 255 | 1 078 | 20.5 | 1 128 | 374 | 3.6 |
| sustained_apim_asym_60k | 90/5/5, CB on 429+5xx, APIM retry=3 | 45 183 | 1 021 | 2.3 | 15 | 318 | 3.4 |

p50_succ of 318–374 ms confirms all successes are genuine LLM completions. The wide range of
success rates (2.3%–20.5%) across configs reflects different iteration counts caused by
different failure latencies, not different actual throughput.

### Sustained load findings

- **All four 60K TPM sustained configs achieve the same goodput: 3.4–3.6 req/s (the quota
  ceiling).** The 60K TPM ceiling is 3 × ~72 RPM ÷ 60 = **3.6 req/s**. Every configuration
  tested — baseline, CB-only, APIM retry, and asymmetric+CB+retry — lands within 6% of that
  ceiling. **Routing configuration does not affect sustained goodput when quota is the binding
  constraint.**

- **The success-rate column is misleading across configs.** Different failure latencies produce
  different iteration counts: slow APIM retry failures (p50=1128ms) → 5 255 iterations in 5 min;
  fast CB rejections (p50=15ms) → 45 183 iterations. But actual completions (~1020–1079) are
  nearly identical across all four runs. Use goodput, not success rate, for sustained comparisons.

- **`sustained_apim_retry_60k` confirms APIM retry does not degrade sustained throughput.**
  Goodput = 3.6 req/s, identical to no-retry baseline. The mechanism is simply that each failed
  APIM retry call takes longer to return a 503 (multiple backend attempts before giving up),
  reducing the VU cycle rate but not the actual completion rate.

- **The original "CB-only best sustained (2.8% vs 2.4%)" finding was an artifact.** Without body
  validation, both `sustained_baseline` and `sustained_cb_only` included synthetic gateway 200s
  (p50 ≈ 14 ms). Their apparent goodput of 2.0–4.6 req/s was 3.3–7.7× above the 10K TPM
  ceiling of ~0.6 req/s — impossible without artificial inflation.

- **Retry-enabled configs at 10K TPM (original runs): 0.5 req/s.** The 10K ceiling is ~0.6
  req/s; these also appear ceiling-bound. The original "8× catastrophic degradation" compared
  unvalidated inflated baseline counts against reliable retry counts. At matched quota (60K),
  retry and no-retry have identical goodput.

- **`sustained_cb_only_r2` and `sustained_apim_asym_60k` p50=15ms (all) with p50_succ=318–342ms
  confirm the CB mechanism.** Fast CB rejections account for the 15 ms overall median; the small
  fraction that escapes shows real 318–342 ms completion latency. Quota gates the ceiling; CB and
  retry change only the failure pattern, not the completion count.

---

## Complete summary

| run_id | type | http_200_% | p50_ms | goodput (req/s) |
|---|---|---|---|---|
| retry_after_header | burst client | 99.5 | 188.7 | 0.4 |
| optimal_equal_client | burst client | 99.0 | 146.9 | 0.5 |
| **car_direct_spill** / **_r2** / **_r3** | **CAR direct** | **100.0** | **280–298** | — |
| car_baseline | CAR Phase 4 | 100.0 | 374 | — |
| **car_retry_cb429_90_5_5_trip1** | **CAR Phase 4** | **99.3** | **330** | — |
| **car_retry_cb429_90_5_5** / **_r2** | **CAR Phase 4** | **98.0** | **328–334** | — |
| car_retry_cb429_90_5_5_r3 | CAR Phase 4 | 93.5 | 345 | — |
| apim_retry_equal_r2 | burst APIM 60K | 96.5 | 358 | — |
| asym_retry_no_cb_r2 | burst ablation 60K | 95.0 | 353 | — |
| optimal_equal_apim_r2 | burst APIM 60K | 90.5 | 349 | — |
| optimal_asym_client | burst client | 36.0 | 94.5 | 0.6 |
| apim_retry_equal | burst APIM 10K | 18.5 | 1128.9 | 2.9 |
| apim_retry_asym | burst APIM 10K | 18.0 | 1091.1 | 3.7 |
| asym_retry_no_cb | burst ablation 10K | 18.0 | 1096.1 | 3.0 |
| optimal_equal_apim | burst APIM 10K | 18.0 | 1118.2 | 2.8 |
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
| **sustained_baseline_r2** | **sustained 60K** | **4.6** | **115** | **3.6** |
| **sustained_apim_retry_60k** | **sustained 60K** | **20.5** | **1 128** | **3.6** |
| **sustained_cb_only_r2** | **sustained 60K** | **2.2** | **15** | **3.4** |
| **sustained_apim_asym_60k** | **sustained 60K** | **2.3** | **15** | **3.4** |
| sustained_cb_only ⚠ | sustained 10K | 2.8 | 14.5 | 4.6 |
| sustained_baseline ⚠ | sustained 10K | 2.4 | 97.8 | 2.0 |
| circuit_breaker | burst APIM | 4.5 | 106.1 | 3.7 |
| apim_retry_cb | burst APIM | 4.5 | 1078.3 | 1.1 |
| gateway_throttle | burst APIM | 3.5 | 11.8 | 2.9 |
| retry_backoff | burst client | 13.0 | 107.2 | 0.6 |
| retry_backoff_jitter | burst client | 13.0 | 107.0 | 0.6 |
| retry_fixed_1s | burst client | 12.0 | 100.8 | 0.6 |
| direct_sequential | burst direct | 16.5 ² | 101.1 | 6.2 |
| optimal_asym_apim | burst APIM | 5.5 | 24.6 | 1.6 |
| sustained_apim_asym | sustained 10K | 0.3 | 13.5 | 0.5 |
| sustained_apim_retry_cb | sustained 10K | 0.3 | 13.8 | 0.5 |
| sustained_trip_count_1 | sustained 10K | 0.3 | 13.7 | 0.5 |
| full_resilience | burst APIM | 0.0 | 11.6 | 0.0 |
| car_90_5_5 | CAR Phase 4 | 70.4 | 288 | — |
| car_90_5_5_r2 | CAR Phase 4 | 69.6 | 297 | — |
| car_90_5_5_r3 | CAR Phase 4 | 69.8 | 292 | — |
| car_cb5xx_90_5_5 | CAR Phase 4 | 69.9 | 281 | — |
| car_retry_90_5_5 | CAR Phase 4 | 68.2 | 361 | — |
| car_retry_90_5_5_r2 | CAR Phase 4 | 68.2 | 371 | — |
| car_retry_90_5_5_r3 | CAR Phase 4 | 69.1 | 384 | — |
| car_retry_cb5xx_90_5_5 | CAR Phase 4 | 68.2 | 389 | — |

¹ Goodput elevated by fast CB-induced 503s; not comparable with real-completion goodput.

² `direct_sequential` denominator is HTTP calls (567), not iterations (200). Correct per-request rate: 33 ÷ 200 = **16.5%**.

⚠ Unvalidated: body check absent; 200 counts include synthetic gateway responses.

**60K** suffix indicates re-run at 60 000 TPM; **10K** indicates original 10 000 TPM run.

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

### Results (2026-11-02, r1 validated; r2/r3 repeats)

All runs used the `circuitBreaker = null` fix (commit `ee87a8b`) and 60 000 TPM per backend.
No `dropped_iterations` on any run. Body validation (`choices[]` check) confirmed all `http_200`
counts as real model responses.

**r1 results:**

| run_id | iterations | http_200 | http_200_% | p50_req_ms | p50_success_ms |
|---|---|---|---|---|---|
| `car_baseline` | 301 | 301 | **100.0** | 374 | 381 |
| `car_90_5_5` | 601 | 423 | 70.4 | 288 | 326 |
| `car_cb5xx_90_5_5` | 601 | 420 | 69.9 | 281 | 312 |
| `car_retry_90_5_5` | 601 | 410 | 68.2 | 361 | 342 |
| `car_retry_cb5xx_90_5_5` | 600 | 409 | 68.2 | 389 | 358 |
| `car_retry_cb429_90_5_5` | 600 | 588 | **98.0** | 328 | 333 |

All p50 values are in the 280–390 ms range — consistent with real LLM completions.

**A3 repeat results (r2, r3) and A4 direct comparison:**

| run_id | iterations | http_200 | http_200_% | p50_ms | p50_succ_ms |
|---|---|---|---|---|---|
| car_90_5_5_r2 | 601 | 418 | 69.6 | 297 | 338 |
| car_90_5_5_r3 | 600 | 419 | 69.8 | 292 | 326 |
| car_retry_90_5_5_r2 | 601 | 410 | 68.2 | 371 | 352 |
| car_retry_90_5_5_r3 | 601 | 415 | 69.1 | 384 | 363 |
| car_retry_cb429_90_5_5_r2 | 601 | 589 | 98.0 | 334 | 339 |
| car_retry_cb429_90_5_5_r3 | 599 | 560 | 93.5 | 345 | 352 |
| **car_retry_cb429_90_5_5_trip1** | **600** | **596** | **99.3** | **330** | **338** |
| **car_direct_spill** | **601** | **601** | **100.0** | **298** | **402** |
| **car_direct_spill_r2** | **601** | **601** | **100.0** | **293** | **363** |
| **car_direct_spill_r3** | **601** | **601** | **100.0** | **280** | **388** |

`car_direct_spill` runs use `direct_car_test.js`: sequential client fallback (UK South → West
Europe → Sweden Central) at 2 req/s with no APIM, body-validated. `total_http_calls` now
recorded: r2=842, r3=900 → retry overhead 0.40–0.50 extra calls per success.

`car_retry_cb429_90_5_5_trip1` uses CB trip count=1 (UK South removed after first failure).

**Spread summary across r1–r3 (APIM arms) and n=3 confirmed (direct):**

| arm | r1 | r2 | r3 | mean | range |
|---|---|---|---|---|---|
| `car_90_5_5` | 70.4% | 69.6% | 69.8% | **69.9%** | 69.6–70.4% |
| `car_retry_90_5_5` | 68.2% | 68.2% | 69.1% | **68.5%** | 68.2–69.1% |
| `car_retry_cb429_90_5_5` | 98.0% | 98.0% | 93.5% | **96.5%** | 93.5–98.0% |
| `car_retry_cb429_90_5_5_trip1` | 99.3% | — | — | **99.3%** | n=1 |
| `car_direct_spill` | 100.0% | 100.0% | 100.0% | **100.0%** | 100.0% |

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

| config | UK South (offered) | WE (offered) | SC (offered) | expected success |
|---|---|---|---|---|
| 33/33/34 (calibration) | 0.33 req/s (20 RPM) | 0.33 req/s | 0.33 req/s | ~100% ✓ |
| 90/5/5 (spill) | 1.8 req/s (108 RPM) | 0.1 req/s (6 RPM) | 0.1 req/s (6 RPM) | ~70% ✓ |

### Phase 4 findings

- **Unassisted spill: 69.9% (range 69.6–70.4%, n=3).** Without any recovery mechanism, UK South
  saturates at 108 RPM offered (ceiling ~72 RPM). WE and SC serve all their requests at 100%.
  Overall success is 0.9 × (72/108) + 0.05 × 1.0 + 0.05 × 1.0 ≈ 70%. The range across three
  independent runs is < 1 percentage point — the measurement is stable.

- **CB on 5xx only: 69.9%.** Indistinguishable from `car_90_5_5`. No 5xx errors occur in a
  quota-saturation scenario (backends return 429, not 5xx); the CB never fires.

- **APIM retry without CB: 68.5% (range 68.2–69.1%, n=3) — slightly worse than no retry.**
  The slight decrease vs no-retry is consistent across all three repeats (not noise). The
  proposed mechanism — retries re-enter the 90/5/5 pool and ~90% re-hit UK South — is derived
  from pool weights, not directly measured. The additional per-retry delay (p50=361–384 ms vs
  288–297 ms for no-retry) is consistently observed.

- **APIM retry + CB on 5xx: 68.2%.** Same as retry without CB. CB on 5xx is silent under
  429-only failures; the retry pool selection is identical.

- **APIM retry + CB on 429+5xx: 96.5% (range 93.5–98.0%, n=3).** UK South receives 429s, trips
  the CB, and is removed from the pool. APIM retries are then forced to WE and SC — both under
  10% of their quota ceiling — and succeed at ~100%. The shortfall from 100% is the ramp-up
  window before UK South accumulates enough failures to trip the CB; r3 (93.5%) is the worst
  case where that window is longest.

  **CB on 429 is necessary for APIM retry to actually route to fallbacks.** Without it, retry
  is unguided and returns to the saturated primary.

- **CB trip count=1 (single-failure trip): 99.3% (n=1).** Reducing the trip threshold from 3
  to 1 eliminates most of the ramp-up window: UK South is removed from the pool after a single
  429 instead of three. This closes the gap from 93.5–98.0% to 99.3% — approaching the direct
  fallback result. This is a concrete production recommendation: **prefer a low CB trip count
  (1 or 2) in the spill regime** to minimise failures during the CB activation window.

- **Sequential client fallback: 100.0% (n=3 confirmed) — confirmed to match or beat APIM
  CB+retry.** All three direct runs achieved 601/601. `total_http_calls` = 842–900, giving
  retry overhead of 0.40–0.50 extra calls per success (the wasted UK South attempt). The
  success latency (p50_succ 363–402 ms) is ~25–65 ms above APIM CB+retry (~338 ms) due to
  that extra call. Limitations: direct uses a fixed UK South–first ordering vs APIM's 90/5/5
  weighted pool; no per-region counters; clients must hold API keys for all regions and bypass
  APIM's centralised policy, auth, and observability. **APIM's value is operational, not
  throughput** — the best APIM config (CB+retry, trip=1) achieves 99.3%, within 0.7 pp of
  direct.

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

1. **At 10K TPM (global quota saturation), burst success plateaus at ~17–18% for almost all
   APIM configurations.** The fundamental constraint is token budget. Whether CB is on or off,
   whether weights are symmetric or asymmetric, whether APIM retry is enabled — burst results
   cluster at 16.5–18.5% with one exception: CB on 429+5xx with equal weights and retry collapses
   to 4.5%. At 60K TPM (quota-available), APIM retry without CB achieves 90–96%: the TPM
   level — not the routing config — is the binding variable.

2. **The dangerous burst combination is CB on 429+5xx + APIM retry with equal weights.** Each
   retried 429 increments the CB failure counter; all backends trip in sequence; the pool empties.
   With asymmetric weights (90/5/5), CB on 429+5xx at burst is harmless because the fallbacks
   are never close to exhaustion. CB on 5xx only is always safe — it never fires when the only
   failure mode is quota 429s.

3. **CB on 5xx only is always neutral at quota saturation.** It never fires during quota
   saturation (there are no 5xx errors, only 429s). It is the correct production CB setting: it
   protects against hard backend failures without interfering with quota redistribution.

4. **Routing configuration does not affect sustained throughput — quota level does.** At 60K TPM,
   all four sustained configs tested (baseline, CB-only, APIM retry, asymmetric+CB+retry) achieve
   3.4–3.6 req/s — the quota ceiling. APIM retry at sustained 60K confirmed: same goodput as
   no-retry. The original "APIM retry catastrophic at sustained (0.3% vs 2.4%)" finding compared
   unvalidated inflated 10K baseline counts against reliable 10K retry counts; the matched-quota
   comparison shows no retry penalty. **To increase sustained throughput, increase quota.**

5. **CB without retry does not materially improve sustained throughput.** At 60K TPM, CB-only
   and baseline achieve statistically identical goodput (3.4 vs 3.6 req/s). CB changes the
   failure pattern (fast rejections → more iterations, lower success rate) without changing the
   number of actual completions per second — both are constrained by the quota ceiling.

6. **Client `Retry-After` achieves 99% eventual success at 30-second median latency.** This is
   the right strategy for batch or non-interactive workloads. For interactive workloads, the
   burst ceiling without client retry is ~18% at 10K TPM and ~90–96% at 60K TPM.

7. **Burst tests on quota-limited systems can be misleading without quota context.** At 10K TPM
   (global saturation): `baseline` = 17.5% burst. At 60K TPM (quota available): APIM retry
   without CB = 90–96% burst. The quota level changes the result more than any routing
   configuration choice. Any performance claim about a quota-limited AI gateway should state the
   quota level and validate with a sustained run spanning multiple quota reset cycles.

8. **Always run a calibration gate before interpreting CAR results.** A control arm (equal
   weights, no CB, no retry) at the intended arrival rate must reach ≥ 95% success before the
   other arms are meaningful. If it fails, the arrival rate exceeds the backends' effective
   capacity and all routing configs will converge on the same throughput ceiling.
   _Phase 4 calibration gate: 100% at 1 req/s, 60 000 TPM._

9. **CB on 429 is the essential ingredient for APIM retry to route around a saturated primary;
   a low trip count eliminates most of the ramp-up loss.** In the single-region-spill regime
   (PTU primary at 108 RPM offered, fallbacks at 6 RPM):
   - No recovery: **69.9%** (range 69.6–70.4%, n=3) — stable, matches theoretical ceiling
   - CB on 5xx / retry without CB: **68–70%** — no improvement or slight regression; very tight spread
   - CB on 429 + retry, trip=3: **96.5%** (range 93.5–98.0%, n=3) — near-perfect recovery; variance from trip timing
   - CB on 429 + retry, **trip=1**: **99.3%** (n=1) — faster UK South removal closes the ramp-up window

   **Production recommendation: use CB on 429+5xx with APIM retry and a trip count of 1.**
   The retries-without-CB mechanism is derived from pool weights, not measured per-backend.

10. **Sequential client fallback confirmed at 100.0% across n=3 runs — within 0.7 pp of APIM's
    best config (CB+retry, trip=1 at 99.3%).** Total calls = 842–900, retry overhead 0.40–0.50
    extra calls per success (the wasted UK South attempt); p50_succ = 363–402 ms (~25–65 ms
    above APIM CB+retry). The mechanism advantage — client reacts instantly to the first 429
    with no CB trip window — is real but the operational trade-off is decisive for most production
    contexts: direct requires per-region API keys and bypasses APIM's centralised policy, auth,
    and observability. **APIM CB+retry (trip=1) achieves 99.3% and retains full gateway value.**

11. **The CAR-mode throughput ceiling scales linearly with TPM — but the absolute rate is
    anomalously low and the burst behaviour is not fully explained.** At 10 000 TPM the ceiling
    is ~12 RPM per backend; at 60 000 TPM it is ~72 RPM — a 6× increase with 6× quota. At the
    typical Azure ratio of ~6 RPM per 1 000 TPM, 10 000 TPM would allow ~60 RPM; the measured
    ~12 RPM is ~5× below that. The reason (separate RPM cap, model-specific limit, or
    subscription tier) has not been confirmed against the Azure portal. Additionally, the 60K
    burst test achieves 96.5% at a rate that would exceed the 72 RPM CAR ceiling if sustained
    — indicating the RPM limit applies differently to short bursts. Both open questions should
    be investigated before drawing conclusions about quota efficiency or scaling.

    For quota-saturation experiments, CAR mode at a fixed arrival rate is more conservative and
    more reproducible than closed-loop load, because fast failures do not inflate the offered load.
