variable "resource_group_name" {
  description = "Name of the resource group for Terraform state storage"
  type        = string
  default     = "rg-tfstate-uks"
}

variable "location" {
  description = "Azure region for the state storage account"
  type        = string
  default     = "UK South"
}

variable "storage_account_name_prefix" {
  description = "Prefix for the storage account name (3-24 chars total with random suffix; alphanumeric only)"
  type        = string
  default     = "tfstate"
}

variable "container_name" {
  description = "Name of the blob container for Terraform state files"
  type        = string
  default     = "tfstate"
}

variable "state_file_key" {
  description = "Name of the state file (blob key) in the container - used for backend config"
  type        = string
  default     = "hyperv-host.tfstate"
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default = {
    Purpose   = "Terraform state"
    ManagedBy = "Terraform"
  }
}
