locals {
  backend_weights = {
    uksouth       = var.backend_weight_uksouth
    westeurope    = var.backend_weight_westeurope
    swedencentral = var.backend_weight_swedencentral
  }
}

# Individual backend for each Foundry region.
# The URL is derived from the cognitive account endpoint so no endpoint value
# ever appears as a literal in committed code.
resource "azurerm_api_management_backend" "foundry" {
  for_each = local.foundry_regions

  name                = "foundry-${each.key}"
  resource_group_name = azurerm_resource_group.rg.name
  api_management_name = azurerm_api_management.apim.name
  protocol            = "http"

  # Endpoint ends with "/"; APIM strips the API path prefix ("openai") from the
  # incoming URL and appends the remainder, so this becomes:
  # {endpoint}openai/deployments/{deploymentId}/chat/completions
  url = "${azurerm_cognitive_account.foundry[each.key].endpoint}openai"

  tls {
    validate_certificate_chain = true
    validate_certificate_name  = true
  }
}

# Per-backend circuit breaker rules, applied via azapi to access the full ARM schema.
# Always present so that count=0 explicitly clears rules rather than leaving prior
# config on the backend (azapi_update_resource destroy does not reset Azure state).
resource "azapi_update_resource" "circuit_breaker" {
  for_each = local.foundry_regions

  type        = "Microsoft.ApiManagement/service/backends@2023-09-01-preview"
  resource_id = azurerm_api_management_backend.foundry[each.key].id

  # azapi 2.x requires a native HCL object, not jsonencode()
  body = {
    properties = {
      circuitBreaker = {
        rules = var.circuit_breaker_failure_count > 0 ? [
          {
            name             = "trip-on-overload"
            tripDuration     = "PT60S"
            acceptRetryAfter = true
            failureCondition = {
              count    = var.circuit_breaker_failure_count
              interval = "PT60S"
              statusCodeRanges = concat(
                var.circuit_breaker_on_429 ? [{ min = 429, max = 429 }] : [],
                [{ min = 500, max = 599 }]
              )
            }
          }
        ] : []
      }
    }
  }
}

# Backend pool — groups the three Foundry backends for weighted load balancing.
# Uses azapi because the pool type is not yet a first-class attribute in azurerm_api_management_backend.
resource "azapi_resource" "foundry_pool" {
  type      = "Microsoft.ApiManagement/service/backends@2023-09-01-preview"
  name      = "foundry-pool"
  parent_id = azurerm_api_management.apim.id

  # azapi 2.x requires a native HCL object, not jsonencode()
  body = {
    properties = {
      description = "Weighted pool across UK South, West Europe, and Sweden Central Foundry backends"
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
  }

  depends_on = [azurerm_api_management_backend.foundry]
}
