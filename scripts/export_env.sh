#!/usr/bin/env bash
# Run from the infra/ directory after terraform apply.
# Writes sensitive outputs to infra/.env (git-ignored).
# Usage: cd infra && bash ../scripts/export_env.sh

set -euo pipefail

OUT=".env"

{
  echo "export APIM_GATEWAY_URL=\"$(terraform output -raw apim_gateway_url)\""
  echo "export APIM_SUBSCRIPTION_KEY=\"$(terraform output -raw apim_subscription_key)\""
  echo "export APP_INSIGHTS_CONNECTION_STRING=\"$(terraform output -raw app_insights_connection_string)\""
  # Deployment name is fixed in Terraform — matches azurerm_cognitive_deployment.model name.
  echo "export DEPLOYMENT_ID=\"chat\""
  # Direct Foundry endpoints and keys — for direct_sequential / direct_weighted experiments.
  echo "export FOUNDRY_ENDPOINT_UKSOUTH=\"$(terraform output -raw foundry_endpoint_uksouth)\""
  echo "export FOUNDRY_ENDPOINT_WESTEUROPE=\"$(terraform output -raw foundry_endpoint_westeurope)\""
  echo "export FOUNDRY_ENDPOINT_SWEDENCENTRAL=\"$(terraform output -raw foundry_endpoint_swedencentral)\""
  echo "export FOUNDRY_KEY_UKSOUTH=\"$(terraform output -raw foundry_key_uksouth)\""
  echo "export FOUNDRY_KEY_WESTEUROPE=\"$(terraform output -raw foundry_key_westeurope)\""
  echo "export FOUNDRY_KEY_SWEDENCENTRAL=\"$(terraform output -raw foundry_key_swedencentral)\""
} > "$OUT"

echo "Endpoints written to infra/$OUT (git-ignored)."
echo "Run: source infra/$OUT"
