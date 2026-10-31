resource "azurerm_api_management" "apim" {
  name                = "apim-foundry-${random_id.suffix.hex}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  publisher_name      = var.publisher_name
  publisher_email     = var.publisher_email
  sku_name            = "Developer_1"

  identity {
    type = "SystemAssigned"
  }

  tags = local.common_tags
}

# Grant APIM's managed identity read access to each Foundry deployment.
# This is the only credential in the chain — no API keys anywhere.
resource "azurerm_role_assignment" "apim_foundry" {
  for_each = local.foundry_regions

  scope                = azurerm_cognitive_account.foundry[each.key].id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = azurerm_api_management.apim.identity[0].principal_id
}

resource "azurerm_log_analytics_workspace" "law" {
  name                = "law-foundry-perf-${random_id.suffix.hex}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.common_tags
}

resource "azurerm_application_insights" "ai" {
  name                = "ai-foundry-perf-${random_id.suffix.hex}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  application_type    = "web"
  workspace_id        = azurerm_log_analytics_workspace.law.id
  tags                = local.common_tags
}

resource "azurerm_api_management_logger" "ai_logger" {
  name                = "appinsights-logger"
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name

  application_insights {
    instrumentation_key = azurerm_application_insights.ai.instrumentation_key
  }
}
