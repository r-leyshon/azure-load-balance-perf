# Footguns found while benchmarking APIM in front of Azure Foundry

Each entry: what goes wrong, how it showed up, how we found it, what to do. Ordered by how badly
it can mislead a conclusion. Status of affected results is noted where relevant.

---

## A. APIM policy and configuration

### 1. APIM retry silently does nothing when the request has a body (the big one)
- **Symptom:** retry configured (`count=3`), yet it never rescues a 429. Success looks like "retry
  made no difference" or "retry made things slightly worse".
- **Cause:** the first `forward-request` consumes the request body. On retry APIM re-sends with a
  `Content-Length` but no body and fails locally with `Content length mismatch`; the retry
  condition then evaluates false and APIM returns an error. The retry never reaches Foundry.
- **How found:** Azure Monitor showed ~1.00 Foundry call per request in every "retry" arm, and
  k6 failure count equalled the Foundry 429 count exactly. A policy trace (`Ocp-Apim-Trace`)
  then showed the mismatch message.
- **Fix:** `<forward-request buffer-request-body="true" />` inside the `<retry>` block.
  (The `set-body` + `preserveContent` workaround was rejected by ARM validation here.)
- **Detect in future:** compare Foundry-side calls per request to 1.0 on a run where 429s occur.
  If they match, retries are not happening. Check traces, not just success rate.
- **Affected results:** every "APIM retry" arm before the fix was effectively a no-retry arm.
  Success in the CB arms came from the breaker removing the primary, not from retries.

### 2. A retry block without `<forward-request />` returns synthetic 200s
- APIM returns its own fast (~14 ms) 200 without calling the backend. Looks like great success.
- Guard: validate the response body (`choices[]`) and check p50 latency of successes is
  ~300-400 ms, not ~14 ms.

### 3. Policy changes take up to ~2 minutes to reach the gateway
- A traced request 25 s after `terraform apply` still ran the previous policy.
- Starting load straight after apply means the first part of a run can use the old config.
- **Fix:** settle ~120 s after apply before generating load (now in `run_experiments.sh`).

### 4. Circuit-breaker state is in memory and survives `terraform apply`
- State is per-gateway, trip duration `PT60S`. A "CB off" run straight after a "CB on" run can
  inherit tripped backends.
- Allow at least 60 s idle between runs; do not assume apply resets runtime state.

### 5. Turning the breaker off: `rules = []` is rejected, use `circuitBreaker = null`
- ARM returns `ValidationError` for an empty rules list. Destroying the `azapi_update_resource`
  also does not reset Azure state. Set the property to `null` explicitly.

### 6. `retry count=N` means N+1 attempts
- `count=3` is 1 initial + 3 retries = 4 attempts. A client making 3 attempts is not matched.
- Fixed-policy runs use `count=2` so both sides make 3 attempts.

### 7. Retry without a breaker re-enters the weighted pool
- Retries can pick the backend that just returned 429, in proportion to its weight (90% for
  UK South in 90/5/5). Retry alone does not route around a saturated primary.
- With a working retry, the 90/5/5 no-breaker arm still behaves like the matched weighted client
  (see RESULTS.md Phase 5).

### 8. Retry interval 0 is accepted and stored, but had no observable effect
- ARM and the stored policy show `interval="0"`. Runtime may floor it to 1 s; p95 latency did not
  change. Record what you configured *and* what you measured.

### 9. Priority pool vs weighted pool
- Priority 1 for the primary and 2 for fallbacks means fallbacks get traffic only after the
  primary is removed. Weights inside a priority tier still split traffic.
- Always read the applied pool back from ARM; do not trust that a variable applied.

### 10. A breaker on 429 trips *every* region when all are short
- With equal weights and all regions saturating, 429s trip each backend in turn and the pool
  empties, giving fast 503s. Original `circuit_breaker` run: 4.5% success.

---

## B. Quota and measurement

### 11. The request limit, not just TPM, is the ceiling (and it is low)
- Each deployment has `request: 60 per 60 s` alongside `token: 60,000 per 60 s`. That is roughly
  1 RPM per 1K TPM, not the 6 RPM per 1K TPM often quoted.
- Measured ceiling (~72 RPM per backend) sat ~20% above the configured 60; not fully explained.
- Read limits with `az cognitiveservices account deployment show ... --query properties.rateLimits`.

### 12. Burst tests mislead; the quota level changes the answer more than routing does
- Same config gave 18% at 10K TPM and 90-96% at 60K TPM. State the quota with every result and
  confirm with a run spanning several quota windows.

### 13. Closed-loop load inflates offered load for fast failures
- With fixed virtual users, a config that fails fast (CB 503s) sends many more requests per second
  than one that fails slowly, so configs do not face the same load.
- **Fix:** use constant-arrival-rate (CAR) for comparisons, and use goodput, not success rate,
  for sustained closed-loop runs.

### 14. Success rate and goodput can be artefacts
- Fast failures inflate goodput; unvalidated 200s inflate success. Original sustained "retry is
  catastrophic" and "CB-only is best" findings came from unvalidated synthetic 200s.
- Validate bodies; compare configs only at similar failure latencies.

### 15. Denominators: HTTP calls vs requests
- `direct_sequential` made up to 3 calls per iteration; `summarise.py` divided by HTTP calls and
  reported 5.8% where the real per-request rate was 16.5%.
- For APIM arms k6 sees one call per request; APIM's internal retries are invisible to k6, so
  "extra calls per success" cannot be compared from k6 alone.

### 16. A closed-loop "retry beats baseline" can be a different load, not a better config
- Check offered load per arm before reading differences.

---

## C. Azure Monitor / observability

### 17. Per-region call counts need an isolated window
- `ModelRequests` (split by `Region`, `StatusCode`) is the cleanest Foundry-side count, and
  matched k6's own counters within ~2 calls on an isolated direct run.
- But 1-minute buckets lag request time by up to ~1 minute, and tight windows lose tail traffic.
- Isolate runs with >= 3 minutes idle either side and use a generous window
  (`scripts/foundry_region_counts.py`).

### 18. Your own manual traffic contaminates the window
- A 150-call saturation burst fired just before a run added 62 phantom successes. Foundry
  showed 539 successes against k6's 476; subtracting the burst gave 477.
- Do not run ad-hoc tests near a run you intend to account for.

### 19. A "gap" in Foundry metrics may really be a corrupted run (laptop sleep)
- `p5r_apim_priority_r2` showed 63 Foundry calls while k6 saw 511 completions. We first blamed
  an Azure Monitor gap. It was a run that took 1,908 s instead of 300 s: the laptop slept
  mid-run, so k6 stalled and the run is invalid (see #33). Always check run duration first.

---

## D. Load generator and scripts

### 20. k6 `check()` on an undefined response throws
- If a client-side cooldown skips every region, no call is made and `finalRes` is undefined.
  `check(undefined, ...)` raised ~1,750 TypeErrors across runs. Counters were unaffected but the
  log was noisy. Guard with `if (finalRes)`.

### 21. Client memory is per-VU; APIM's breaker is global
- A per-VU 429 cooldown reacts faster to its own first failure than a global 3-failure breaker,
  so it can beat APIM here. A single shared client process would behave differently.
- Not a like-for-like match; document the difference rather than hide it.

### 22. Retry-exhaustion status differs by policy state
- Broken policy: failures surfaced as 5xx. Fixed policy: final failures return the last 429.
  k6 checks written for one will misreport the other.

### 23. Hidden output makes failures look like success
- `terraform apply | tail -5` shows only the outputs block, not "Apply complete". Success was
  inferred from outputs appearing, which only prints after a successful apply.
- Piping a script through `tee`, or wrapping a driver, can return exit 0 after a failure.
  Always verify result-file counts and grep the log for errors; do not trust the exit code.

### 24. Interleaving and gaps matter
- Run client and gateway arms interleaved, with >= 60 s between runs, and repeat each headline
  arm >= 5 times. Per-arm runs back-to-back confound with time of day and quota state.

---

## E. Azure access and environment

### 25. PIM activation propagates one permission at a time
- After activating PIM, `service/read` can work while `backends/read` and the subscription
  `listSecrets` action still return 403. A probe of one permission is not enough.
- **Gate on a real `terraform apply` succeeding** before starting a long run, and run long
  batches with an activation window longer than the batch.

### 26. PIM expiry mid-batch kills the run after it starts
- The runner stops on the first failure (`set -e`); completed results are kept. Make drivers
  stop on failure and skip finished runs when resuming.

### 27. The Azure CLI default subscription can change mid-run
- A read-back using `az account show` silently queried the wrong subscription and failed with
  `ResourceGroupNotFound` after a successful apply. Pin the subscription from `terraform.tfvars`
  (git-ignored) instead of the CLI default.

### 28. macOS `sed` differs from GNU `sed`
- `sed -i` with newlines in patterns fails; use `-E` and a Python/Edit step for multi-line edits.

### 33. Laptop sleep silently corrupts a run (and the run still produces numbers)
- A sleeping laptop stalls k6 mid-run. The run still finishes and writes a plausible-looking
  result: 66-70% success, dropped iterations, or a 99.5% where ~79% is expected.
- 8 of 34 fixed-policy Scenario A runs were hit (durations of 480 s to 3,989 s against 300 s).
- **Validity rule:** discard any run whose `testRunDurationMs` exceeds ~330 s or that has
  `dropped_iterations > 0`. Apply it before looking at success rates. Keep the machine awake
  (`caffeinate -i`) for long batches.

### 34. The Azure CLI token fetch can hang forever
- `az` calls use `read timeout=None`. After a network drop or sleep, `terraform apply` sat for
  ~15 hours with no output, and a plain retry cannot help because the hung attempt never returns.
- Wrap apply and read-back in a watchdog that kills attempts after a fixed time
  (`retry3` in `scripts/run_experiments.sh`: 15 min, 3 attempts). The first interrupt to
  terraform is graceful, so a second is needed to force exit.

### 35. macOS has no `timeout` command
- A guard written as `timeout 120 terraform ...` fails with command-not-found, and piping
  through `grep` hides the error. Use a background process and `kill`, as in `retry3`.

### 36. A manual test run adjacent to an accounted run contaminates it
- See #18; the same applies to your own debugging traffic.

### 37. A background watchdog can hold a pipe open and stall the caller
- `retry3 terraform apply ... | tail -5`: the watchdog subshell inherited stdout, and killing it
  left its `sleep 900` child holding the pipe, so `tail` waited ~15 minutes after every apply.
  Looked like a hang or a sleeping laptop; it was neither.
- Redirect the watchdog's stdout to `/dev/null`. Test any wrapper by piping it through `tail`,
  not just by calling it directly.

### 38. A newly created APIM instance can break the Terraform provider's read (405)
- Rebuilding on 2026-11-09, `azurerm_api_management` was created (30 min) but every refresh then
  failed with `405 MethodNotAllowed: Direct management API is disabled for this service`
  ("retrieving tenant access properties"). The provider treats that as fatal, so the resource was
  marked tainted and every later plan/apply failed at the same read (and a retry loop just repeats
  it six times). Left alone, a taint means a 30-minute destroy and recreate that fails again.
- **Workaround used:** `terraform untaint azurerm_api_management.apim`, then apply with
  `-refresh=false` (also for destroy). This avoids enabling the direct management API, which would
  widen the service's management surface.
- Do not blind-retry a failing apply more than once or twice; read the first error.

### 39. Azure Monitor buckets are stamped with their END time; a neighbouring run's tail leaks in
- A pin check on `rlC_uksouth_r2` "failed" (38-39 calls to unpinned regions) because its counting
  window began two minutes before the run and caught the tail of the direct run that ended 2.5
  minutes earlier. Inside the run's own minutes the unpinned regions had exactly zero calls and
  UK South had exactly the 321 requests sent.
- A bucket stamped 12:41 covers real time 12:40-12:41, so a run that ended at 12:40:17 still
  appears in buckets up to 12:41. Start the window at the run's own start (`PAD_BEFORE_S=0`) and
  keep >= 3 minutes idle before a run you intend to account for.
- Before trusting a failed check, print the per-minute series; it distinguishes a leak from
  contamination at a glance.

### 40. Too few pre-allocated VUs can drop an iteration in a constant-arrival-rate run (suspected)
- 2 of 4 interleaved runs (one request every 0.67 s, 2 pre-allocated VUs) each dropped exactly one
  iteration and were discarded under the validity rule; the single-region runs (one request every
  2 s) never did. Suspected cause: a slow response needs a third VU, which k6 must initialise
  mid-run. Not tested. Pre-allocate enough VUs for the worst plausible in-flight count, and expect
  to re-run a fraction of runs.

---

## F. Interpretation traps

### 29. "Retry makes it worse" can be an artefact
- Before the body fix, retry arms looked slightly worse than no-retry. Retry was a no-op that
  only added a 1 s wait.

### 30. Weight distribution mattered only for no-retry configs
- Claims that weights are the primary variable were retracted. With a breaker present the
  breaker state dominates.

### 31. The Developer tier is not production
- Single-unit gateway; latency tails and scaling behaviour will differ on Standard/Premium.
  Treat p95 differences between batches cautiously and compare within a batch only.

### 32. A matching gateway does not settle the non-performance case
- Credentials (managed identity vs per-region keys), central policy, and monitoring are
  untouched by any of this.

---

## Status of earlier conclusions

Findings that relied on APIM retry working (Phase 2b, Phase 3, parts of Phase 4, and the first
Phase 5 batch) were measured with a retry policy that did nothing (#1) and are marked superseded
in RESULTS.md. The corrected comparison is the fixed-policy `p6*` runs in the Phase 5 section.
Headline: with retry working, APIM matches a well-built client on success and does not beat it
on latency; failure memory (a breaker or a cooldown), not retry, is what recovers a saturated
primary.
