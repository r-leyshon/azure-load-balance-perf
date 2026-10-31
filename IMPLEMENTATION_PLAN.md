# Azure AI Foundry + APIM Load Balancing — Implementation Plan

## Overview

This experiment deploys three Azure AI Foundry projects across UK South, West Europe, and Sweden
Central — each with a deliberately minimal token quota — behind a single Azure API Management (APIM)
instance. APIM acts as the AI gateway, distributing load across the three Foundry endpoints using a
weighted backend pool and protecting each with a circuit breaker. A recursive load-testing loop (k6)
varies the configuration (weights, circuit-breaker thresholds, token limits, concurrency) and reports
success rate and throughput at each iteration.

All resources are tagged for **automatic destruction after 7 days** via a scheduled GitHub Actions
workflow, avoiding sandbox cost creep.

The goal is to publish the code openly, write an article on the findings, and carry the learnings
into a production multi-region Foundry fallback design for a more resilient service.

---

## Architecture

```
k6 (local machine)
        │  HTTPS + Ocp-Apim-Subscription-Key header
        ▼
┌──────────────────────────────────────┐
│  Azure API Management  (UK South)    │  ← Developer_1 SKU (sandbox)
│  - llm-token-limit policy            │
│  - llm-emit-token-metric             │
│  - Backend pool (weighted)           │
│  - Per-backend circuit breaker       │
└──────────────┬───────────────────────┘
               │ set-backend-service → foundry-pool
       ┌───────┼───────┐
       ▼       ▼       ▼
 [FA: UK South] [FB: West Europe] [FC: Sweden Central]
    10k TPM        10k TPM            10k TPM
    ← minimal quota — trivial to saturate under load →
```

Each Foundry backend is an Azure OpenAI (`azurerm_cognitive_account`, `kind = "OpenAI"`) account with
one model deployment (`gpt-4.1-mini`) at a quota of ~10 000 TPM. At ~500 tokens per request this
saturates under roughly 20 concurrent virtual users.

APIM uses its system-assigned managed identity to authenticate to each Foundry endpoint — no API keys
flow anywhere in the architecture.

---

## Authentication Model & Production Benefits

This section captures the authentication design for the article. It is one of the most practically
valuable things a reader can take away.

### How APIM authenticates with Azure Foundry in this experiment

Azure Foundry (Azure OpenAI) supports two authentication methods:

| Method | How it works | Suitable for |
|---|---|---|
| **API key** | Static key passed in `api-key` header. Stored in KeyVault or config. Requires manual rotation. | Quick prototyping, local development |
| **Managed identity** | APIM fetches a short-lived Bearer token from Entra ID at request time. No key to store or rotate. | Production, any automated workload |

**This experiment uses managed identity exclusively.** The Terraform config assigns APIM's
system-assigned identity the `Cognitive Services OpenAI User` RBAC role on each Foundry account.
The APIM policy then calls:

```xml
<authentication-managed-identity resource="https://cognitiveservices.azure.com" />
```

This fires before the request reaches the backend. APIM acquires a short-lived Bearer token from
Entra ID (cached for the token's lifetime, typically ~60 minutes), attaches it as an
`Authorization: Bearer <token>` header, and forwards the request. The Foundry endpoint validates
the token against the RBAC role — if the identity has `Cognitive Services OpenAI User`, the request
is accepted. No key is ever exchanged or stored.

> `local_auth_enabled = true` is set on the cognitive accounts in this sandbox so that API keys
> remain available for manual troubleshooting via the Azure portal or CLI. In a production
> deployment you would set `local_auth_enabled = false` to enforce managed identity as the only
> auth path, removing the possibility of a key being leaked or misused.

### What the calling application needs to know

Without APIM, any application consuming these three Foundry endpoints must manage:

- 3× Foundry endpoint URLs
- 3× API keys (or its own token-acquisition logic per endpoint)
- Circuit breaker and fallback logic in application code
- Key rotation schedules
- Updates to configuration whenever a backend changes

With APIM acting as the gateway, the consuming application needs exactly two things:

| Secret | Sensitivity | Managed by |
|---|---|---|
| APIM gateway URL | Not sensitive — public HTTPS endpoint | Hard-coded or config |
| APIM subscription key | Sensitive — single key | KeyVault, 1 entry |

All knowledge of the backends — their endpoints, their auth, how to fail over between them — lives
inside APIM. The application is completely decoupled from the backend topology. Adding a fourth
region, rotating Foundry keys, or swapping the model requires zero changes to the application.

### Extension to other Azure AI services

APIM is not specific to Foundry or language models. The same backend pool and managed identity
pattern applies to any Azure Cognitive Service that exposes an HTTP endpoint:

| Service | RBAC role for managed identity | APIM tier required |
|---|---|---|
| Azure OpenAI / Foundry | `Cognitive Services OpenAI User` | Any (Developer upwards) |
| Azure Speech-to-Text (REST / batch) | `Cognitive Services User` | Any |
| Azure Speech-to-Text (real-time WebSocket) | `Cognitive Services User` | Standard v2 or Premium |
| Azure AI Vision | `Cognitive Services User` | Any |
| Azure Document Intelligence | `Cognitive Services User` | Any |

This means a single APIM instance can act as the organisation's unified AI gateway — one place
to govern access, enforce quotas, observe usage, and manage resilience across every AI service,
with each consuming application holding only one subscription key.

---

## Tech Stack

| Layer | Tool |
|---|---|
| Infrastructure as Code | Terraform (`azurerm` provider ≥ 4.x) |
| AI gateway | Azure API Management — Developer_1 SKU, UK South |
| AI backends | Azure OpenAI via Foundry (UK South, West Europe, Sweden Central) |
| Auth (APIM → Foundry) | System-assigned managed identity + `Cognitive Services OpenAI User` RBAC |
| Observability | Application Insights + `llm-emit-token-metric` policy |
| Load testing | **k6** (Grafana k6) — JavaScript, runs locally, structured JSON output |
| Secrets / endpoints | `.env` (git-ignored); never in committed files |
| Auto-destroy | GitHub Actions scheduled workflow (OIDC auth, `terraform destroy`) |

**Why k6 over Gatling:** k6 scripts are plain JavaScript, install in one command (`brew install k6`),
produce structured JSON/CSV output that scripts can parse directly, and are far more readable in an
article than Gatling's Scala DSL. Gatling's JVM setup adds unnecessary complexity for an open tutorial.

---

## Repository Layout

```
azure-load-balance-perf/
├── IMPLEMENTATION_PLAN.md
├── .gitignore
├── infra/
│   ├── main.tf                    ← provider, resource group, random suffix
│   ├── variables.tf
│   ├── outputs.tf                 ← endpoint names only; actual values never committed
│   ├── foundry.tf                 ← 3× cognitive account + deployment (one per region)
│   ├── apim.tf                    ← APIM instance, managed identity, App Insights, logger
│   ├── apim_backends.tf           ← 3 individual backends + 1 pool backend
│   ├── apim_api.tf                ← API, product, subscription
│   ├── apim_policy.xml.tpl        ← policy template (rendered by templatefile())
│   └── monitoring.tf              ← Log Analytics workspace
├── experiment/
│   ├── load_test.js               ← k6 script; reads config from env vars
│   ├── summarise.py               ← parse k6 JSON output → comparison table
│   ├── config.yaml                ← experiment run definitions (no endpoints)
│   └── results/                   ← k6 JSON output per run (git-ignored)
├── .github/
│   └── workflows/
│       ├── scheduled-destroy.yml  ← daily check: destroy if destroy_after tag has passed
│       └── oidc-setup.md          ← instructions for configuring federated credentials
└── docs/
    └── article-outline.md
```

---

## Security & Endpoint Policy

- **No secrets in source.** Subscription ID, tenant ID, publisher email, and the APIM subscription
  key live in `infra/terraform.tfvars` — git-ignored.
- **No endpoints in source.** All resource URLs (Foundry endpoints, APIM gateway URL) are written
  to `infra/.env` by a post-apply script and consumed by k6 via environment variables. This file is
  git-ignored.
- **Managed identity only.** APIM authenticates to Foundry via its system-assigned identity —
  zero API keys in the request chain.
- **GitHub Actions OIDC.** The destroy workflow uses federated identity (no stored secrets in GitHub).
  Setup instructions live in `oidc-setup.md`.

### `.gitignore` targets

```
# Terraform state and secrets
*.tfvars
*.tfstate
*.tfstate.backup
.terraform/
.terraform.lock.hcl   # optional — commit this if you want reproducible provider versions

# Endpoints and runtime secrets
infra/.env
experiment/.env
experiment/results/
**/.env

# k6 output
*.k6.json
```

---

## Terraform Implementation

### 1. Provider, Resource Group & Tagging (`main.tf`)

The resource group is tagged with `destroy_after` set 7 days from the initial apply. The GitHub
Actions workflow reads this tag daily and calls `terraform destroy` once the date has passed.

```hcl
terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = ">= 4.0" }
    random  = { source = "hashicorp/random",  version = ">= 3.0" }
    time    = { source = "hashicorp/time",    version = ">= 0.9" }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

resource "random_id" "suffix" {
  byte_length = 4
}

resource "time_static" "deploy_time" {}

locals {
  destroy_after = formatdate("YYYY-MM-DD", timeadd(time_static.deploy_time.rfc3339, "168h"))
}

resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.apim_location

  tags = {
    environment   = "sandbox"
    project       = "apim-foundry-perf"
    destroy_after = local.destroy_after
  }
}
```

### 2. Variables (`variables.tf`)

Sensitive values have no default — they must be supplied via `.tfvars`:

```hcl
variable "subscription_id"     { type = string; sensitive = true }
variable "resource_group_name" { type = string; default = "rg-apim-foundry-perf" }
variable "apim_location"       { type = string; default = "uksouth" }
variable "publisher_name"      { type = string }
variable "publisher_email"     { type = string; sensitive = true }
variable "model_name"          { type = string; default = "gpt-4.1-mini" }
variable "model_version"       { type = string; default = "2025-04-14" }
variable "quota_tpm"           { type = number; default = 10000 }

# Per-run variables (overridden between experiment iterations)
variable "gateway_tpm_limit"           { type = number; default = 30000 }
variable "circuit_breaker_failure_count" { type = number; default = 0 }
variable "backend_weight_uksouth"      { type = number; default = 33 }
variable "backend_weight_westeurope"   { type = number; default = 33 }
variable "backend_weight_swedencentral"{ type = number; default = 34 }
```

### 3. Foundry Projects (`foundry.tf`)

Each Foundry backend is a separate `azurerm_cognitive_account` in its own region, with a model
deployment at `var.quota_tpm`. A `for_each` over a region map keeps the code DRY.

```hcl
locals {
  foundry_regions = {
    uksouth       = var.apim_location
    westeurope    = "westeurope"
    swedencentral = "swedencentral"
  }
}

resource "azurerm_cognitive_account" "foundry" {
  for_each            = local.foundry_regions
  name                = "foundry-${each.key}-${random_id.suffix.hex}"
  location            = each.value
  resource_group_name = azurerm_resource_group.rg.name
  kind                = "OpenAI"
  sku_name            = "S0"

  tags = azurerm_resource_group.rg.tags
}

resource "azurerm_cognitive_deployment" "model" {
  for_each             = local.foundry_regions
  name                 = "chat"
  cognitive_account_id = azurerm_cognitive_account.foundry[each.key].id

  model {
    format  = "OpenAI"
    name    = var.model_name
    version = var.model_version
  }

  sku {
    name     = "Standard"
    capacity = var.quota_tpm / 1000  # capacity unit = 1 000 TPM
  }
}
```

> `quota_tpm = 10000` → `capacity = 10` → 10 000 TPM. At ~500 tokens/request, ~20 concurrent VUs
> will saturate a single backend within seconds.

### 4. APIM Instance (`apim.tf`)

**SKU: `Developer_1` (UK South)**

| Reason | Detail |
|---|---|
| Circuit breakers | Supported; Consumption tier is not |
| Backend pools | Supported at this tier |
| Managed identity | System-assigned; required for keyless Foundry auth |
| Cost | ~£0.07/hr vs ~£1.40/hr for Standard — appropriate for a sandbox |
| SLA | None — acceptable for experiments |
| Provision time | ~25–45 min first apply; policy-only re-applies are <2 min |

```hcl
resource "azurerm_api_management" "apim" {
  name                = "apim-foundry-${random_id.suffix.hex}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  publisher_name      = var.publisher_name
  publisher_email     = var.publisher_email
  sku_name            = "Developer_1"

  identity { type = "SystemAssigned" }

  tags = azurerm_resource_group.rg.tags
}

resource "azurerm_role_assignment" "apim_foundry" {
  for_each             = local.foundry_regions
  scope                = azurerm_cognitive_account.foundry[each.key].id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = azurerm_api_management.apim.identity[0].principal_id
}

resource "azurerm_log_analytics_workspace" "law" {
  name                = "law-apim-foundry-${random_id.suffix.hex}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = azurerm_resource_group.rg.tags
}

resource "azurerm_application_insights" "ai" {
  name                = "ai-apim-foundry-${random_id.suffix.hex}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  application_type    = "web"
  workspace_id        = azurerm_log_analytics_workspace.law.id
  tags                = azurerm_resource_group.rg.tags
}

resource "azurerm_api_management_logger" "ai_logger" {
  name                = "appinsights-logger"
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name

  application_insights {
    instrumentation_key = azurerm_application_insights.ai.instrumentation_key
  }
}
```

### 5. Backends & Pool (`apim_backends.tf`)

Individual backends reference Foundry endpoints via `azurerm_cognitive_account.foundry[*].endpoint`,
so no endpoint URL ever appears in committed code.

```hcl
locals {
  backend_weights = {
    uksouth       = var.backend_weight_uksouth
    westeurope    = var.backend_weight_westeurope
    swedencentral = var.backend_weight_swedencentral
  }
}

resource "azurerm_api_management_backend" "foundry" {
  for_each            = local.foundry_regions
  name                = "foundry-${each.key}"
  resource_group_name = azurerm_resource_group.rg.name
  api_management_name = azurerm_api_management.apim.name
  protocol            = "http"
  url = format(
    "%sopenai/deployments/chat",
    azurerm_cognitive_account.foundry[each.key].endpoint
  )

  credentials {
    authorization {
      scheme    = "Bearer"
      parameter = "{{managed-identity-token}}"
    }
  }
}

# Backend pool — uses azurerm_resource to target the ARM REST API directly,
# as the pool type is not yet a first-class attribute in azurerm_api_management_backend.
# Verify provider version before applying; replace with native resource if available.
resource "azurerm_resource" "foundry_pool" {
  name      = "foundry-pool"
  type      = "Microsoft.ApiManagement/service/backends@2023-09-01-preview"
  parent_id = azurerm_api_management.apim.id

  body = jsonencode({
    properties = {
      description = "Load-balanced pool of Foundry backends"
      type        = "Pool"
      pool = {
        services = [
          {
            id       = azurerm_api_management_backend.foundry["uksouth"].id
            priority = 1
            weight   = var.backend_weight_uksouth
          },
          {
            id       = azurerm_api_management_backend.foundry["westeurope"].id
            priority = 1
            weight   = var.backend_weight_westeurope
          },
          {
            id       = azurerm_api_management_backend.foundry["swedencentral"].id
            priority = 1
            weight   = var.backend_weight_swedencentral
          }
        ]
      }
    }
  })
}
```

Circuit breaker rules (trip on N × 429/5xx per minute) are applied to each individual backend via a
separate `azurerm_resource` block once per-run variables are in place. When `circuit_breaker_failure_count`
is 0, the rule block is omitted.

### 6. APIM API & Policy (`apim_api.tf` + `apim_policy.xml.tpl`)

The policy template is rendered by `templatefile()` so per-run values (TPM limit) flow in via
Terraform variables — no endpoint values appear.

```hcl
resource "azurerm_api_management_api" "foundry" {
  name                  = "foundry-chat"
  resource_group_name   = azurerm_resource_group.rg.name
  api_management_name   = azurerm_api_management.apim.name
  display_name          = "Foundry Chat Completions"
  path                  = "openai"
  protocols             = ["https"]
  revision              = "1"
  subscription_required = true

  import {
    content_format = "openapi-link"
    content_value  = "https://raw.githubusercontent.com/Azure/azure-rest-api-specs/main/specification/cognitiveservices/data-plane/AzureOpenAI/inference/stable/2024-02-01/inference.json"
  }
}

resource "azurerm_api_management_api_policy" "foundry" {
  api_name            = azurerm_api_management_api.foundry.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name

  xml_content = templatefile("${path.module}/apim_policy.xml.tpl", {
    gateway_tpm_limit = var.gateway_tpm_limit
  })
}
```

**`apim_policy.xml.tpl`**

```xml
<policies>
  <inbound>
    <base />
    <authentication-managed-identity resource="https://cognitiveservices.azure.com" />
    <llm-token-limit
      counter-key="@(context.Subscription.Id)"
      tokens-per-minute="${gateway_tpm_limit}"
      estimate-prompt-tokens="false"
      remaining-tokens-variable-name="remainingTokens"
      tokens-consumed-variable-name="tokensConsumed" />
    <set-backend-service backend-id="foundry-pool" />
  </inbound>

  <backend>
    <base />
  </backend>

  <outbound>
    <base />
    <set-header name="X-Tokens-Consumed" exists-action="override">
      <value>@(context.Variables.GetValueOrDefault<string>("tokensConsumed", "0"))</value>
    </set-header>
    <llm-emit-token-metric namespace="foundry-perf">
      <dimension name="run_id"
        value="@(context.Request.Headers.GetValueOrDefault("X-Run-Id", "unknown"))" />
      <dimension name="backend_id" value="@(context.Backend?.Id ?? "unknown")" />
    </llm-emit-token-metric>
  </outbound>

  <on-error>
    <base />
  </on-error>
</policies>
```

### 7. APIM Product & Subscription

```hcl
resource "azurerm_api_management_product" "perf" {
  product_id            = "foundry-perf"
  api_management_name   = azurerm_api_management.apim.name
  resource_group_name   = azurerm_resource_group.rg.name
  display_name          = "Foundry Perf Test"
  subscription_required = true
  approval_required     = false
  published             = true
}

resource "azurerm_api_management_product_api" "link" {
  api_name            = azurerm_api_management_api.foundry.name
  product_id          = azurerm_api_management_product.perf.product_id
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_api_management_subscription" "load_test" {
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  product_id          = azurerm_api_management_product.perf.id
  display_name        = "load-test-subscription"
  state               = "active"
}
```

### 8. Outputs (`outputs.tf`)

Actual endpoint values are sensitive outputs written to a local `.env` file by the deploy script —
never printed to the terminal in CI or committed.

```hcl
output "apim_gateway_url" {
  value     = azurerm_api_management.apim.gateway_url
  sensitive = true
}

output "apim_subscription_key" {
  value     = azurerm_api_management_subscription.load_test.primary_key
  sensitive = true
}

# Foundry endpoints and keys — used only by direct_test.js (no APIM in the path).
# Keys are available because local_auth_enabled = true on the cognitive accounts.
output "foundry_endpoint_uksouth" {
  value     = azurerm_cognitive_account.foundry["uksouth"].endpoint
  sensitive = true
}

output "foundry_endpoint_westeurope" {
  value     = azurerm_cognitive_account.foundry["westeurope"].endpoint
  sensitive = true
}

output "foundry_endpoint_swedencentral" {
  value     = azurerm_cognitive_account.foundry["swedencentral"].endpoint
  sensitive = true
}

output "foundry_key_uksouth" {
  value     = azurerm_cognitive_account.foundry["uksouth"].primary_access_key
  sensitive = true
}

output "foundry_key_westeurope" {
  value     = azurerm_cognitive_account.foundry["westeurope"].primary_access_key
  sensitive = true
}

output "foundry_key_swedencentral" {
  value     = azurerm_cognitive_account.foundry["swedencentral"].primary_access_key
  sensitive = true
}

output "destroy_after_date" {
  value = local.destroy_after
}
```

---

## Local Load Testing

### Why local works

APIM Developer_1 exposes a standard public HTTPS gateway (`https://<name>.azure-api.net`). k6
running on your laptop connects to this endpoint exactly as any API consumer would. Authentication
to the Foundry backends is handled entirely inside Azure (APIM → managed identity → Foundry) — the
caller only needs the APIM subscription key in a request header. There are no VNet restrictions,
private endpoints, or IP allowlists on the Developer tier by default.

### Network latency caveat

Your local machine adds ~10–30 ms round-trip to each Azure call. This inflates absolute latency
figures but does not affect **relative** comparisons between experiment runs (all runs go through
the same path). Document this in the article and use p95/p99 deltas rather than absolute numbers
for cross-run comparison.

### Auth flow summary

```
k6 (laptop)
  │
  │  HTTPS POST /openai/deployments/chat/completions
  │  Header: Ocp-Apim-Subscription-Key: <from .env>
  │  Header: X-Run-Id: baseline
  ▼
APIM gateway  (public endpoint, no VNet required)
  │
  │  Acquires Bearer token via system-assigned managed identity
  │  Forwards to selected Foundry backend
  ▼
azurerm_cognitive_account.foundry[region]
  (OpenAI-compatible endpoint, private to APIM via managed identity RBAC)
```

### k6 script (`experiment/load_test.js`)

The script reads all configuration — gateway URL, subscription key, run ID — from environment
variables so no values are hardcoded:

```javascript
import http from "k6/http";
import { check, sleep } from "k6";

const BASE_URL   = __ENV.APIM_GATEWAY_URL;   // e.g. https://apim-foundry-xxxx.azure-api.net
const APIM_KEY   = __ENV.APIM_SUBSCRIPTION_KEY;
const RUN_ID     = __ENV.RUN_ID || "unnamed";
const VUS        = parseInt(__ENV.VUS  || "20");
const ITERATIONS = parseInt(__ENV.ITER || "200");

export const options = {
  vus: VUS,
  iterations: ITERATIONS,
  summaryTrendStats: ["avg", "p(50)", "p(95)", "p(99)", "max"],
};

const PAYLOAD = JSON.stringify({
  model: "chat",
  messages: [{ role: "user", content: "Reply with exactly one word: Hello." }],
  max_tokens: 5,
});

export default function () {
  const res = http.post(
    `${BASE_URL}/openai/deployments/chat/completions?api-version=2024-02-01`,
    PAYLOAD,
    {
      headers: {
        "Content-Type": "application/json",
        "Ocp-Apim-Subscription-Key": APIM_KEY,
        "X-Run-Id": RUN_ID,
      },
    }
  );

  check(res, {
    "status 200": (r) => r.status === 200,
    "status 429 (throttled)": (r) => r.status === 429,
  });

  // short think-time to avoid token exhaustion in a single burst
  sleep(0.1);
}

export function handleSummary(data) {
  return { [`results/${RUN_ID}.json`]: JSON.stringify(data, null, 2) };
}
```

### Running an experiment iteration (APIM runs)

```bash
# Load endpoints from post-apply env file (git-ignored)
source infra/.env

k6 run experiment/load_test.js \
  -e APIM_GATEWAY_URL="$APIM_GATEWAY_URL" \
  -e APIM_SUBSCRIPTION_KEY="$APIM_SUBSCRIPTION_KEY" \
  -e RUN_ID=baseline \
  -e VUS=20 \
  -e ITER=200
```

### Running direct comparison runs (no APIM)

Two additional runs call Foundry endpoints directly — no gateway in the path. These use
`experiment/direct_test.js` with a `MODE` env var to switch strategy. Foundry API keys are
used here (loaded from `.env`; `local_auth_enabled = true` on the cognitive accounts).

```bash
source infra/.env

# Sequential fallback: try UK South → West Europe → Sweden Central on each 429
k6 run experiment/direct_test.js \
  -e MODE=sequential \
  -e RUN_ID=direct_sequential \
  -e VUS=20 -e ITER=200

# Weighted direct: same 33/33/34 split as APIM baseline but no gateway overhead
k6 run experiment/direct_test.js \
  -e MODE=weighted \
  -e RUN_ID=direct_weighted \
  -e VUS=20 -e ITER=200
```

Both scripts write results to `experiment/results/{run_id}.json` in the same format as
`load_test.js`, so `summarise.py` processes them identically.

---

## Auto-Destroy After 7 Days

### Strategy

On `terraform apply`, the resource group receives a `destroy_after` tag (deploy date + 7 days).
A GitHub Actions workflow runs on a daily schedule, reads the tag, and calls `terraform destroy`
once the date has passed. Authentication uses OIDC federated credentials — no long-lived secrets
stored in GitHub.

### GitHub Actions workflow (`.github/workflows/scheduled-destroy.yml`)

```yaml
name: Scheduled resource destroy

on:
  schedule:
    - cron: "0 6 * * *"   # 06:00 UTC daily
  workflow_dispatch:        # allow manual trigger

permissions:
  id-token: write
  contents: read

jobs:
  check-and-destroy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

      - name: Check destroy_after tag
        id: tag
        run: |
          TAG=$(az group show \
            --name rg-apim-foundry-perf \
            --query "tags.destroy_after" -o tsv 2>/dev/null || echo "")
          echo "destroy_after=$TAG" >> "$GITHUB_OUTPUT"

      - name: Destroy if expired
        if: steps.tag.outputs.destroy_after != '' && steps.tag.outputs.destroy_after < $(date -u +%Y-%m-%d)
        working-directory: infra
        env:
          TF_VAR_subscription_id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
          TF_VAR_publisher_name: ${{ secrets.TF_PUBLISHER_NAME }}
          TF_VAR_publisher_email: ${{ secrets.TF_PUBLISHER_EMAIL }}
        run: |
          terraform init -backend-config="..." 
          terraform destroy -auto-approve
```

> **OIDC setup:** Create a federated credential on an Entra app registration pointing at this
> repo + the `main` branch (or the `scheduled-destroy.yml` workflow). Assign the app `Contributor`
> on the sandbox subscription. Add `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`
> as GitHub Actions secrets. Detailed instructions in `.github/workflows/oidc-setup.md`.

> **Terraform state:** The destroy workflow needs access to Terraform state. Options: Terraform
> Cloud free tier, or an Azure Storage Account backend (itself outside the perf resource group so
> it survives the destroy). Configure the `backend` block in `main.tf` accordingly.

---

## Experiment Design

### Runs

**Direct runs** (`experiment/direct_test.js`) — no APIM in the path. Run first to establish a
baseline of raw Foundry behaviour and quantify the APIM latency overhead.

| Run ID | Strategy | What it shows |
|---|---|---|
| `direct_sequential` | Try UK South → West Europe → Sweden Central on each 429 | Latency penalty of naïve app-level fallback |
| `direct_weighted` | Random pick weighted 33/33/34 per request, no fallback | Same distribution as APIM baseline but zero gateway overhead — isolates APIM cost |

**APIM runs** (`experiment/load_test.js`) — traffic routed through the gateway.

Defined in `experiment/config.yaml`:

```yaml
runs:
  - id: "baseline"
    description: "Equal weight (33/33/34) across all three regions, no circuit breaker"
    vus: 20
    iterations: 200
    weights: { uksouth: 33, westeurope: 33, swedencentral: 34 }
    gateway_tpm_limit: 30000      # high — Foundry backends will saturate first
    circuit_breaker_failure_count: 0

  - id: "weighted_primary"
    description: "UK South favoured (60/25/15) — simulates production PTU priority"
    vus: 20
    iterations: 200
    weights: { uksouth: 60, westeurope: 25, swedencentral: 15 }
    gateway_tpm_limit: 30000
    circuit_breaker_failure_count: 0

  - id: "circuit_breaker"
    description: "Equal weight + circuit breaker trips after 3 failures per backend"
    vus: 20
    iterations: 200
    weights: { uksouth: 33, westeurope: 33, swedencentral: 34 }
    gateway_tpm_limit: 30000
    circuit_breaker_failure_count: 3

  - id: "gateway_throttle"
    description: "Low gateway TPM limit (500) — APIM throttles before backends saturate"
    vus: 20
    iterations: 200
    weights: { uksouth: 33, westeurope: 33, swedencentral: 34 }
    gateway_tpm_limit: 500
    circuit_breaker_failure_count: 0

  - id: "full_resilience"
    description: "Weighted priority + circuit breaker + moderate gateway limit"
    vus: 30
    iterations: 300
    weights: { uksouth: 50, westeurope: 30, swedencentral: 20 }
    gateway_tpm_limit: 15000
    circuit_breaker_failure_count: 3
```

### Metrics Captured Per Run

| Metric | Source | Direct runs | APIM runs |
|---|---|---|---|
| `success_rate` (% HTTP 200) | k6 `check` pass rate | ✓ | ✓ |
| `p50 / p95 / p99 latency (ms)` | k6 `http_req_duration` trend | ✓ | ✓ |
| `throughput (req/s)` | k6 `http_reqs` rate | ✓ | ✓ |
| `http_429_count` | k6 check for `status == 429` | ✓ | ✓ |
| `tokens_consumed` | `X-Tokens-Consumed` response header | — | ✓ (policy sets header) |
| `backend_distribution` | App Insights `foundry-perf` metric, `backend_id` dim | — | ✓ |
| `fallback_count` | k6 custom counter (sequential mode only) | ✓ | — |

The latency delta between `direct_weighted` and `baseline` (same traffic distribution, different
path) is the empirical APIM overhead.

### Recursive Iteration

```
# Phase 1 — direct runs (no Terraform changes needed between these)
k6 run direct_test.js -e MODE=sequential -e RUN_ID=direct_sequential ...
k6 run direct_test.js -e MODE=weighted   -e RUN_ID=direct_weighted   ...

# Phase 2 — APIM runs (re-apply Terraform between each to update policy/pool)
for each run in config.yaml:
  1. terraform apply -var-file=terraform.tfvars \
       -var="gateway_tpm_limit=<N>" \
       -var="backend_weight_uksouth=<W>" \
       ...
     (Only policy + pool resources change; apply takes <2 min after first deploy)

  2. Wait 60 s for quota + policy propagation

  3. k6 run experiment/load_test.js \
       -e RUN_ID=<run.id> \
       -e VUS=<run.vus> \
       -e ITER=<run.iterations> \
       ...

  4. python experiment/summarise.py --results experiment/results/
     → appends a row to comparison_table.md
```

---

## Deployment Sequence

```
# Prerequisites
brew install k6 terraform azure-cli

# 1. Authenticate (once)
az login
az account set --subscription <sandbox-subscription-id>

# 2. Create terraform.tfvars (git-ignored) with subscription_id, publisher_name, publisher_email
cp infra/terraform.tfvars.example infra/terraform.tfvars
$EDITOR infra/terraform.tfvars

# 3. Deploy infrastructure (~25–45 min for APIM first time)
cd infra
terraform init
terraform plan -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars

# 4. Export endpoints + key to .env (git-ignored)
terraform output -json | python ../scripts/write_env.py > .env

# 5. Run experiments
source .env
cd ..
for RUN in baseline weighted_primary circuit_breaker gateway_throttle full_resilience; do
  # Re-apply Terraform with run-specific vars (fast — policy only)
  cd infra && terraform apply -var-file=terraform.tfvars \
    -var="gateway_tpm_limit=$(yq ".runs[] | select(.id == \"$RUN\") | .gateway_tpm_limit" ../experiment/config.yaml)" \
    ... && cd ..

  sleep 60  # quota propagation

  k6 run experiment/load_test.js \
    -e APIM_GATEWAY_URL="$APIM_GATEWAY_URL" \
    -e APIM_SUBSCRIPTION_KEY="$APIM_SUBSCRIPTION_KEY" \
    -e RUN_ID="$RUN" -e VUS=20 -e ITER=200
done

# 6. Summarise
python experiment/summarise.py --results experiment/results/

# 7. Manual destroy (or wait for GitHub Actions)
cd infra && terraform destroy -var-file=terraform.tfvars
```

---

## Known Limitations & Mitigations

| Limitation | Mitigation |
|---|---|
| APIM backend-pool load balancing is **approximate** — gateway instances don't sync state | Developer_1 is single-unit so no multi-instance divergence. Accept and note in article. |
| Circuit breaker state is **per-gateway-instance** | Same — single unit, not a concern here. |
| `azurerm_api_management_backend` pool type may require `azurerm_resource` ARM workaround | Noted in plan; verify at implement time; fall back to `azurerm_resource` if needed. |
| Foundry quota changes take 1–2 min to propagate | 60 s sleep between `terraform apply` and k6 run. |
| Cross-region latency (West Europe, Sweden Central) inflates absolute p99 for those backends | Expected; adds an interesting real-world dimension to the article. Document clearly. |
| Local k6 → Azure adds ~10–30 ms overhead | Use relative deltas between runs, not absolute latency values. |
| `estimate-prompt-tokens="false"` means prompts may pass through even at limit | Acceptable for experiment; note in article. |
| APIM Developer SKU provisions in 25–45 min | Provision once; policy-only re-applies are <2 min. |

---

## Security Checklist

- [ ] `.gitignore` covers `*.tfvars`, `*.tfstate*`, `.terraform/`, `infra/.env`, `experiment/results/`
- [ ] No hardcoded subscription IDs, tenant IDs, keys, emails, or endpoint URLs in committed files
- [ ] Foundry endpoint URLs referenced only via `azurerm_cognitive_account.foundry[*].endpoint` in Terraform (not interpolated into any committed string)
- [ ] Managed identity is the sole credential for APIM → Foundry auth
- [ ] APIM subscription key read from `$APIM_SUBSCRIPTION_KEY` env var in k6; never in script source
- [ ] `publisher_email` supplied via `.tfvars` only
- [ ] All Terraform `sensitive` outputs confirmed before first `terraform apply`
- [ ] GitHub Actions secrets (OIDC) configured; no long-lived credentials stored

---

## Article Outline

1. **Motivation** — why multi-endpoint fallback matters for production AI services
2. **Architecture** — three Foundry regions, APIM as AI gateway, backend pools, circuit breakers
3. **Infrastructure setup** — Terraform walkthrough (IaC for reproducibility)
4. **Experiment methodology** — saturating Foundry quotas with k6, capturing metrics
5. **Direct baseline results** — sequential fallback vs weighted direct: the latency penalty of naïve app-level fallback
6. **APIM results** — comparison table across five APIM configurations
7. **The APIM overhead question** — `direct_weighted` vs `baseline` delta: what the gateway costs and what it buys
8. **Key findings** — which configuration yielded the best resilience and why
9. **Production recommendations** — multi-region, PTU vs pay-as-you-go priority groups, session affinity
10. **Code** — link to this repository

---

## Next Steps

- [x] Write `.gitignore` and `infra/terraform.tfvars.example`
- [x] Scaffold all `infra/` Terraform files
- [x] Write `experiment/load_test.js` k6 script (APIM runs)
- [x] Write `experiment/summarise.py` result aggregator
- [x] Write `experiment/config.yaml` run definitions
- [x] Write `.github/workflows/scheduled-destroy.yml` auto-destroy workflow
- [ ] `terraform apply` — in progress
- [ ] Add Foundry endpoint + key outputs to `infra/outputs.tf` (pending apply completion)
- [ ] Update `scripts/export_env.sh` to export Foundry endpoints and keys
- [ ] Write `experiment/direct_test.js` (sequential + weighted modes)
- [ ] Add `direct_sequential` and `direct_weighted` to `experiment/config.yaml`
- [ ] Initialise git repository and push to GitHub (set to public)
- [ ] Configure GitHub OIDC federated credential (see `oidc-setup.md`)
- [ ] Configure Terraform remote state backend (Azure Storage Account, outside perf RG)
- [ ] Run `direct_sequential` and `direct_weighted` experiments
- [ ] Run five APIM experiment runs
- [ ] Run `summarise.py` and review comparison table
