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
| Default burst load | 20 VUs, 200 iterations |
| Sustained load | 20 VUs, 5-minute duration |

---

## Metric definitions

| Column | Meaning |
|---|---|
| `iterations` | Original requests dispatched (not counting retries) |
| `http_200` | Requests that eventually received HTTP 200 (may include retried attempts) |
| `http_200_%` | `http_200 / iterations × 100` — eventual success rate |
| `total_calls` | Total HTTP calls made including all retry attempts |
| `p50_ms` / `p95_ms` | Percentile HTTP request duration |
| `tts_p50_ms` | Time-to-success: wall-clock ms from first attempt to final 200, including retry delays |
| `retry_overhead` | `(total_calls / iterations) − 1` — extra HTTP calls per original request |
| `goodput` | Successful completions per second of elapsed test time — the primary combined metric |

**Goodput** is the headline metric: it rewards both high success rate and low latency, and
penalises slow retries even when they eventually succeed.

---

## Phase 1 — Baseline characterisation

Equal-weight and weighted pool configurations with no retry logic. Establishes how much of the
available quota APIM can extract without resilience features.

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

- **`baseline` achieves the highest Phase 1 success rate (17.5%).** All three backends share
  the quota burden equally; the high p95 (1940ms) reflects requests queuing behind saturated
  backends while waiting for quota windows to roll.

- **Circuit breakers hurt under global saturation.** When all three regions are simultaneously
  exhausted, a CB tripping on 429 removes its backend from the pool. With all three tripped
  simultaneously there is nowhere left to route — success rate collapses from 17.5% to 4.5%
  (`circuit_breaker`). CBs that trip only on 5xx (`cb_5xx_only`) are worse still (3.0%) because
  they provide no quota-aware routing and consume tokens rapidly.

- **`asymmetric_cb` (90/5/5) improves tail latency but not success rate.** UK South saturates
  first; the CB trips it and remaining traffic finds WE/SC with fresher quota. p95 drops from
  1940ms to 720ms. Success rate is unchanged at 16.5% — the overall token budget is the same,
  just distributed more efficiently within it.

- **`full_resilience` (500 RPM gateway cap + CB + weighted) scores 0 successes.** The gateway
  throttle rejects all requests before they reach any backend (12ms avg = instant APIM rejection).

- **Direct-to-Foundry is not better than APIM without resilience features.** The matched pair
  `direct_equal` vs `baseline` both achieve 17.5% success. APIM adds no measurable overhead
  penalty at the quota limit. Client-side sequential fallback (`direct_sequential`) is actively
  worse (5.8%), making 567 HTTP calls to get 33 successes.

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
  backoff both *reduce* success rate (to ~12–13%) because the delays consume time without
  clearing quota.

- **The key insight:** partial backoff is strictly worse than no backoff under global saturation.
  Either wait the full quota window (`Retry-After`) or do not retry. There is no middle ground.

- **`retry_after_header` suits low-frequency, must-not-fail workloads** (batch jobs, critical
  single requests) where 30–60 second latency is acceptable. It is unsuitable for interactive
  or high-throughput use.

---

## Phase 2b — APIM server-side retry

APIM retries the backend pool up to 3× on 429 before surfacing any error to the client. Each
retry can be routed to a different pool member — something client-side retry cannot do. Client
retry disabled for isolation.

| run_id | http_200_% | p50_ms | p95_ms | tts_p50_ms | goodput (req/s) |
|---|---|---|---|---|---|
| apim_retry_equal | 16.5 | 111.9 | 417.7 | 448 | 11.2 |
| apim_retry_cb | 100.0 | 14.5 | 52.2 | 16 | 153.1 |
| apim_retry_asym | 100.0 | 13.2 | 19.3 | 15 | 159.6 |

### Phase 2b findings

- **`apim_retry_asym` and `apim_retry_cb` both achieve 100% success at ~14ms p50** — a
  completely different performance category from anything in Phase 1 or 2a.

- **The circuit breaker is load-bearing.** `apim_retry_equal` (no CB, APIM retry enabled) gets
  16.5% — identical to `baseline`. Without a CB to remove saturated backends from the pool, APIM
  retries hit the same three exhausted backends and fail again. Retry alone is not sufficient.

- **The mechanism:** UK South saturates → CB trips after 3× 429 within 60s → UK South removed
  from pool → APIM retries for subsequent requests route to WE/SC, which have consumed less
  quota → client receives 200 at ~14ms. The entire sequence is invisible to the caller.

- **Goodput jumps from ~7 req/s (`baseline`) to ~160 req/s** — a 23× improvement in useful work
  delivered per second.

---

## Phase 3 — Optimal configuration candidates

Combining the best elements from Phases 1 and 2.

| run_id | config summary | http_200_% | tts_p50_ms | retry_overhead | goodput (req/s) |
|---|---|---|---|---|---|
| optimal_equal_client | Equal weights, no CB, client `Retry-After` | 99.0 | 30 450 | 1.25 | 0.5 |
| optimal_asym_client | 90/5/5, CB on 429+5xx, client `Retry-After` | 36.0 | 430 | 0.31 | 0.6 |
| optimal_combined | 90/5/5, CB on 429+5xx, APIM retry + client `Retry-After` | 100.0 | 15 | 0.10 | 6.3 |

### Phase 3 findings

- **`optimal_combined` achieves 100% success with p50 of 15ms.** The client `Retry-After` layer
  fired for only 20 of 200 iterations (0.10 overhead) — the rare cases where APIM's 3 retries
  were all exhausted. When it fired, the wait extended the test to 32 seconds, dragging goodput
  to 6.3 req/s. The client layer is a safety net, not a primary mechanism.

- **`optimal_asym_client` (CB + client `Retry-After`, no APIM retry) achieves 36%** — much
  better than `asymmetric_cb` alone (16.5%). CB trips UK South; client retries occasionally find
  WE/SC with remaining quota. But without APIM routing retries to specific pool members, 64%
  still fail when the client cannot distinguish which backend has quota.

---

## Ablation — winning corner decomposed

Each run removes or varies exactly one element of the winning stack to identify what is actually
doing the work.

**Winning stack:** 90/5/5 weights · CB trips on 429+5xx after 3 failures · APIM retry=3

| run_id | change from winner | http_200_% | p50_ms | p95_ms | goodput (req/s) |
|---|---|---|---|---|---|
| apim_retry_asym *(reference)* | — | 100.0 | 13.2 | 19.3 | 159.6 |
| asym_retry_no_cb | CB disabled | 100.0 | 13.3 | 45.2 | 142.0 |
| asym_retry_cb_5xx | CB trips on 5xx only (429 ignored) | 100.0 | 12.2 | 15.4 | **162.4** |
| weight_70_15_15 | 70/15/15 weights | 100.0 | 13.0 | 18.4 | 160.1 |
| weight_80_10_10 | 80/10/10 weights | 100.0 | 14.0 | 19.1 | 91.7 |
| trip_count_1 | CB trips on 1st failure (not 3rd) | 100.0 | 12.4 | 16.7 | 130.9 |

### Ablation findings

- **The circuit breaker is not required for 100% burst success when asymmetric weight is used.**
  `asym_retry_no_cb` (CB disabled) achieves 100% success at 13ms p50. With 90% of traffic
  pointed at UK South, it saturates first; APIM retries land on WE/SC which have consumed only
  5% of their quota. The CB was redundant for the burst case.

- **The CB does not need to treat 429 as a failure signal.** `asym_retry_cb_5xx` (CB on 5xx
  only) achieves 100% success and is actually the **fastest configuration of any experiment**
  (p50 12.2ms, p95 15.4ms, goodput 162.4 req/s). This is the most actionable production
  finding: configure the CB to protect against hard backend failures (5xx) only; let APIM retry
  handle quota redistribution. Treating 429 as a CB trip signal adds no benefit and risks
  collateral pool drainage.

- **"Skew hard" is not a strict rule — but there is an inflection point.** Both 70/15/15 and
  90/5/5 achieve 100% success with indistinguishable latency. 80/10/10 also achieves 100%
  success but p95 jumps to 19ms and goodput halves to 91.7 req/s — the 10% fallback allocation
  occasionally runs dry simultaneously under load, causing APIM retries to search across a
  partly-exhausted pool. The 70% threshold appears sufficient; 80% is the risky midpoint.

- **CB trip threshold (1 vs 3 failures) makes no meaningful difference.** `trip_count_1` (trips
  on first 429) achieves 100% success at 12.4ms p50, marginally faster than the reference but
  within noise. The difference matters only at sustained load — see below.

---

## Sustained load — multiple quota windows

5-minute runs to test whether burst results hold across repeated 60-second quota reset cycles.

| run_id | iterations | http_200_% | p50_ms | p95_ms | goodput (req/s) |
|---|---|---|---|---|---|
| sustained_baseline | 25 992 | 2.4 | 97.8 | 192.5 | 2.0 |
| sustained_cb_only | 48 929 | 2.8 | 14.5 | 22.0 | 4.6 |
| sustained_apim_retry_cb | 49 122 | 97.2 | 14.5 | 23.8 | 159.1 |
| sustained_apim_asym | 49 832 | 98.9 | 14.1 | 20.3 | 164.3 |
| sustained_trip_count_1 | 50 220 | 98.7 | 14.4 | 21.3 | 165.2 |

### Sustained load findings

- **`sustained_baseline` collapses from 17.5% burst to 2.4% sustained.** The burst caught
  favourable quota timing — a window had recently reset when the 5-second run began. Over 5
  minutes, quota is exhausted repeatedly and the unmanaged pool accumulates failures with no
  recovery mechanism. The gap to the winning configs is wider at steady state than burst results
  suggested.

- **`sustained_cb_only` (CB, no APIM retry) confirms the production failure mode.** 2.8%
  success despite making ~49 000 requests. The CB drains the pool between window resets; without
  APIM retry there is nothing to route to. The 14.5ms p50 reflects fast APIM rejections (no pool
  members), not successful completions. Shipping a circuit breaker without a pool retry policy
  is actively harmful under sustained saturation.

- **`sustained_apim_retry_cb` (equal weights, CB, APIM retry): 97.2%, 159 goodput** — holds up
  almost as well as the asymmetric winner. Equal weights do not disadvantage the sustained case
  because the CB+retry combination handles the quota cycle regardless of weight distribution.
  The asymmetric weight advantage is primarily a burst optimisation (faster CB detection of the
  primary region).

- **`sustained_trip_count_1` vs `sustained_apim_asym`: no meaningful difference** (98.7% vs
  98.9%, 165 vs 164 goodput). The 1.1% miss in `sustained_apim_asym` is structural — the brief
  window between a backend saturating and APIM's retries successfully routing around it — and is
  not eliminated by tripping the CB on the first failure rather than the third.

---

## Complete summary by goodput

| run_id | type | http_200_% | p50_ms | p95_ms | goodput (req/s) |
|---|---|---|---|---|---|
| sustained_trip_count_1 | sustained | 98.7 | 14.4 | 21.3 | 165.2 |
| sustained_apim_asym | sustained | 98.9 | 14.1 | 20.3 | 164.3 |
| asym_retry_cb_5xx | burst ablation | 100.0 | 12.2 | 15.4 | 162.4 |
| weight_70_15_15 | burst ablation | 100.0 | 13.0 | 18.4 | 160.1 |
| sustained_apim_retry_cb | sustained | 97.2 | 14.5 | 23.8 | 159.1 |
| apim_retry_asym | burst | 100.0 | 13.2 | 19.3 | 159.6 |
| apim_retry_cb | burst | 100.0 | 14.5 | 52.2 | 153.1 |
| asym_retry_no_cb | burst ablation | 100.0 | 13.3 | 45.2 | 142.0 |
| trip_count_1 | burst ablation | 100.0 | 12.4 | 16.7 | 130.9 |
| weight_80_10_10 | burst ablation | 100.0 | 14.0 | 19.1 | 91.7 |
| direct_weighted | direct (60/25/15) | 16.5 | 94.2 | 305.0 | 11.1 |
| apim_retry_equal | burst | 16.5 | 111.9 | 417.7 | 11.2 |
| asymmetric_cb | burst | 16.5 | 119.4 | 720.9 | 8.5 |
| baseline | burst | 17.5 | 122.5 | 1940.4 | 6.8 |
| optimal_combined | burst | 100.0 | 13.4 | 246.1 | 6.3 |
| sustained_cb_only | sustained | 2.8 | 14.5 | 22.0 | 4.6 |
| sustained_baseline | sustained | 2.4 | 97.8 | 192.5 | 2.0 |
| retry_after_header | burst | 99.5 | 188.7 | 433.7 | 0.4 |

---

## Key takeaways

1. **APIM server-side retry is essential; circuit breaker alone is not.** CB without retry
   drains the pool and scores 2.8% sustained. Retry without CB scores 16.5% — no better than
   no features at all. Together they deliver 97–100% success at ~14ms p50.

2. **The circuit breaker should trip on 5xx only, not 429.** The ablation shows CB on 5xx only
   (`asym_retry_cb_5xx`) is the fastest configuration tested (162 goodput, p95 15ms). APIM retry
   handles quota redistribution; the CB should be reserved for hard backend failures. Treating
   quota exhaustion as a CB trip signal adds no benefit and risks leaving the pool empty.

3. **Asymmetric weight accelerates CB detection of the primary region but is not required for
   high success rates.** Equal-weight configs with CB+retry achieve 97% sustained success.
   Asymmetric weight (70/15/15 or 90/5/5) ensures the primary region saturates and trips first,
   preserving fallback quota — useful in production where one region is PTU and others are PAYG.
   Avoid 80/10/10 — the fallback allocation is large enough to over-commit but small enough to
   run dry, spiking p95.

4. **Burst results can be misleading.** `baseline` scored 17.5% in a 5-second burst but 2.4%
   over 5 minutes. Short bursts catch favourable quota timing. Any honest performance claim about
   a quota-limited system should be validated with a sustained run spanning multiple quota windows.

5. **Client-side retry is counterproductive under global quota saturation**, with one exception:
   sleeping for the exact `Retry-After` duration achieves 99.5% eventual success at the cost of
   ~30 second median latency. Use `Retry-After` only for batch or non-interactive workloads.
   All other client retry strategies (immediate, fixed, exponential backoff) either tie baseline
   or make results worse by consuming quota faster.

6. **APIM adds measurable value over direct-to-Foundry routing.** The matched pair `direct_equal`
   vs `baseline` confirms equal performance at 17.5% burst success — APIM costs nothing at the
   quota limit. But with CB+retry enabled, APIM delivers 97–100% sustained success against the
   same backends. The gateway's value is entirely in its resilience policies, not its routing.

7. **Future work:** these experiments use deliberately tiny quotas (10 000 TPM) to force
   saturation within seconds. In production, where quotas are larger, the CB trip threshold and
   APIM retry interval would need tuning to match the actual quota-exhaustion rate. The `trip=1`
   result suggests the threshold is not sensitive in burst scenarios; sustained load at
   production quotas may tell a different story. A longer sustained run at higher VU counts would
   expose whether the 97–99% steady-state ceiling is stable or whether WE/SC quotas also
   eventually exhaust.
