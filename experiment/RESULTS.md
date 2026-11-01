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
> **Bug 2:** APIM circuit-breaker state is in-memory with a PT30S trip duration. It survives
> `terraform apply` of new policy configurations. Experiments whose terraform apply completed
> faster than the 30-second trip window inherited tripped backends from the previous run. Nine
> experiments were re-run with an explicit 60-second isolation gap added to `run_experiments.sh`.
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
| direct_sequential | UK→WE→SC fallback | 5.8 | 101.1 | 6.2 | 567 HTTP calls for 33 successes |
| direct_weighted | 60/25/15 | 16.5 | 94.2 | 11.1 | |
| direct_equal | 33/33/34 | 17.5 | 104.4 | 3.1 | matched pair with baseline |

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

- **`optimal_asym_apim` (90/5/5, CB on 429+5xx, APIM retry): 5.5%** — this uses the same
  configuration as `apim_retry_asym` (18.0% in Phase 2b). The discrepancy reflects inherent
  quota-timing variance: with 10 000 TPM and tests completing in 6–10 seconds, results shift
  significantly depending on where in the 60-second quota cycle the test starts. Single-run
  estimates for this configuration should be treated as 5–18% range.

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
  configuration.** The CB trips backends within milliseconds of quota exhaustion. With PT30S
  trip duration and no retry amplification, backends re-open after 30 seconds into a partially-
  recovered quota window. Requests that arrive at the moment of re-opening complete in ~16ms.
  The CB acts as a rate limiter that synchronises with the quota cycle.

- **`sustained_baseline` (no features): 2.4%.** Without CB, requests keep hitting exhausted
  backends and getting 429s. Some catch the brief window when quota has just reset. The result
  is only slightly worse than CB-only — the 0.4% difference comes from the CB's ability to
  "park" the pool for 30 seconds and then pounce on the reset window.

- **`sustained_apim_retry_cb` and `sustained_apim_asym` both 0.3% — catastrophic.** This is
  the critical sustained finding. APIM retry transforms the quota exhaustion cycle into an
  amplification storm: each incoming request generates up to 3 retries, re-exhausting any
  briefly-recovered quota within milliseconds of the window resetting. The CB re-trips
  immediately. The pattern repeats every 30 seconds, allowing only ~160 completions across the
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
| direct_sequential | burst direct | 5.8 | 101.1 | 6.2 |
| optimal_asym_apim | burst APIM | 5.5 | 24.6 | 1.6 |
| sustained_apim_asym | sustained | 0.3 | 13.5 | 0.5 |
| sustained_apim_retry_cb | sustained | 0.3 | 13.8 | 0.5 |
| sustained_trip_count_1 | sustained | 0.3 | 13.7 | 0.5 |
| full_resilience | burst APIM | 0.0 | 11.6 | 0.0 |

¹ Goodput elevated by fast CB-induced 503s; not comparable with real-completion goodput.

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
   no-features baseline (2.4%).

5. **CB without APIM retry is the best APIM strategy at sustained load: 2.8% vs 2.4% baseline.**
   Without retry amplification, the CB acts as a rate limiter that synchronises with the quota
   cycle: backends trip fast, wait 30 seconds, re-open into a briefly-available quota window,
   and some requests complete before the cycle repeats.

6. **Client `Retry-After` achieves 99% eventual success at 30-second median latency.** This is
   the right strategy for batch or non-interactive workloads. For interactive workloads, the
   ceiling without client retry is ~18% burst and ~2.8% sustained.

7. **Burst tests on quota-limited systems are systematically misleading.** `baseline` scores
   17.5% burst but 2.4% sustained. `apim_retry_asym` scores 18% burst but 0.3% sustained.
   Any performance claim about a quota-limited AI gateway should be validated with a sustained
   run spanning multiple quota reset cycles before being presented as representative.
