output "resource_group_name" {
  description = "Resource group name for the state storage account"
  value       = azurerm_resource_group.rg.name
}

output "storage_account_name" {
  description = "Name of the storage account for Terraform state"
  value       = azurerm_storage_account.tfstate.name
}

output "container_name" {
  description = "Name of the blob container for state files"
  value       = azurerm_storage_container.tfstate.name
}

output "state_file_key" {
  description = "Suggested state file key (blob name) for the main configuration"
  value       = var.state_file_key
}

output "backend_config_instructions" {
  description = "Instructions for configuring the main module backend"
  value       = <<-EOT
    Create backend.hcl in the parent directory with:
    
    resource_group_name  = "${azurerm_resource_group.rg.name}"
    storage_account_name = "${azurerm_storage_account.tfstate.name}"
    container_name       = "${azurerm_storage_container.tfstate.name}"
    key                  = "${var.state_file_key}"
    
    Then run: terraform init -reconfigure -backend-config=backend.hcl
  EOT
}
