# Load Balancing Experiment Results

Experiments characterise the behaviour of Azure API Management (APIM) as an AI gateway in front
of three Azure AI Foundry deployments (UK South, West Europe, Sweden Central), under deliberate
quota saturation. All runs used the same small `gpt-4.1-mini` deployment with 10 000 TPM per
region — chosen specifically to be exhaustible within seconds, making failure modes visible.

Load was generated locally with [Grafana k6](https://k6.io). Each request sends a fixed
single-sentence prompt with `max_tokens: 5` to keep token consumption deterministic.

> **Integrity note:** An earlier version of these results contained fabricated data. The
> APIM `<retry>` block was missing `<forward-request />`, so retries re-evaluated backend
> selection without actually forwarding the request. APIM returned synthetic 200 responses
> from its own cache instead of calling any model. All 14 experiments with APIM retry enabled
> were re-run after the fix was applied. A second issue (APIM circuit-breaker state persisting
> across `terraform apply` with a 30-second trip duration) compromised five further experiments;
> these were re-run with a 60-second isolation gap. Every table in this document reflects the
> corrected data only.

---

## Setup

| Parameter | Value |
|---|---|
| Gateway | Azure API Management (Developer tier) |
| Backends | 3 × Azure AI Foundry (OpenAI kind), one per region |
| Auth | System-assigned managed identity + Cognitive Services OpenAI User RBAC |
| Model | gpt-4.1-mini (2025-04-14) |
| Quota per backend | 10 000 TPM |
| Default burst load | 20 VUs, 200 iterations |
| Sustained load | 20 VUs, 5-minute duration |

---

## Metric definitions

| Column | Meaning |
|---|---|
| `iterations` | Original requests dispatched (not counting retries) |
| `http_200` | Requests that eventually received HTTP 200 |
| `http_200_%` | `http_200 / iterations × 100` — eventual success rate |
| `total_calls` | Total HTTP calls including all retry attempts |
| `p50_ms` / `p95_ms` | Percentile HTTP request duration (all requests, including fast failures) |
| `tts_p50_ms` | Time-to-success: ms from first attempt to final 200, including retry delays |
| `retry_overhead` | `(total_calls / iterations) − 1` — extra HTTP calls per original request |
| `goodput` | Successful completions ÷ wall-clock seconds. Rewards high success and low latency jointly. |

**Goodput caveat:** when a configuration fails fast (e.g. CB-induced 503 in 13ms), the short
elapsed time can inflate goodput even at low success rates. Treat goodput as a meaningful
combined metric only when comparing runs with similar failure modes.

**APIM retry → 503 behaviour:** when APIM exhausts all retries with the last response still
being 429, it returns 503 to the caller. k6's "no server error" check (`status < 500`) fails on
these 503s. This means experiments with APIM retry may show 0 genuine 429s at the k6 layer —
all non-200 responses appear as 5xx (APIM's own 503), not as backend 429s.

---

## Phase 1 — Baseline characterisation

Equal-weight and weighted pool configurations with no retry logic. Establishes the quota budget
APIM can extract without resilience features.

| run_id | http_200_% | p50_ms | p95_ms | goodput (req/s) |
|---|---|---|---|---|
| baseline | 17.5 | 122.5 | 1940.4 | 6.8 |
| weighted_primary | 16.5 | 379.9 | 1120.5 | 5.6 |
| circuit_breaker | 4.5 | 106.1 | 250.2 | 3.7 |
| gateway_throttle | 3.5 | 11.8 | 159.2 | 2.9 |
| full_resilience | 0.0 | 11.6 | 17.7 | 0.0 |
| asymmetric_cb | 16.5 | 119.4 | 720.9 | 8.5 |
| cb_5xx_only | 3.0 | 98.4 | 297.4 | 2.3 |

**Direct-to-Foundry comparators (no APIM):**

| run_id | weights | http_200_% | p50_ms | goodput (req/s) | notes |
|---|---|---|---|---|---|
| direct_sequential | UK→WE→SC fallback | 5.8 | 101.1 | 6.2 | 567 HTTP calls for 33 successes |
| direct_weighted | 60/25/15 | 16.5 | 94.2 | 11.1 | mismatched weights vs baseline |
| direct_equal | 33/33/34 | 17.5 | 104.4 | 3.1 | matched pair with baseline |

### Phase 1 findings

- **`baseline` (equal weights, no CB, no retry) achieves the highest Phase 1 success rate
  (17.5%).** The pool distributes requests evenly; quota is consumed proportionally; the test
  catches some requests in the remaining window before all three regions saturate. The high p95
  (1940ms) reflects requests queuing while waiting for a backend with remaining quota.

- **Circuit breaker on 429+5xx collapses success rate from 17.5% to 4.5%** (`circuit_breaker`).
  When all three equally-weighted regions simultaneously exhaust their quota, the CB trips all
  three and the pool has no remaining open backends. Every subsequent request gets an instant 503.
  The 3.7 goodput is high only because failures are fast (106ms) — there are only 9 real
  completions.

- **`asymmetric_cb` (90/5/5, CB on 429+5xx) maintains 16.5%.** UK South absorbs 90% of
  traffic, saturates first, and trips. West Europe and Sweden Central have consumed only 5% of
  their quota each, so requests land there with quota still available. The p95 drops from 1940ms
  to 720ms because the fast-failing primary region is removed early.

- **`cb_5xx_only` (CB trips on 5xx only, equal weights, no retry) scores only 3.0%.** This is
  _worse_ than `circuit_breaker`. Without 429 as a CB signal, all three regions remain "open"
  while their quota is exhausted — every request reaches a backend but gets 429'd. There is no
  redistribution mechanism to steer traffic toward fresher quota. This establishes that CB alone,
  regardless of trigger, does not improve success rate without a complementary retry mechanism.

- **`full_resilience` (500 RPM gateway cap + CB + weighted) scores 0 successes.** The gateway
  throttle rejects all requests before they reach any backend (12ms avg = instant APIM rejection).

- **APIM adds no latency overhead vs direct at equal quota utilisation.** `direct_equal` and
  `baseline` both achieve 17.5% success. The gateway pays for itself only when resilience
  features are added.

---

## Phase 2a — Client-side retry strategies

Client retries on 429 up to 3 attempts. Base config: equal weights, no circuit breaker, no APIM
retry. Isolates retry strategy as the sole variable.

| run_id | http_200_% | total_calls | tts_p50_ms | retry_overhead | goodput (req/s) |
|---|---|---|---|---|---|
| retry_immediate | 17.5 | 730 | 548 | 2.65 | 5.0 |
| retry_fixed_1s | 12.0 | 762 | 1 568 | 2.81 | 0.6 |
| retry_backoff | 13.0 | 752 | 920 | 2.76 | 0.6 |
| retry_backoff_jitter | 13.0 | 752 | 1 078 | 2.76 | 0.6 |
| retry_after_header | 99.5 | 481 | 30 516 | 1.40 | 0.4 |

### Phase 2a findings

- **`retry_after_header` achieves 99.5% eventual success** — the only client strategy that
  approaches 100%. Azure returns a `Retry-After` header on 429 indicating when the quota window
  resets. Sleeping for that exact duration means the retry always lands in a fresh window. The
  cost is latency: p50 time-to-success is **30 seconds**, p95 is **61 seconds**.

- **Every other client retry strategy underperforms or ties `baseline` (17.5%).** Backoff delays
  of 500ms–2s are far too short to outlast a 60-second quota window. Immediate retry ties
  baseline at 17.5% but makes 3.65× the HTTP calls with no improvement. Fixed and exponential
  backoff both _reduce_ success rate (to ~12–13%) because the delays consume time without
  clearing quota.

- **The key insight:** partial backoff is strictly worse than no backoff under global saturation.
  Either wait the full quota window (`Retry-After`) or do not retry. There is no middle ground.

- **`retry_after_header` suits low-frequency, must-not-fail workloads** (batch jobs, critical
  single requests) where 30–60 second latency is acceptable. It is unsuitable for interactive
  or high-throughput use.

---

## Phase 2b — APIM server-side retry

APIM retries the backend pool up to 3× on 429 before surfacing any error to the client. Each
retry can be routed to a different pool member via `<set-backend-service>`. Client retry
disabled for isolation.

| run_id | config | http_200_% | p50_ms | tts_p50_ms | goodput (req/s) |
|---|---|---|---|---|---|
| apim_retry_equal | Equal weights, no CB, APIM retry=3 | 18.5 | 1128.9 | 553 | 2.9 |
| apim_retry_cb | Equal weights, CB on 429+5xx, APIM retry=3 | 4.5 | 1078.3 | 454 | 1.1 |
| apim_retry_asym | 90/5/5, CB on 429+5xx, APIM retry=3 | 0.0 | 13.6 | — | 0.0 |

### Phase 2b findings

- **APIM retry alone (no CB) improves burst success rate marginally: 18.5% vs 17.5% baseline.**
  When APIM retries a 429 it picks a new pool member via `<set-backend-service>`, which may have
  remaining quota. The improvement is small because all three regions are simultaneously
  saturated — a retry landing on a different region still has a high chance of 429. The 1129ms
  p50 confirms these are genuine model completions (not fast APIM rejections).

- **Adding CB on 429+5xx with APIM retry collapses success to 4.5%** (`apim_retry_cb`).
  Each APIM retry that receives a 429 increments the CB failure counter. Three consecutive
  429-retries trip the backend. With equal weights and saturated quota, retries cycle through
  all three backends, tripping each in turn. The pool drains; subsequent requests get instant 503.

- **With asymmetric weights (90/5/5) + CB + retry: 0.0% success** (`apim_retry_asym`).
  90% of traffic hits UK South → saturates → CB trips. APIM retries the pool (now 90% tripped),
  retries land on WE/SC → they saturate and trip → pool fully drained → all 503. Run completes
  in 1.3 seconds because every request fails instantly once all three backends are tripped.

- **The root problem:** APIM retry amplifies the request rate against quota-limited backends,
  while CB on 429 treats the resulting 429s as hard failures and removes backends from the pool.
  The combination empties the pool in seconds under global saturation.

---

## Phase 3 — Optimal configuration candidates

Combining elements from Phases 1 and 2 to find the best achievable success rate.

| run_id | config summary | http_200_% | tts_p50_ms | retry_overhead | goodput (req/s) |
|---|---|---|---|---|---|
| optimal_equal_client | Equal weights, no CB, client `Retry-After` | 99.0 | 30 450 | 1.25 | 0.5 |
| optimal_asym_client | 90/5/5, CB on 429+5xx, client `Retry-After` | 36.0 | 430 | 0.31 | 0.6 |
| optimal_equal_apim | Equal weights, no CB, APIM retry=3 | 18.0 | 450 | 0.0 | 2.8 |
| optimal_asym_apim | 90/5/5, CB on 429+5xx, APIM retry=3 | 5.5 | 379 | 0.0 | 1.6 |
| optimal_combined | 90/5/5, CB on 429+5xx, APIM retry + client `Retry-After` | 0.0 | — | 0.0 | 0.0 |

### Phase 3 findings

- **`optimal_equal_client` achieves 99.0% using client `Retry-After`** — confirming Phase 2a.
  APIM acts as a simple proxy here; the client's `Retry-After` sleep is doing all the work.
  Median wait to success is 30 seconds.

- **`optimal_asym_client` (CB + client `Retry-After`, no APIM retry) achieves 36%** — the
  highest success rate achievable in a ~2-minute burst without a 30-second sleep. The CB trips
  UK South; client retries occasionally find WE/SC with remaining quota. The 0.31 retry overhead
  is low because most successes come from the first attempt against a briefly-open fallback.

- **`optimal_equal_apim` (APIM retry, no CB): 18.0%** — identical to `apim_retry_equal` in
  Phase 2b. Equal weights with no CB is the highest-goodput configuration that avoids CB pool
  drain.

- **`optimal_asym_apim` (CB on 429+5xx + APIM retry, asymmetric): 5.5%** — CB partially drains
  the pool but does not fully empty it within 200 iterations. The 379ms tts_p50 confirms
  completions are real.

- **`optimal_combined` (CB + APIM retry + client `Retry-After`): 0.0%.** The APIM retry storm
  drains all three backends before the client's `Retry-After` can save any request. Complete
  pool exhaustion in 2.4 seconds.

---

## Ablation — isolating which variables matter

Each run removes or varies exactly one element to identify what drives success. All five ablation
runs were performed with a 60-second isolation gap to prevent CB state bleed between experiments.

**Reference point:** `apim_retry_equal` (APIM retry=3, no CB, equal weights) — 18.5% burst.

| run_id | change from reference | http_200_% | p50_ms | goodput (req/s) | notes |
|---|---|---|---|---|---|
| apim_retry_equal *(reference)* | — | 18.5 | 1128.9 | 2.9 | |
| asym_retry_no_cb | 90/5/5 weights, no CB | 18.0 | 1096.1 | 3.0 | near-identical |
| asym_retry_cb_5xx | 90/5/5, CB on 5xx only | 17.0 | 1095.5 | 2.7 | neutral CB |
| weight_70_15_15 | 70/15/15, CB on 429+5xx | 16.5 | 13.4 | 8.0 | fast CB 503s inflate goodput |
| weight_80_10_10 | 80/10/10, CB on 429+5xx | 0.0 | 14.1 | 0.0 | full pool drain |
| trip_count_1 | 90/5/5, CB trips on 1st failure | 16.5 | 13.2 | 9.9 | fast CB 503s inflate goodput |

> **Goodput note for `weight_70_15_15` and `trip_count_1`:** their high goodput values reflect
> fast CB-induced 503s (test completes in 3–4 seconds), not efficient delivery. Each has only
> 33 real completions. Goodput is not meaningful for comparison here.

### Ablation findings

- **Weight skew (90/5/5 vs 33/33/34) makes no measurable difference to success rate when CB
  is disabled.** `asym_retry_no_cb` (18.0%) and the equal-weight reference (18.5%) are within
  noise. Asymmetric weights do not help when CB is off and all three regions are saturated.

- **CB on 5xx only is neutral** (`asym_retry_cb_5xx`, 17.0%). The CB never fires because all
  failures are 429s, not 5xx. Success rate and tts_p50 are indistinguishable from the reference.
  This is the correct production setting: protect against hard backend failures without penalising
  quota redistribution.

- **CB on 429+5xx with 70/15/15 weights degrades success (16.5%) and with 80/10/10 causes
  complete pool drain (0.0%).** The failure mode is identical to Phase 2b: CB trips backends
  faster than APIM retries can recover. 80/10/10 is the worst midpoint — the fallback allocation
  is large enough to saturate but the primary dominates long enough to trip first, leaving
  fallbacks over-committed. 70/15/15 partially escapes this but still underperforms no-CB.

- **CB trip threshold (1 vs 3 failures) changes timing, not outcome.** `trip_count_1` drains the
  pool faster (3.3 seconds vs 4.1 seconds for 70/15/15), but the end state is the same: pool
  partly or fully tripped, most requests failing.

- **The effective ablation winner is: equal weights + APIM retry + no CB, or alternatively
  any-weight + APIM retry + CB on 5xx only.** Both achieve ~17–18.5% burst success. CB on
  429+5xx consistently makes things worse.

---

## Sustained load — multiple quota windows

5-minute runs test whether burst results hold across repeated 60-second quota reset cycles.

| run_id | config | iterations | http_200 | http_200_% | goodput (req/s) |
|---|---|---|---|---|---|
| sustained_cb_only | Equal weights, CB on 429+5xx, no retry | 48 929 | 1 368 | 2.8 | 4.6 |
| sustained_baseline | Equal weights, no CB, no retry | 25 992 | 627 | 2.4 | 2.0 |
| sustained_apim_asym | 90/5/5, CB on 429+5xx, APIM retry=3 | 46 281 | 161 | 0.3 | 0.5 |
| sustained_apim_retry_cb | Equal weights, CB on 429+5xx, APIM retry=3 | 44 660 | 156 | 0.3 | 0.5 |
| sustained_trip_count_1 | 90/5/5, CB trips on 1st, APIM retry=3 | 46 388 | 161 | 0.3 | 0.5 |

### Sustained load findings

- **`sustained_baseline` (no features) achieves 2.4% over 5 minutes.** The quota resets every
  60 seconds across all three regions simultaneously; without any routing logic, requests land
  at whichever backend happens to have quota remaining at that moment.

- **`sustained_cb_only` (CB on 429+5xx, no retry) is the best APIM configuration at sustained
  load: 2.8%, 4.6 goodput.** The CB trips backends within milliseconds of quota exhaustion,
  then waits PT30S (the CB trip duration) before re-opening. When backends re-open, their quota
  window has had time to partially reset — requests that land in that window find available quota
  and complete in ~16ms (fresh backend, no queue). The CB is acting as a rate limiter that
  synchronises with the quota cycle.

- **`sustained_apim_retry_cb`, `sustained_apim_asym`, and `sustained_trip_count_1` all deliver
  0.3% success and 0.5 goodput** — a 9× regression vs the baseline. Adding APIM retry to a
  CB-on-429 pool amplifies the request storm: each incoming request generates up to 3 retries
  against backends whose quota is already exhausted. The burst of retried requests exhausts any
  briefly-recovered quota within milliseconds of the window resetting. The CB re-trips
  immediately. Nothing useful gets through.

- **The sustained result completely reverses the burst hierarchy.** The burst winner
  (`apim_retry_equal`, 18.5%) was not run at sustained load — but the pattern is clear: APIM
  retry + CB on 429 is catastrophic under multi-window sustained saturation.

- **Under global quota saturation, no APIM configuration exceeds 5% sustained success.** The
  fundamental constraint is token budget: 3 × 10 000 TPM = 30 000 tokens/minute. At ~25 tokens
  per request (5-token response + short prompt), the theoretical maximum is ~500 successful
  requests per minute (8.3 req/s). The best sustained configuration (`sustained_cb_only`)
  delivers 1368 successes over 5 minutes = 4.6 req/s, reaching ~55% of the theoretical ceiling.

---

## Complete summary by goodput (adjusted success ≥ 5%)

Configurations achieving fewer than 5 real completions are excluded as not meaningfully comparable.

| run_id | type | http_200_% | p50_ms | goodput (req/s) |
|---|---|---|---|---|
| sustained_cb_only | sustained | 2.8 | 14.5 | 4.6 |
| sustained_baseline | sustained | 2.4 | 97.8 | 2.0 |
| retry_after_header | burst | 99.5 | 188.7 | 0.4 |
| optimal_equal_client | burst | 99.0 | 146.9 | 0.5 |
| optimal_asym_client | burst | 36.0 | 94.5 | 0.6 |
| apim_retry_equal | burst | 18.5 | 1128.9 | 2.9 |
| optimal_equal_apim | burst | 18.0 | 1118.2 | 2.8 |
| asym_retry_no_cb | burst ablation | 18.0 | 1096.1 | 3.0 |
| baseline | burst | 17.5 | 122.5 | 6.8 |
| direct_equal | burst direct | 17.5 | 104.4 | 3.1 |
| asym_retry_cb_5xx | burst ablation | 17.0 | 1095.5 | 2.7 |
| weight_70_15_15 | burst ablation | 16.5 | 13.4 | 8.0 ¹ |
| asymmetric_cb | burst | 16.5 | 119.4 | 8.5 ¹ |
| weighted_primary | burst | 16.5 | 379.9 | 5.6 |
| direct_weighted | burst direct | 16.5 | 94.2 | 11.1 ¹ |
| trip_count_1 | burst ablation | 16.5 | 13.2 | 9.9 ¹ |
| retry_immediate | burst | 17.5 | 103.3 | 5.0 |

¹ Goodput elevated by fast failures (CB 503s in <15ms); actual completions ≈ 33.

---

## Key takeaways

1. **CB on 429+5xx + APIM retry is the worst APIM configuration under global quota saturation.**
   The retry amplifies the request flood; the CB counts each retried 429 as a failure and trips
   backends. Together they drain the pool in seconds. Success rates collapse to 0–5% burst and
   0.3% sustained — worse than doing nothing (17.5% burst, 2.4% sustained).

2. **The circuit breaker trigger matters more than anything else.** CB on 5xx only
   (`asym_retry_cb_5xx`) achieves 17% burst — indistinguishable from no CB at all. CB on
   429+5xx consistently causes pool drain. The production setting should be: CB triggers on 5xx
   (hard backend failures) only; let APIM retry handle 429 redistribution.

3. **APIM retry without CB gives a marginal burst improvement: 18.5% vs 17.5% baseline.**
   The improvement comes from routing retries to different pool members. Without CB, the pool
   stays open and retries have a chance of landing on a backend with remaining quota. This is the
   best APIM-only burst configuration, but the absolute success ceiling is still ~18%.

4. **Under sustained saturation, CB-only (no retry) is the best APIM strategy: 2.8% vs 2.4%
   baseline.** The CB acts as a rate limiter that synchronises with the quota reset cycle:
   backends trip within milliseconds of exhaustion, wait 30 seconds (during which the quota
   window resets), then re-open into a briefly-available window. No retry means no amplification
   storm that re-exhausts the window immediately.

5. **Client-side `Retry-After` achieves 99% eventual success at 30-second median latency.**
   This is the right tool for batch, non-interactive, or idempotent workloads where latency is
   acceptable. For interactive workloads it is unusable.

6. **Weight skew (90/5/5 vs 33/33/34) has no material effect without CB.** When all three
   regions are simultaneously exhausted, re-routing 90% to one of them does not help. Asymmetric
   weights make sense in PTU+PAYG mixed deployments, where one region has dedicated throughput
   and the others are fallbacks — not in this experiment where all three are equally constrained.

7. **No configuration exceeds ~5% sustained success under global 10 000 TPM × 3 saturation.**
   The fundamental constraint is token budget. In production, larger quotas and less aggressive
   load will produce better numbers — but the _relative_ rankings of configurations will hold.
   Burst results consistently overstate sustained performance.
