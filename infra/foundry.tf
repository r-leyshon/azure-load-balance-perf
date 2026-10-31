locals {
  foundry_regions = {
    uksouth       = "uksouth"
    westeurope    = "westeurope"
    swedencentral = "swedencentral"
  }
}

resource "azurerm_cognitive_account" "foundry" {
  for_each = local.foundry_regions

  name                = "foundry-${each.key}-${random_id.suffix.hex}"
  location            = each.value
  resource_group_name = azurerm_resource_group.rg.name
  kind                = "OpenAI"
  sku_name            = "S0"

  tags = local.common_tags
}

resource "azurerm_cognitive_deployment" "model" {
  for_each = local.foundry_regions

  name                 = "chat"
  cognitive_account_id = azurerm_cognitive_account.foundry[each.key].id

  model {
    format  = "OpenAI"
    name    = var.model_name
    version = var.model_version
  }

  sku {
    name = "Standard"
    # capacity unit = 1 000 TPM; quota_tpm = 10000 → capacity = 10
    capacity = var.quota_tpm / 1000
  }
}
