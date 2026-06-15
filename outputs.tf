output "resource_group_name" {
  description = "Name of the resource group"
  value       = azurerm_resource_group.rg.name
}

output "vm_id" {
  description = "Resource ID of the Windows Server VM"
  value       = azurerm_windows_virtual_machine.vm.id
}

output "vm_name" {
  description = "Name of the Windows Server VM"
  value       = azurerm_windows_virtual_machine.vm.name
}

output "vm_private_ip" {
  description = "Private IP address of the VM"
  value       = azurerm_network_interface.vm.private_ip_address
}

output "bastion_host_id" {
  description = "Resource ID of the Azure Bastion host"
  value       = azurerm_bastion_host.bastion.id
}

output "nat_gateway_public_ip" {
  description = "Public IP address used by the NAT gateway (outbound)"
  value       = azurerm_public_ip.nat.ip_address
}

output "vnet_name" {
  description = "Name of the virtual network"
  value       = azurerm_virtual_network.vnet.name
}

output "scripts_storage_account_name" {
  description = "Name of the storage account used for VM provisioning scripts"
  value       = azurerm_storage_account.scripts.name
}

output "hyperv_host_nsg_id" {
  description = "Resource ID of the Network Security Group applied to the Hyper-V host NIC"
  value       = azurerm_network_security_group.vm.id
}

output "nsg_flow_logs_enabled" {
  description = "Whether Virtual Network flow logs were enabled (controlled by enable_nsg_flow_logs)"
  value       = var.enable_nsg_flow_logs
}

output "flow_logs_storage_account_name" {
  description = "Storage account name used for Virtual Network flow logs (null if disabled)"
  value       = var.enable_nsg_flow_logs ? azurerm_storage_account.flowlogs[0].name : null
}

output "traffic_analytics_workspace_id" {
  description = "Log Analytics workspace resource ID used for Traffic Analytics (null if disabled)"
  value       = (var.enable_nsg_flow_logs && var.enable_traffic_analytics) ? azurerm_log_analytics_workspace.flowlogs[0].id : null
}

output "hyperv_ready_note" {
  description = "Reminder to reboot the VM after Hyper-V installation"
  value       = "After first boot, reboot the VM once to complete Hyper-V role installation and run the setup script. Connect via Azure Bastion."
}
