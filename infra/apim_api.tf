resource "azurerm_api_management_api" "foundry" {
  name                  = "foundry-chat"
  resource_group_name   = azurerm_resource_group.rg.name
  api_management_name   = azurerm_api_management.apim.name
  display_name          = "Foundry Chat Completions"
  path                  = "openai"
  protocols             = ["https"]
  revision              = "1"
  subscription_required = true
}

# Manually define the chat completions operation rather than importing the full
# Azure OpenAI OpenAPI spec, which is large and caused import validation errors.
resource "azurerm_api_management_api_operation" "chat_completions" {
  operation_id        = "post-chat-completions"
  api_name            = azurerm_api_management_api.foundry.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  display_name        = "Chat Completions"
  method              = "POST"
  url_template        = "/deployments/{deploymentId}/chat/completions"

  template_parameter {
    name     = "deploymentId"
    required = true
    type     = "string"
  }
}

resource "azurerm_api_management_api_policy" "foundry" {
  api_name            = azurerm_api_management_api.foundry.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name

  xml_content = templatefile("${path.module}/apim_policy.xml.tpl", {
    gateway_rpm_limit     = var.gateway_rpm_limit
    apim_retry_count      = var.apim_retry_count
    apim_retry_interval_s = var.apim_retry_interval_s
  })

  depends_on = [azapi_resource.foundry_pool]
}

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
