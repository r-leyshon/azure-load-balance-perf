terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.0"
    }
    azapi = {
      source  = "azure/azapi"
      version = ">= 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.9"
    }
  }

  # Configure a remote backend before first apply.
  # An Azure Storage Account outside this resource group is recommended so that
  # state survives the scheduled destroy. See scripts/bootstrap_state.sh.
  # backend "azurerm" {
  #   resource_group_name  = "rg-tfstate"
  #   storage_account_name = "<storage-account-name>"
  #   container_name       = "tfstate"
  #   key                  = "apim-foundry-perf.tfstate"
  # }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

provider "azapi" {}

resource "random_id" "suffix" {
  byte_length = 4
}

# Pinned at first apply so the destroy_after tag stays stable across re-applies.
resource "time_static" "deploy_time" {}

locals {
  destroy_after = formatdate("YYYY-MM-DD", timeadd(time_static.deploy_time.rfc3339, "168h"))

  common_tags = {
    environment   = "sandbox"
    project       = "apim-foundry-perf"
    destroy_after = local.destroy_after
  }
}

resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.apim_location
  tags     = local.common_tags
}
