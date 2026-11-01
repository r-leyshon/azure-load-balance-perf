# Production Deployment and Operations Guide

This guide translates the sandbox experiment findings into a production-ready APIM + Azure AI
Foundry deployment. It covers recommended configuration values, infrastructure changes, monitoring
strategy, alert rules, and a tuning reference for ongoing operations.

The sandbox used 10 000 TPM quotas and a Developer_1 APIM tier. Neither is representative of
production — but the failure modes are. **One important scope caveat:** every sandbox experiment
forced *global* saturation — all three regions simultaneously exhausted. A real PTU + PAYG
deployment, where the primary region has high provisioned throughput and the PAYG fallbacks have
fresh quota, is a materially different regime. Where sandbox findings diverge from the expected
production scenario, this is noted explicitly below.

---

## 1. Recommended configuration

### Backend pool weights

**Recommended: 90 / 5 / 5 (PTU / PAYG-1 / PAYG-2)**

| Region | Role | Weight |
|---|---|---|
| UK South | PTU (primary) | 90 |
| West Europe | PAYG (first fallback) | 5 |
| Sweden Central | PAYG (second fallback) | 5 |

**Rationale:** PTU has predictable, high capacity and a fixed monthly cost — send it as much
traffic as possible. PAYG fallbacks exist for PTU overflow, so their weights should be low enough
that they are rarely used but high enough to absorb a full PTU failover. 5/5 achieves this.

**What to avoid:** 80/10/10. The sandbox showed this creates a p95 latency spike because the
10% fallback allocation is large enough to over-commit under load but small enough to exhaust
simultaneously. Stay either side of 80: use 90/5/5 or 70/15/15.

### Circuit breaker

| Parameter | Value | Rationale |
|---|---|---|
| `statusCodeRanges` | 500–599 only | Sandbox finding: CB on 5xx only is the fastest configuration tested. APIM retry handles quota redistribution; the CB should protect against hard backend failures only. Treating 429 as a CB signal adds no benefit and risks draining the pool. |
| `count` (trip threshold) | 3 | Trip threshold 1 vs 3 made no meaningful difference in sustained runs. 3 is more resilient to transient single failures. |
| `interval` (evaluation window) | PT60S | Matches Azure OpenAI's quota replenishment window. |
| `tripDuration` | PT60S | Matches Azure OpenAI's quota replenishment window. Set in `apim_backends.tf`. The sandbox data suggests the full 60s is appropriate: a backend that tripped on quota exhaustion needs the full window to reset before it can serve requests again. |
| `acceptRetryAfter` | true | Lets APIM honour the backend's own retry guidance when available. |

### APIM server-side retry

| Parameter | Value | Rationale |
|---|---|---|
| `count` | 3 | With 90/5/5 weights and a PTU primary that saturates while PAYG fallbacks have headroom, retries will almost always find fresh capacity on the first or second retry. |
| `interval` | 1s | Short enough to be transparent to callers; long enough for APIM to re-evaluate the pool after a CB trip. Increase if retry storms surface in logs. |
| `condition` | `context.Response.StatusCode == 429` | Only retry on quota exhaustion, not on all failures. 5xx from the backend should trip the CB, not trigger a retry loop. |

> **Sandbox caveat:** under *global* saturation (all backends simultaneously exhausted), APIM
> retry is harmful at sustained load: each incoming request generates up to 3 retries that
> re-exhaust quota the moment a window resets, giving 0.3% sustained success vs 2.4% with no
> retry. In the PTU+PAYG production scenario this setting is designed for — where the PTU
> saturates but PAYG fallbacks have capacity — retries route to the open fallbacks and succeed.
> If you observe PAYG fallbacks also saturating under normal load, reduce retry count to 1 or 0
> and rely on client-side `Retry-After` instead.

### Gateway RPM limit

**Do not set a gateway-level RPM cap in production unless you have a specific cost or fair-use
reason to do so.** The sandbox `gateway_throttle` and `full_resilience` runs showed that a cap
set below the PTU's natural capacity is immediately fatal. Let the backends' quota enforce the
ceiling; the gateway's job is routing and resilience, not rate limiting callers.

If you must cap (e.g. per-subscription fair use), set it to at least 120% of your expected peak
call rate per subscription, measured over a 60-second window.

### Client-side retry guidance (for callers of this gateway)

Advise callers to implement `Retry-After` header respect only. All other retry strategies
(immediate, fixed delay, exponential backoff) are counterproductive under quota saturation —
they consume quota faster than it replenishes. If a caller is getting 429 from APIM it means the
entire pool is saturated; any retry shorter than the `Retry-After` value will fail.

For interactive workloads, a single attempt with fast failure is preferable to a retry that
blocks the caller thread for 30+ seconds. Surface the 429 to the caller and let them decide.

---

## 2. Infrastructure changes for production

### APIM tier

| Attribute | Sandbox | Production |
|---|---|---|
| SKU | Developer_1 | **Premium** |
| SLA | None | 99.95% (single region), 99.99% (multi-region) |
| Zone redundancy | No | Yes — minimum 3 capacity units across 3 zones |
| Private endpoints | No | Yes — APIM in internal VNet, backends via private link |
| Capacity units | 1 | Start at 3 (one per AZ); scale by throughput metrics |
| Custom domain | No | Yes — corporate domain with managed certificate |

**Why Premium and not Standard_v2?** Standard_v2 is zone-redundant by default and simpler to
operate, but as of writing does not support the `azapi` backend pool type used for the weighted
pool and circuit breaker. Check Azure documentation before choosing — if Standard_v2 gains
support, prefer it (lower cost, simpler scaling).

### Terraform changes required

```hcl
# SKU change
resource "azurerm_api_management" "apim" {
  sku_name = "Premium_3"          # was "Developer_1"

  zones = ["1", "2", "3"]         # add zone pinning

  virtual_network_type = "Internal"          # add VNet integration
  virtual_network_configuration {
    subnet_id = azurerm_subnet.apim.id
  }
}

# Add custom hostname
resource "azurerm_api_management_custom_domain" "apim" { ... }

# Remove public IP from Foundry backends; add private endpoint resources
resource "azurerm_private_endpoint" "foundry" { ... }
```

### Secret management

Move away from `terraform.tfvars` for sensitive values:

| Value | Sandbox approach | Production approach |
|---|---|---|
| `subscription_id` | tfvars | Azure Workload Identity / OIDC in CI |
| `publisher_email` | tfvars | Azure Key Vault, read at plan time via `data.azurerm_key_vault_secret` |
| APIM subscription key | terraform output → .env | Key Vault, delivered to callers via internal API or RBAC-scoped Key Vault reference |

Managed identity auth to Foundry is already correct — no change needed there.

---

## 3. Monitoring

### Signal sources

| Source | What it gives you |
|---|---|
| **APIM diagnostic logs** → Log Analytics | Per-request logs: method, URL, backend, status code, duration, client IP |
| **App Insights (linked to APIM)** | Request traces, dependency calls, live metrics, failure analysis |
| **Azure Monitor — APIM metrics** | Capacity, requests, backend duration, gateway errors — aggregated, 1-min granularity |
| **Azure Monitor — Cognitive Services** | `TokenTransaction` (prompt + completion tokens consumed per minute per deployment) |
| **Custom metric: `foundry-request`** | Already wired via `emit-metric` in `apim_policy.xml.tpl`. Dimensions: `run_id`, `status_code`. In production, swap `run_id` for a meaningful caller identifier (e.g. product name, team). |

### KQL queries for Log Analytics

**Error rate by backend (last 1 hour):**
```kql
AzureDiagnostics
| where ResourceType == "SERVICE" and Category == "GatewayLogs"
| where TimeGenerated > ago(1h)
| extend BackendId = tostring(parsejson(backendId_s))
| summarize
    total   = count(),
    errors  = countif(responseCode_d >= 500),
    quota   = countif(responseCode_d == 429)
  by BackendId, bin(TimeGenerated, 1m)
| extend error_rate = errors / total
```

**Circuit breaker trip events (inferred from backend 5xx spike):**
```kql
AzureDiagnostics
| where Category == "GatewayLogs" and responseCode_d >= 500
| summarize count() by backendId_s, bin(TimeGenerated, 1m)
| where count_ > 3
```

**Token consumption approaching quota (per region):**
```kql
AzureMetrics
| where ResourceType == "MICROSOFT.COGNITIVESERVICES/ACCOUNTS"
| where MetricName == "TokenTransaction"
| summarize avg(Total) by Resource, bin(TimeGenerated, 1m)
```

### Healthy vs degraded state

| Indicator | Healthy | Investigate | Degraded |
|---|---|---|---|
| APIM 5xx rate | < 0.1% | 0.1–1% | > 1% |
| APIM 429 rate (to callers) | < 5% | 5–20% | > 20% |
| Backend p95 duration | < 5 000ms | 5–10s | > 10s |
| PTU token utilisation | < 80% | 80–95% | > 95% |
| APIM Capacity unit utilisation | < 70% | 70–85% | > 85% |
| PAYG backend call share | < 15% | 15–40% | > 40% (PTU may be degraded) |

PAYG backend call share is the most operationally meaningful single number: if WE and SC are
handling significantly more than their 10% weight allocation, the PTU is saturated or degraded
and cost is accumulating on PAYG.

---

## 4. Alert rules

All alerts should target the APIM instance and its linked App Insights workspace. Severity
follows Azure Monitor convention (Sev0 = critical, Sev4 = informational).

| Alert | Metric / query | Threshold | Window | Severity | Action |
|---|---|---|---|---|---|
| **Zero successful requests** | APIM `SuccessfulRequests` | = 0 | 2 min | Sev1 | Page on-call immediately |
| **High gateway error rate** | APIM `FailedRequests` / `TotalRequests` | > 5% | 5 min | Sev2 | Investigate CB state, Foundry status |
| **Sustained quota pressure** | APIM 429-to-caller rate | > 20% | 10 min | Sev2 | PTU may be undersized; review token metrics |
| **PTU near quota ceiling** | Cognitive Services `TokenTransaction` | > 90% of PTU TPM | 5 min | Sev3 | Consider increasing PTU, or adjusting weights to shift earlier to PAYG |
| **PAYG backend overloaded** | PAYG backend call share | > 40% for 5 min | 5 min | Sev3 | PTU likely degraded; check Azure service health |
| **APIM backend latency spike** | APIM `BackendDuration` p95 | > 8 000ms | 5 min | Sev3 | Backend slowness; check Foundry service health |
| **APIM capacity headroom** | APIM `Capacity` | > 80% | 10 min | Sev3 | Add capacity units before traffic peaks |
| **CB trip storm (inferred)** | Backend 5xx count per backend | > 10 in 1 min | 1 min | Sev2 | Foundry backend may be down; check Azure status |

For Sev1 and Sev2: create an action group with email + PagerDuty/Opsgenie integration.
For Sev3: email notification to the owning team during business hours.

---

## 5. Tuning levers

Use this reference when a specific signal indicates the configuration needs adjustment. All
changes should go through Terraform — avoid manual portal edits.

---

### Backend weights

**What it does:** Controls the proportion of traffic directed to each Foundry backend under
normal (no-CB-trip) conditions.

| Signal | Action | Watch out for |
|---|---|---|
| PAYG backends consistently handling > 20% of traffic | Increase PTU weight (e.g. 90→95) or investigate PTU health | Weight above 95 leaves almost no fallback headroom |
| PTU returning 429s faster than expected | Reduce PTU weight to shift earlier to PAYG | PAYG costs increase; monitor token spend |
| PTU incidents (regional outage) | Emergency: set PTU weight to 0 via Terraform; PAYG handles 100% | PAYG capacity limits; watch Azure quota consumption |

**No dangerous midpoint was confirmed.** Early analysis flagged 80/10/10 as harmful, but this
was a measurement artefact (CB state bleed between experiments). After proper isolation, 80/10/10
achieves the same ~16–18% burst success as 70/15/15 and 90/5/5. Weight distribution within the
asymmetric range does not strongly predict burst success under global saturation. Use 90/5/5 as
the production starting point to maximise PTU utilisation and minimise PAYG cost.

---

### CB trip count

**What it does:** Number of failures within the evaluation window before a backend is removed
from the pool.

| Signal | Action | Watch out for |
|---|---|---|
| Frequent single-failure CB trips causing unnecessary pool disruption | Increase to 5 | Higher count means more requests hit a bad backend before it trips |
| Slow CB detection allowing degraded backend to serve too many requests | Decrease to 1 | At count=1, any transient single 5xx trips the CB; noisy in degraded-but-not-failed scenarios |

**Recommended starting value: 3.** The sandbox showed count=1 vs count=3 produced no meaningful
difference in sustained success rate. Reserve count=1 for backends where hard failures are
clearly distinguishable from transient errors (i.e. you have confidence in the signal quality).

---

### CB trip duration (`tripDuration`)

**What it does:** How long a tripped backend stays out of the pool before being re-admitted.

| Signal | Action | Watch out for |
|---|---|---|
| Backends re-entering the pool before they have recovered, causing immediate re-trip | Increase (e.g. PT30S → PT60S → PT120S) | Longer trip duration = more traffic on remaining backends during recovery |
| Backends staying out of the pool long after they have recovered, wasting capacity | Decrease (e.g. PT60S → PT30S) | Too short and you reintroduce a flapping pattern |

**Recommended starting value: PT60S** (the value set in `apim_backends.tf`). This matches
Azure OpenAI's quota replenishment window. With CB-on-5xx-only, this governs hard failure
recovery time rather than quota cycling. Azure service incidents typically resolve within
minutes; PT60S ensures a fully recovered backend before re-admission.

---

### APIM retry count

**What it does:** Number of times APIM will retry a failed request against the backend pool
before surfacing a 429 or 5xx to the caller.

| Signal | Action | Watch out for |
|---|---|---|
| Callers seeing 429s that should have been retried to a live backend | Increase to 4 or 5 | Each extra retry adds latency to the failed-path response time |
| Retry storms visible in backend logs — backends receiving repeated calls from single APIM requests | Decrease to 2 | Too few retries means genuine quota bursts reach callers |

**Recommended: 3.** With a 90/5/5 pool, 3 retries is almost always enough to reach a PAYG
backend. More than 5 retries begins to meaningfully extend p99 latency for requests that
ultimately fail.

---

### APIM retry interval

**What it does:** Seconds between retry attempts.

| Signal | Action | Watch out for |
|---|---|---|
| Retries hitting the same backend in rapid succession, all returning 429 | Increase to 2s | Increases latency on the retry path |
| Backend recovery is fast (e.g. CB reset cycle is working well) and 1s feels like wasted time | Decrease to 0s (first-fast-retry) | May cause retry storms against a borderline backend |

**Recommended: 1s.** This is the point where a re-evaluation of the pool state is meaningful.
Sub-second retries are unlikely to find a different result; 2s+ starts to noticeably affect p95.

---

### Gateway RPM limit

**What it does:** Caps the call rate at the APIM gateway level, before any backend is reached.
Returns 429 to the caller immediately.

| Signal | Action | Watch out for |
|---|---|---|
| Runaway callers consuming disproportionate PAYG quota | Enable a per-subscription cap at 80% of expected peak | This rate-limits all callers equally; consider per-key limits instead |
| Cost spike from unexpected PAYG consumption | Enable a global cap as an emergency brake | Setting this too low will throttle legitimate traffic |

**Default recommendation: disabled.** Let the backends' native quota enforce the ceiling.
Enable only if you have a specific cost-control or fair-use requirement.

---

### Number of fallback regions

**What it does:** Adding a third or fourth PAYG fallback region increases the pool available
for APIM retries to route to.

| Signal | Action | Watch out for |
|---|---|---|
| Two PAYG backends are both saturating simultaneously during PTU failover | Add a third PAYG region (e.g. France Central) | APIM pool definition and CB rules need updating; RBAC assignment required on new Foundry resource |
| PAYG backend in one region experiencing persistent Azure capacity issues | Swap for a different region | Model availability varies by region — verify the target region has your model |

**Recommended: 2 PAYG fallbacks (current topology).** Adding a third adds cost complexity
without clear benefit unless you have evidence of PAYG capacity pressure in both WE and SC
simultaneously.

---

### PTU quota size

**What it does:** The number of provisioned throughput units determines the TPM ceiling of the
primary backend.

| Signal | Action | Watch out for |
|---|---|---|
| PTU token utilisation consistently above 80% | Scale PTU up (contact Microsoft for PTU reservation increase) | PTU is billed monthly whether used or not; don't over-provision |
| PTU token utilisation below 40% for sustained periods | Scale PTU down at next renewal | Under 40% utilisation on a reserved capacity indicates over-procurement |
| PAYG backends handling > 15% of normal (non-incident) traffic | PTU is undersized for current load | PAYG costs accumulate quickly at scale |

**Sizing approach for initial deployment:** measure your 95th-percentile token consumption over
a representative 2-week period, then provision PTU at 120% of that P95. This leaves headroom
for growth while keeping PAYG spill-over below 5% of normal traffic.

---

## 6. Rollout sequence

Follow this order. Each step should be verified before proceeding to the next. Do not short-cut
steps 1–5 — they are the safety net for step 6.

| Step | Action | Verification |
|---|---|---|
| **1. Networking** | Deploy VNet, subnets, private endpoints for Foundry backends, NSGs | `az network private-endpoint show` returns Succeeded for all three Foundry resources |
| **2. Foundry backends** | Deploy Cognitive Accounts and model deployments in all three regions | `az cognitiveservices account list` shows all three in Succeeded state |
| **3. RBAC** | Assign `Cognitive Services OpenAI User` to the APIM system-assigned identity on each Foundry resource | `az role assignment list` confirms assignment; test identity token fetch |
| **4. APIM (no traffic)** | Deploy APIM Premium with zone redundancy, internal VNet, no public exposure | APIM Developer Portal accessible from VNet; `az apim show` returns Online |
| **5. Monitoring first** | Deploy Log Analytics workspace, App Insights, diagnostic settings, alert rules | Send a single test request through APIM and confirm it appears in App Insights within 5 minutes |
| **6. Smoke test** | Allow a single internal caller; send 50 requests across 2 minutes | Check: < 1% 5xx, p95 < 2 000ms, all three backends appear in diagnostic logs |
| **7. Canary (5% traffic)** | Route 5% of production traffic to new APIM gateway; old path remains active | Monitor for 30 minutes: error rate, latency, PAYG call share |
| **8. Ramp (25% → 50% → 100%)** | Increase traffic share in increments with 30-minute hold at each step | At each step: PAYG call share < 15%, no Sev1/Sev2 alerts firing, p95 stable |
| **9. Decommission old path** | Remove old routing rule; old infrastructure can be retained for 48 hours as rollback option | Confirm all traffic in APIM diagnostic logs; zero requests on old path |

**Rollback trigger:** at any step from 6 onwards, if PAYG call share exceeds 40% for more than
5 minutes, or if the Sev1 "zero successful requests" alert fires, roll back to the previous step
immediately and investigate before re-attempting.

---

## Configuration summary (production starting point)

```hcl
# terraform.tfvars (non-sensitive values only; load sensitive values from Key Vault)
backend_weight_uksouth       = 90
backend_weight_westeurope    = 5
backend_weight_swedencentral = 5

circuit_breaker_failure_count = 3
circuit_breaker_on_429        = false   # 5xx only — key finding from sandbox
# tripDuration set in apim_backends.tf to "PT60S"

apim_retry_count      = 3
apim_retry_interval_s = 1

gateway_rpm_limit = 10000000   # effectively disabled; adjust only for explicit cost control
```

These are starting values. Tune from the first signals in production monitoring — specifically
PAYG call share and PTU token utilisation — which will give you a much more accurate picture
than any sandbox experiment can.
