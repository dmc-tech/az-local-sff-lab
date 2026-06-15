# ---------------------------------------------------------------------------
# Bootstrap: Storage account and container for Terraform state
# Run this once, then use the outputs to configure the main module's backend.
# ---------------------------------------------------------------------------

provider "azurerm" {
  features {}
}

# ---------------------------------------------------------------------------
# Resource group for state storage
# ---------------------------------------------------------------------------
resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# ---------------------------------------------------------------------------
# Unique suffix for storage account name (must be globally unique, 3-24 chars)
# ---------------------------------------------------------------------------
resource "random_string" "suffix" {
  length  = 8
  special = false
  upper   = false
}

# ---------------------------------------------------------------------------
# Storage account for Terraform state
# ---------------------------------------------------------------------------
resource "azurerm_storage_account" "tfstate" {
  name                     = substr("${var.storage_account_name_prefix}${random_string.suffix.result}", 0, 24)
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"

  blob_properties {
    versioning_enabled = true
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Container for state files
# ---------------------------------------------------------------------------
resource "azurerm_storage_container" "tfstate" {
  name                  = var.container_name
  storage_account_id    = azurerm_storage_account.tfstate.id
  container_access_type = "private"
}
