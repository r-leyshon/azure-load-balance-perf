# Load Balancing Experiment Results

Experiments characterise the behaviour of Azure API Management (APIM) as an AI gateway in front
of three Azure AI Foundry deployments (UK South, West Europe, Sweden Central), under deliberate
quota saturation. All runs used the same small `gpt-4.1-mini` deployment with 10 000 TPM per
region — chosen specifically to be exhaustible within seconds, making failure modes visible.

Load was generated locally with [Grafana k6](https://k6.io). Each request sends a fixed
single-sentence prompt with `max_tokens: 5` to keep token consumption deterministic.

---

## Setup

| Parameter | Value |
|---|---|
| Gateway | Azure API Management (Developer tier) |
| Backends | 3 × Azure AI Foundry (OpenAI kind), one per region |
| Auth | System-assigned managed identity + Cognitive Services OpenAI User RBAC |
| Model | gpt-4.1-mini (2025-04-14) |
| Quota per backend | 10 000 TPM |
| Default load | 20 VUs, 200 iterations |
| Sustained load | 20 VUs, 5-minute duration |

---

## Metric definitions

| Column | Meaning |
|---|---|
| `iterations` | Original requests dispatched (not counting retries) |
| `http_200` | Requests that eventually received HTTP 200 (may include retried attempts) |
| `http_200_%` | `http_200 / iterations × 100` — eventual success rate |
| `total_calls` | Total HTTP calls made including all retry attempts |
| `avg_ms` | Mean HTTP request duration (excludes retry delay sleep time) |
| `p50_ms` / `p95_ms` | Percentile HTTP request duration |
| `tts_p50_ms` / `tts_p95_ms` | Time-to-success: wall-clock ms from first attempt to final 200, including retry delays |
| `retry_overhead` | `(total_calls / iterations) − 1` — extra HTTP calls per original request |
| `goodput` | Successful completions per second of elapsed test time — the primary combined metric |

**Goodput** is the headline metric: it rewards both high success rate and low latency, and
penalises slow retries even when they eventually succeed.

---

## Phase 1 — Baseline characterisation

Equal-weight and weighted pool configurations with no retry logic. Establishes how much of the
available quota APIM can extract without resilience features.

| run_id | iterations | http_200 | http_200_% | p50_ms | p95_ms | goodput (req/s) |
|---|---|---|---|---|---|---|
| baseline | 200 | 35 | 17.5 | 122.5 | 1940.4 | 6.83 |
| weighted_primary | 200 | 33 | 16.5 | 379.9 | 1120.5 | 5.58 |
| circuit_breaker | 200 | 9 | 4.5 | 106.1 | 250.2 | 3.74 |
| gateway_throttle | 200 | 7 | 3.5 | 11.8 | 159.2 | 2.89 |
| full_resilience | 300 | 0 | 0.0 | 11.6 | 17.7 | 0.00 |
| asymmetric_cb | 200 | 33 | 16.5 | 119.4 | 720.9 | 8.53 |
| cb_5xx_only | 200 | 6 | 3.0 | 98.4 | 297.4 | 2.29 |

**Direct-to-Foundry comparators (no APIM):**

| run_id | iterations | http_200 | http_200_% | p50_ms | goodput (req/s) |
|---|---|---|---|---|---|
| direct_sequential | 567 | 33 | 5.8 | 101.1 | 6.18 |
| direct_weighted | 200 | 33 | 16.5 | 94.2 | 11.12 |

### Phase 1 findings

- **`baseline` achieves the highest success rate (17.5%)** of any Phase 1 config. All three
  backends share the quota burden equally; failures are spread across the burst and reflected in
  the high p95 (1940ms) as requests queue behind saturated backends.

- **Circuit breakers hurt under global saturation.** When all three regions are simultaneously
  exhausted, a CB tripping on 429 removes the backend from the pool. With all three tripped,
  there is nowhere left to route — success rate collapses from 17.5% (`baseline`) to 4.5%
  (`circuit_breaker`). CBs that trip only on 5xx (`cb_5xx_only`) are even worse (3.0%) because
  they do not help at all and still consume quota rapidly.

- **`asymmetric_cb` (90/5/5 weights) is the best Phase 1 config on tail latency.** UK South
  saturates first, CB trips it, and remaining traffic finds WE/SC with fresher quota. p95 drops
  from 1940ms to 720ms. Success rate is unchanged at 16.5% because the overall quota budget is
  the same — the CB just routes traffic more efficiently within it.

- **`full_resilience` (500 RPM gateway limit + CB + weighted) gets 0 successes.** The 500 RPM
  gateway throttle rejects requests before they reach any backend. The 12ms avg reflects APIM
  returning 429s at the gateway level almost instantly.

- **Direct-to-Foundry client-side fallback (`direct_sequential`) performs worse than APIM**
  (5.8% vs 17.5%), making 567 HTTP calls to get 33 successes. Server-side routing is more
  efficient than client-side sequential fallback.

---

## Phase 2a — Client-side retry strategies

Client retries on 429, up to 3 attempts. Base config: equal weights, no circuit breaker, no APIM
retry. Isolates retry strategy as the sole variable.

| run_id | iterations | http_200 | http_200_% | total_calls | tts_p50_ms | tts_p95_ms | retry_overhead | goodput (req/s) |
|---|---|---|---|---|---|---|---|---|
| retry_immediate | 200 | 35 | 17.5 | 730 | 548 | 811 | 2.65 | 4.98 |
| retry_fixed_1s | 200 | 24 | 12.0 | 762 | 1568 | 3819 | 2.81 | 0.59 |
| retry_backoff | 200 | 26 | 13.0 | 752 | 920 | 4433 | 2.76 | 0.65 |
| retry_backoff_jitter | 200 | 26 | 13.0 | 752 | 1078 | 3657 | 2.76 | 0.62 |
| retry_after_header | 200 | 199 | 99.5 | 481 | 30 516 | 61 012 | 1.40 | 0.44 |

### Phase 2a findings

- **`retry_after_header` achieves 99.5% eventual success** — the only client strategy that
  approaches 100%. Azure returns a `Retry-After` header on 429 indicating when the quota window
  resets. Sleeping for that exact duration means the retry always lands in a fresh window.
  The cost is severe: p50 time-to-success is **30 seconds**, p95 is **61 seconds**.

- **Every other client retry strategy underperforms `baseline` (17.5%).** Backoff delays of
  500ms–2s are long enough to reduce throughput but far too short to outlast the 60-second quota
  window. Immediate retry ties `baseline` at 17.5% but consumes 3.65× the HTTP calls with no
  improvement — each rapid retry burns quota that another VU could have used.

- **The intuitive insight:** in a globally-saturated environment, partial backoff is strictly
  worse than no backoff. Either wait the full quota window (`Retry-After`) or do not retry.
  There is no middle ground.

- **`retry_after_header` is suited to low-frequency, must-not-fail workloads** (batch jobs,
  critical single requests) where 30–60 second latency is acceptable. It is unsuitable for
  interactive or high-throughput workloads.

---

## Phase 2b — APIM server-side retry

APIM retries the backend pool up to 3× on 429 before surfacing any error to the client. Each
retry can be routed to a different pool member — something client-side retry cannot do. Client
retry disabled for isolation.

| run_id | iterations | http_200 | http_200_% | tts_p50_ms | tts_p95_ms | goodput (req/s) |
|---|---|---|---|---|---|---|
| apim_retry_equal | 200 | 33 | 16.5 | 448 | 611 | 11.24 |
| apim_retry_cb | 200 | 200 | 100.0 | 16 | 135 | 153.05 |
| apim_retry_asym | 200 | 200 | 100.0 | 15 | 107 | 159.63 |

### Phase 2b findings

- **`apim_retry_asym` and `apim_retry_cb` both achieve 100% success at ~14ms p50** — a
  completely different performance category from anything in Phases 1 or 2a.

- **The circuit breaker is load-bearing.** `apim_retry_equal` (no CB, APIM retry enabled) gets
  16.5% — identical to `baseline`. Without a CB to remove saturated backends from the pool, APIM
  retries land on the same three exhausted backends and fail again. The retry mechanism only
  works when the CB has narrowed the pool to backends with remaining quota.

- **The mechanism:** UK South saturates → CB trips (3× 429 within 60s window) → UK South removed
  from pool → APIM retries for subsequent requests route to WE/SC, which have consumed less quota
  → client receives 200. The entire sequence is invisible to the caller at ~14ms.

- **Goodput jumps from ~7 req/s (`baseline`) to ~159 req/s** — a 23× improvement in useful work
  delivered per second.

---

## Phase 3 — Optimal configuration candidates

Combining the best elements from Phases 1 and 2 to find the ceiling.

| run_id | config summary | http_200_% | tts_p50_ms | tts_p95_ms | retry_overhead | goodput (req/s) |
|---|---|---|---|---|---|---|
| optimal_equal_client | Equal weights, no CB, client `retry_after` | 99.0 | 30 450 | 60 803 | 1.25 | 0.46 |
| optimal_asym_client | 90/5/5, CB on 429+5xx, client `retry_after` | 36.0 | 429 | 44 367 | 0.31 | 0.58 |
| optimal_combined | 90/5/5, CB on 429+5xx, APIM retry + client `retry_after` | 100.0 | 15 | 30 116 | 0.10 | 6.33 |

### Phase 3 findings

- **`optimal_combined` (APIM retry + CB + client `retry_after` backstop) achieves 100% success**
  with p50 of 15ms. The client retry fired for only 20 of 200 iterations (0.10 overhead) — the
  rare cases where APIM's 3 retries were all exhausted. When it did fire, the `Retry-After` sleep
  extended the overall test duration to 31.6s, dragging goodput down to 6.33 req/s. The client
  layer is a safety net, not a primary mechanism.

- **`optimal_asym_client` (CB + client `retry_after`, no APIM retry) achieves 36%** — much
  better than `asymmetric_cb` alone (16.5%). The CB trips UK South, and when client retries
  succeed, they land quickly (tts_p50 = 429ms). But the client cannot route retries to specific
  backends, so if all CBs trip simultaneously, retries still fail.

- **Adding client `retry_after` to an already-100% APIM config is usually redundant**, but
  provides a meaningful safety net for the rare total-saturation edge case. Whether that 0.1%
  coverage justifies the tail-latency risk (p95 tts = 30s) is a product decision.

---

## Sustained load — multiple quota windows

The winning configuration (`apim_retry_asym`) run for 5 continuous minutes to test whether
the circuit breaker trip-reset cycle sustains performance across multiple 60-second quota windows.

| run_id | duration | total_calls | http_200 | http_200_% | p50_ms | p95_ms | goodput (req/s) |
|---|---|---|---|---|---|---|---|
| sustained_apim_asym | 300s | 49 832 | 49 298 | 98.9 | 14.1 | 20.3 | 164.27 |

### Sustained load findings

- **98.9% success rate and 164 goodput sustained over 5 minutes and ~50 000 requests.** The
  config performs as well under sustained load as in the initial burst — goodput is marginally
  *higher* (164 vs 159 req/s) because the CB reset-cycle reaches a steady state.

- **p95 latency of 20ms across 50 000 requests** confirms that tail latency is structurally
  controlled, not a single-burst artefact.

- **The 1.1% failure rate (~534 requests)** corresponds to the CB trip moment at the leading
  edge of each 60-second window, before APIM's retries have enough signal to route around UK
  South. These are structural and expected — not noise.

---

## Summary ranking by goodput

| Rank | run_id | http_200_% | goodput (req/s) | Notes |
|---|---|---|---|---|
| 1 | sustained_apim_asym | 98.9 | 164.27 | 5-min sustained run of winner |
| 2 | apim_retry_asym | 100.0 | 159.63 | 90/5/5 weights, CB, APIM retry |
| 3 | apim_retry_cb | 100.0 | 153.05 | Equal weights, CB, APIM retry |
| 4 | direct_weighted | 16.5 | 11.12 | No APIM — direct to Foundry |
| 5 | apim_retry_equal | 16.5 | 11.24 | APIM retry without CB — no improvement |
| 6 | asymmetric_cb | 16.5 | 8.53 | CB alone, no retry |
| 7 | baseline | 17.5 | 6.83 | No resilience features |
| — | optimal_combined | 100.0 | 6.33 | 100% success but client retry drags goodput |
| — | retry_after_header | 99.5 | 0.44 | 100% eventual success, ~30s per request |

---

## Key takeaways

1. **Circuit breakers + APIM server-side retry is the winning combination.** Neither alone is
   sufficient: APIM retry without CB gets the same result as no retry (16.5%); CB without retry
   improves tail latency but not success rate (16.5%). Together they unlock 100% success at
   14ms p50.

2. **Client-side retry strategies are almost universally counterproductive under global quota
   saturation.** The only exception is `Retry-After` header respect, which achieves near-100%
   success — but at 30-second median latency, making it suitable only for batch/non-interactive
   workloads.

3. **APIM adds measurable value over direct-to-Foundry routing.** The best no-APIM config
   (`direct_weighted`) delivers 11 goodput req/s at 16.5% success. The best APIM config
   (`apim_retry_asym`) delivers 159 goodput req/s at 100% success — a 14× improvement in useful
   throughput.

4. **Asymmetric weighting (90/5/5) outperforms equal weighting when combined with CB + retry.**
   Concentrating load on one region forces fast CB detection; retries then find two under-utilised
   backends with plentiful remaining quota. Equal weighting spreads quota exhaustion across all
   three simultaneously, leaving fewer retry opportunities.

5. **The winning config is robust under sustained load.** Across 5 minutes and ~50 000 requests
   spanning multiple quota reset cycles, goodput and latency remain stable. The circuit breaker
   trip-reset cadence reaches a steady state rather than accumulating failures over time.

6. **Future work:** these experiments use deliberately tiny quotas (10 000 TPM) to force
   saturation quickly. In production, where quotas are larger and load is spread across more
   callers, the CB trip threshold and retry interval would need tuning to match the actual
   quota-exhaustion rate. A longer sustained run at higher VU counts would expose whether the
   steady-state behaviour degrades as WE/SC quotas also approach exhaustion.
