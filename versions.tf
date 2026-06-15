terraform {
  required_version = ">= 1.0"

  # Partial backend config: use -backend-config=backend.hcl (see backend.hcl.example)
  backend "azurerm" {}

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}
