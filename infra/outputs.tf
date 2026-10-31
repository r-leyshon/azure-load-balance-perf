# All outputs containing endpoints or keys are marked sensitive.
# Use scripts/export_env.sh to write them to infra/.env (git-ignored).

output "apim_gateway_url" {
  description = "Public HTTPS gateway URL — target for k6 load tests."
  value       = azurerm_api_management.apim.gateway_url
  sensitive   = true
}

output "apim_subscription_key" {
  description = "Primary subscription key for the load-test product."
  value       = azurerm_api_management_subscription.load_test.primary_key
  sensitive   = true
}

output "app_insights_connection_string" {
  description = "Application Insights connection string for local SDK use."
  value       = azurerm_application_insights.ai.connection_string
  sensitive   = true
}

output "destroy_after_date" {
  description = "Date after which the GitHub Actions scheduled workflow will destroy all resources."
  value       = local.destroy_after
}

output "resource_group_name" {
  value = azurerm_resource_group.rg.name
}

output "foundry_endpoint_uksouth" {
  description = "Azure OpenAI endpoint for UK South Foundry instance."
  value       = azurerm_cognitive_account.foundry["uksouth"].endpoint
  sensitive   = true
}

output "foundry_endpoint_westeurope" {
  description = "Azure OpenAI endpoint for West Europe Foundry instance."
  value       = azurerm_cognitive_account.foundry["westeurope"].endpoint
  sensitive   = true
}

output "foundry_endpoint_swedencentral" {
  description = "Azure OpenAI endpoint for Sweden Central Foundry instance."
  value       = azurerm_cognitive_account.foundry["swedencentral"].endpoint
  sensitive   = true
}

output "foundry_key_uksouth" {
  description = "API key for UK South Foundry instance (direct k6 tests only)."
  value       = azurerm_cognitive_account.foundry["uksouth"].primary_access_key
  sensitive   = true
}

output "foundry_key_westeurope" {
  description = "API key for West Europe Foundry instance (direct k6 tests only)."
  value       = azurerm_cognitive_account.foundry["westeurope"].primary_access_key
  sensitive   = true
}

output "foundry_key_swedencentral" {
  description = "API key for Sweden Central Foundry instance (direct k6 tests only)."
  value       = azurerm_cognitive_account.foundry["swedencentral"].primary_access_key
  sensitive   = true
}
