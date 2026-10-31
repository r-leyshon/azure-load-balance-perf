# Azure API Management + AI Foundry Load Balancing

A sandbox experiment that uses Azure API Management (APIM) as an AI gateway in front of three
Azure AI Foundry deployments, then runs structured load tests to characterise how weighted load
balancing, circuit breakers, and retry strategies behave under deliberate quota saturation.

The goal is to find the optimal configuration for maximising both **success rate** and **goodput**
(successful completions per second) when LLM quota is the bottleneck — and to carry the findings
into a production multi-region Foundry design.

Full results and analysis: [`experiment/RESULTS.md`](experiment/RESULTS.md)

---

## Architecture

```
k6 (local machine)
      │  HTTPS + subscription key
      ▼
┌─────────────────────────────────────────────────────┐
│           Azure API Management                      │
│                                                     │
│  Inbound policies                                   │
│  ├─ managed-identity auth (keyless to Foundry)      │
│  ├─ rate-limit-by-key                               │
│  └─ set-backend-service → foundry-pool              │
│                                                     │
│  Backend: weighted pool                             │
│  ├─ foundry-uksouth    (weight: configurable)       │
│  ├─ foundry-westeurope (weight: configurable)       │
│  └─ foundry-swedencentral (weight: configurable)    │
│                                                     │
│  Per-backend circuit breakers (azapi)               │
│  └─ trip on N × {429 | 5xx} within 60s window       │
│                                                     │
│  Backend retry policy (optional)                    │
│  └─ retry on 429 up to N times against pool         │
└─────────────────────────────────────────────────────┘
      │   │   │  managed identity (no API keys)
      ▼   ▼   ▼
 Foundry Foundry Foundry
 UK South  WEu  Sweden
```

All three Foundry backends use the same `gpt-4.1-mini` deployment with intentionally small
per-region quotas (10 000 TPM), making quota exhaustion the dominant failure mode within seconds
of a burst. This surfaces circuit breaker and retry behaviour that would otherwise require
production-scale traffic to observe.

---

## Key findings

| Config | Success rate | Goodput (req/s) |
|---|---|---|
| No resilience features (baseline) | 17.5% | 6.8 |
| Circuit breaker only (equal weights) | 4.5% | 3.7 |
| Asymmetric weights + CB | 16.5% | 8.5 |
| APIM retry, no CB | 16.5% | 11.2 |
| **APIM retry + CB (equal weights)** | **100%** | **153** |
| **APIM retry + CB (90/5/5 weights)** | **100%** | **160** |
| Client retry (`Retry-After` header) | 99.5% | 0.4 |
| Sustained 5-min run (winning config) | 98.9% | 164 |

**APIM server-side retry combined with per-backend circuit breakers is the decisive combination.**
Circuit breakers remove saturated backends from the pool; APIM retries then find a backend with
remaining quota. The entire recovery is invisible to the caller at ~14ms p50 latency.

Client-side retry strategies are largely counterproductive under global quota saturation — the
only effective variant is sleeping for the exact `Retry-After` duration returned by Azure, which
achieves ~100% success but at ~30 second median latency, making it suitable only for batch
workloads.

See [`experiment/RESULTS.md`](experiment/RESULTS.md) for the full table, per-phase findings, and
discussion of each experiment.

---

## Repository layout

```
.
├── infra/                        # Terraform IaC
│   ├── main.tf                   # Provider config, random suffix
│   ├── apim.tf                   # APIM instance, managed identity, RBAC
│   ├── apim_api.tf               # API definition, policy binding, subscription
│   ├── apim_backends.tf          # Per-backend resources, circuit breakers, pool
│   ├── apim_policy.xml.tpl       # Inbound + backend retry policy template
│   ├── foundry.tf                # Cognitive accounts, model deployments
│   ├── outputs.tf                # Sensitive outputs (gateway URL, sub key)
│   ├── variables.tf              # All experiment-run variables
│   └── terraform.tfvars.example  # Template — copy to terraform.tfvars and fill in
│
├── experiment/
│   ├── load_test.js              # k6 script — APIM load test with retry strategies
│   ├── direct_test.js            # k6 script — direct-to-Foundry comparison
│   ├── config.yaml               # Canonical experiment definitions (all phases)
│   ├── summarise.py              # Parse k6 JSON results → Markdown table
│   ├── PLAN.md                   # Experiment design rationale
│   └── RESULTS.md                # Full results and analysis
│
├── scripts/
│   ├── run_experiments.sh        # Orchestrate terraform apply + k6 per experiment
│   └── export_env.sh             # Write terraform outputs → infra/.env
│
└── .github/workflows/
    ├── scheduled-destroy.yml     # Auto-destroy resources after 7 days
    └── oidc-setup.md             # OIDC federated credential setup guide
```

---

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) ≥ 1.9
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) — authenticated
  (`az login`) with Contributor + RBAC Administrator on the target subscription
- [k6](https://k6.io/docs/get-started/installation/) installed locally
- [Python](https://www.python.org/) 3.11+ (for `summarise.py`)
- [GitHub CLI](https://cli.github.com/) (optional — for creating the auto-destroy workflow)

> **PIM note:** if your subscription uses Privileged Identity Management, activate your role
> before running `terraform apply`. The activation window needs to cover the full experiment
> run; plan for at least 60 minutes.

---

## Reproducing the experiments

### 1. Configure Terraform variables

```bash
cp infra/terraform.tfvars.example infra/terraform.tfvars
# Edit infra/terraform.tfvars — fill in subscription_id, publisher_name, publisher_email
```

### 2. Deploy infrastructure

```bash
cd infra
terraform init
terraform apply
```

### 3. Export runtime environment

```bash
bash scripts/export_env.sh
# Writes gateway URL, subscription key, deployment ID, Foundry endpoints → infra/.env
# infra/.env is git-ignored; never committed
```

### 4. Run experiments

```bash
# Run a specific experiment
bash scripts/run_experiments.sh baseline

# Run a full phase
bash scripts/run_experiments.sh \
  retry_immediate retry_fixed_1s retry_backoff retry_backoff_jitter retry_after_header

# Run the winning config sustained test
bash scripts/run_experiments.sh sustained_apim_asym
```

Results are written to `experiment/results/<run_id>.json` (git-ignored).

### 5. Summarise results

```bash
python3 experiment/summarise.py
```

### 6. Destroy infrastructure

```bash
cd infra && terraform destroy
```

---

## Experiment phases

| Phase | What varies | Purpose |
|---|---|---|
| Phase 1 — Baseline | Weights, CB threshold, RPM limit | Characterise APIM behaviour without retry |
| Phase 2a — Client retry | Retry strategy (none / immediate / fixed / backoff / Retry-After) | Test client-side recovery under quota saturation |
| Phase 2b — APIM retry | Server-side retry count + CB | Test transparent gateway-level recovery |
| Phase 3 — Optimal | Combinations of Phase 1 + 2 winners | Find the ceiling |
| Sustained | 5-minute duration run of winner | Verify CB trip-reset cycle holds at steady state |

All configurations are defined in [`experiment/config.yaml`](experiment/config.yaml) and
[`scripts/run_experiments.sh`](scripts/run_experiments.sh).

---

## Security notes

- **No API keys in source.** APIM authenticates to Foundry via system-assigned managed identity
  (`Cognitive Services OpenAI User` RBAC). No Foundry API keys are used in the APIM path.
- **No secrets committed.** `terraform.tfvars` (subscription ID, publisher email) and `infra/.env`
  (gateway URL, subscription key) are git-ignored.
- **Sensitive Terraform outputs** are marked `sensitive = true` and written only to `infra/.env`
  by `scripts/export_env.sh`.
- k6 reads all secrets from environment variables — nothing is hardcoded in the test scripts.
