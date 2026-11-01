# Experiment Plan: Retry Strategies and Optimal Configuration

> **Note:** This plan was written before two correctness bugs were discovered and fixed.
> Results referenced here (including `cb_5xx_only` at 3.0%, Phase 2b 100% claims, and
> Phase 3 "winning stack" analysis) reflect bleed-contaminated or pre-fix data. See
> [`RESULTS.md`](RESULTS.md) for the correct findings.

## Context

Phase 1 experiments characterised the behaviour of APIM load balancing, circuit breaking, and
gateway throttling under deliberate quota saturation (20 VUs, 200 iterations, 10 000 TPM per
Foundry backend). All three regions share the same deliberately low quota, so every run saturates
the available token budget within seconds. The key Phase 1 findings are:

| run_id            | total_reqs | http_200 | http_200_% | avg_ms | p50_ms  | p95_ms  | req/s  |
|-------------------|------------|----------|------------|--------|---------|---------|--------|
| baseline          | 200        | 35       | 17.5       | 354.6  | 122.5   | 1940.4  | 39.0   |
| weighted_primary  | 200        | 33       | 16.5       | 434.4  | 379.9   | 1120.5  | 33.8   |
| circuit_breaker   | 200        | 9        | 4.5        | 123.4  | 106.1   | 250.2   | 83.2   |
| gateway_throttle  | 200        | 7        | 3.5        | 57.5   | 11.8    | 159.2   | 82.6   |
| full_resilience   | 300        | 0        | 0.0        | 12.6   | 11.6    | 17.7    | 238.0  |
| asymmetric_cb     | 200        | 33       | 16.5       | 231.8  | 119.4   | 720.9   | 51.7   |
| cb_5xx_only       | 200        | 6        | 3.0        | 117.2  | 98.4    | 297.4   | 76.3   |
| direct_sequential | 567        | 33       | 5.8        | 134.2  | 101.1   | 375.1   | 106.2  |
| direct_weighted   | 200        | 33       | 16.5       | 128.9  | 94.2    | 305.0   | 67.4   |

### Phase 1 anchor scenarios

**Best success rate — `baseline`**
Equal weights (33/33/34), no circuit breaker, no rate limit. 17.5% of requests succeed, with
13.65 successful completions per second. The high p95 (1940ms) reflects requests queuing while
backends work through their quota windows.

**Best tail-latency / throughput balance — `asymmetric_cb`**
90/5/5 weights, circuit breaker trips after 3× (429 or 5xx) per backend. UK South saturates
quickly, the CB trips and redistributes remaining traffic to West Europe and Sweden Central, which
still have fresh quota. Success rate (16.5%) is nearly identical to `baseline`, but p95 drops from
1940ms → 720ms because stale backends are removed from the pool rather than queued against.
Effective successful completions per second: ~8.5 (lower than baseline because fewer total req/s).

**Key insight:** Circuit breakers that include 429 in the failure signal reduce tail latency under
asymmetric load (one region saturates first). They *hurt* under symmetric global saturation
(circuit_breaker run: 4.5%) because they trip all three backends simultaneously, leaving no live
backend in the pool.

---

## Phase 2: Retry Strategies

**Goal:** Improve eventual success rate by retrying failed requests rather than discarding them.
Retries can live at two layers: client-side (k6) or server-side (APIM policy).

### Success metric change

With retries, `http_req_failed` rate is misleading (it counts HTTP calls, not original requests).
Phase 2 introduces custom k6 metrics:

- `eventual_successes` — counter: original requests that eventually got HTTP 200
- `eventual_success_rate` — gauge: eventual_successes / iterations
- `total_http_calls` — counter: actual HTTP calls made (originals + retries)
- `retry_overhead` — gauge: (total_http_calls / iterations) − 1 (extra calls per original request)
- `time_to_success_ms` — trend: wall-clock time from first attempt to 200 response, including
  retry delays (undefined for requests that never succeed)

### 2a — Client-side retry experiments

Base configuration: equal weights (33/33/34), no circuit breaker, 10 000 RPM limit.
This isolates the retry strategy as the sole variable.

Up to 3 retry attempts per original request. On each attempt: if HTTP 429 → apply strategy delay
→ retry. If HTTP 200 → record success and stop. If 3 retries exhausted → record failure.

| id                       | strategy                                  | max_retries | delay formula              |
|--------------------------|-------------------------------------------|-------------|----------------------------|
| `retry_immediate`        | Retry on 429, no delay                    | 3           | 0ms                        |
| `retry_fixed_1s`         | Retry on 429, fixed delay                 | 3           | 1 000ms                    |
| `retry_backoff`          | Exponential backoff                       | 3           | 500ms × 2^attempt          |
| `retry_backoff_jitter`   | Exponential backoff + uniform jitter      | 3           | 500ms × 2^attempt ± 50%    |
| `retry_after_header`     | Respect Azure Retry-After response header | 3           | `Retry-After` value (ms)   |

**Hypothesis:** `retry_after_header` will achieve the highest eventual success rate because it
avoids hammering an exhausted backend during its quota window. `retry_immediate` will have the
worst effective success rate because rapid retries consume quota faster than it replenishes.
`retry_backoff_jitter` prevents thundering herd and should outperform fixed backoff.

### 2b — APIM server-side retry experiments

APIM `<retry>` policy retries the backend call before returning any response to the client.
Combined with a backend pool, a server-side retry can pick a *different* backend on each attempt —
something client-side retry cannot do without knowing the backend topology.

Requires adding a `<retry>` block to `infra/apim_policy.tf`:

```xml
<retry condition="@(context.Response.StatusCode == 429)" count="3" interval="1" first-fast-retry="false">
    <set-backend-service backend-id="foundry-pool" />
</retry>
```

The `interval` (seconds) is a new Terraform variable `apim_retry_interval_s`.

| id                    | config                                                        | apim_retry | apim_retry_interval_s | cb |
|-----------------------|---------------------------------------------------------------|------------|-----------------------|----|
| `apim_retry_equal`    | Equal weights, APIM retries, no CB                            | 3          | 1                     | 0  |
| `apim_retry_cb`       | Equal weights, APIM retries, CB trips on 429+5xx              | 3          | 1                     | 3  |
| `apim_retry_asym`     | 90/5/5 weights, APIM retries, CB trips on 429+5xx             | 3          | 1                     | 3  |

**Hypothesis:** `apim_retry_asym` will outperform client-side equivalents because APIM can route
each retry to a different pool member, spreading retries across regions with fresher quota windows.

---

## Phase 3: Optimal Configuration Search

Using the findings from Phases 1 and 2, Phase 3 combines the best-performing elements into a
small set of candidate "optimal" configurations and cross-validates them.

### Inputs

From Phase 1:
- Best success rate base: **`baseline`** (equal weights, no CB)
- Best tail-latency base: **`asymmetric_cb`** (90/5/5, CB on 429+5xx)

From Phase 2 (expected best-performing):
- Best client-side retry: **`retry_after_header`** or **`retry_backoff_jitter`** (TBD from results)
- Best server-side retry: **`apim_retry_asym`** (TBD from results)

### Phase 3 experiments

| id                        | weights     | CB           | APIM retry | Client retry        | rationale                                       |
|---------------------------|-------------|--------------|------------|---------------------|-------------------------------------------------|
| `optimal_equal_client`    | 33/33/34    | none         | none       | best Phase 2 client | Adds client retry to best Phase 1 success-rate  |
| `optimal_asym_client`     | 90/5/5      | 429+5xx, t=3 | none       | best Phase 2 client | Adds client retry to best Phase 1 tail-latency  |
| `optimal_equal_apim`      | 33/33/34    | none         | best Phase 2 APIM | none         | APIM retry on equal-weight base                 |
| `optimal_asym_apim`       | 90/5/5      | 429+5xx, t=3 | best Phase 2 APIM | none         | APIM retry on asymmetric CB base                |
| `optimal_combined`        | 90/5/5      | 429+5xx, t=3 | 3 × 1s     | retry_backoff_jitter | Both layers: APIM retries + client backoff      |

**`optimal_combined`** is the fully-stacked configuration. Both retry layers serve different
failure modes: APIM retries handle transient backend unavailability (switching pool member
transparently); client retries handle cases where all backends were simultaneously saturated at the
APIM level (APIM gave up, client backs off and retries after quota replenishment).

### Expected outcome

A fully-stacked configuration risks *over-retrying*: if all three backends are simultaneously
saturated, both retry layers fire, producing 4× the HTTP calls per original request while none
succeed. The optimal configuration is likely one or the other retry layer, not both. Phase 3
lets the data decide.

---

## Implementation notes

### k6 script changes (Phase 2a)

`experiment/load_test.js` needs:
- `RETRY_STRATEGY` env var: `none` | `immediate` | `fixed` | `backoff` | `backoff_jitter` | `retry_after`
- `MAX_RETRIES` env var (default 3)
- `RETRY_DELAY_MS` env var (base delay for fixed/backoff strategies, default 500)
- Custom Trend metric `time_to_success` and Counter `eventual_successes`
- Loop: attempt → on 429 apply delay → retry up to MAX_RETRIES

### Terraform changes (Phase 2b)

`infra/apim_policy.tf`:
- New variable `apim_retry_count` (default 0 = disabled)
- New variable `apim_retry_interval_s` (default 1)
- Conditional `<retry>` block in inbound policy

`infra/variables.tf`:
- Add `apim_retry_count` and `apim_retry_interval_s`

### Summarise changes

`experiment/summarise.py`:
- Read `eventual_successes` counter if present, fall back to `http_req_failed`-derived count
- Add `retry_overhead` column when `total_http_calls` metric is present
- Add `time_to_success_p50` and `time_to_success_p95` columns

### run_experiments.sh changes

- Add Phase 2a entries with `RETRY_STRATEGY` and `MAX_RETRIES` k6 env vars
- Add Phase 2b entries with `-var "apim_retry_count=3"` terraform args
- Phase 3 entries compose both sets of vars

---

## Ordering

1. Implement k6 retry logic and new metrics → validate with a short smoke run
2. Run Phase 2a experiments (client-side, 5 runs)
3. Implement APIM retry Terraform → apply to dev state
4. Run Phase 2b experiments (APIM server-side, 3 runs)
5. Identify winners → construct Phase 3 experiment definitions
6. Run Phase 3 experiments (5 runs)
7. Run `experiment/summarise.py` across all phases → write `experiment/RESULTS.md`
