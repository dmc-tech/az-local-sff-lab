variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
  default     = "rg-hyperv-host-uks"
}

variable "location" {
  description = "Azure region for deployment"
  type        = string
  default     = "UK South"
}

variable "environment" {
  description = "Environment tag (e.g. dev, prod)"
  type        = string
  default     = "dev"
}

variable "admin_username" {
  description = "Local administrator username for the Windows VM"
  type        = string
  default     = "azureadmin"
}

variable "admin_password" {
  description = "Local administrator password for the Windows VM"
  type        = string
  sensitive   = true
}

variable "vm_name" {
  description = "Name of the Windows Server VM. Must be 15 characters or fewer (Windows computer name limit)."
  type        = string
  default     = "vm-hv-host-1"

  validation {
    condition     = length(var.vm_name) <= 15
    error_message = "vm_name must be 15 characters or fewer (Windows computer name limit)."
  }
}

variable "nested_vm_prefix" {
  description = "Prefix used for nested Hyper-V VMs created by setup.ps1 (e.g. NestedVM -> NestedVM-01)."
  type        = string
  default     = "NestedVM"
}

variable "nested_vm_count" {
  description = "Number of nested Hyper-V VMs to create on the host. Valid values: 1 or 3."
  type        = number
  default     = 3

  validation {
    condition     = contains([1, 3], var.nested_vm_count)
    error_message = "nested_vm_count must be 1 or 3."
  }
}

variable "data_disk_size_gb" {
  description = "Size of the attached data disk in GB"
  type        = number
  default     = 1024 # 1 TB
}

variable "script_storage_account_prefix" {
  description = "Prefix for the scripts storage account name (alphanumeric, globally unique with random suffix)"
  type        = string
  default     = "scriptstor"
}

variable "setup_script_path" {
  description = "Path to the setup PowerShell script in the repo (relative to Terraform root)"
  type        = string
  default     = "scripts/setup.ps1"
}

variable "voucher_script_path" {
  description = "Path to the SFF node voucher retrieval script (relative to Terraform root)"
  type        = string
  default     = "scripts/Get-SffNodeVoucher.ps1"
}

variable "bootstrap_script_path" {
  description = "Path to the VM bootstrap script run by Custom Script Extension (-File), relative to Terraform root"
  type        = string
  default     = "scripts/vm-bootstrap.ps1"
}

variable "k3s_arc_script_path" {
  description = "Path to the Linux K3s + Azure Arc setup script staged on the Hyper-V host for nested VM copy"
  type        = string
  default     = "scripts/setup-k3s-arc.sh"
}

variable "k3s_join_agent_script_path" {
  description = "Path to k3s-join-agent.sh staged on the Hyper-V host for nested VM copy"
  type        = string
  default     = "scripts/k3s-join-agent.sh"
}

variable "k3s_bootstrap_agents_script_path" {
  description = "Path to bootstrap-k3s-agents.sh staged on the Hyper-V host for nested VM copy"
  type        = string
  default     = "scripts/bootstrap-k3s-agents.sh"
}

variable "k3s_setup_instructions_path" {
  description = "Path to K3S-CLUSTER-SETUP.txt copied to C:\\Scripts on the Hyper-V host"
  type        = string
  default     = "scripts/K3S-CLUSTER-SETUP.txt"
}

variable "k3s_automation_script_paths" {
  description = "K3s automation scripts copied to C:\\Scripts on the Hyper-V host (Deploy-K3sCluster.ps1 orchestrates the cluster build)"
  type        = list(string)
  default = [
    "scripts/Deploy-K3sCluster.ps1",
    "scripts/k3s-node-prep.sh",
    "scripts/k3s-install-server.sh",
  ]
}

variable "os_image_package_url" {
  description = "URL for the Azure Local OS package (ZIP containing provision-os.iso) or a direct ISO URL."
  type        = string
  default     = "https://azurestackreleases.download.prss.microsoft.com/dbazure/AzureLocal/OS-Composition-Linux/10.2604.0.3100/roe-10.2604.0.3100.zip"
}

variable "configurator_app_url" {
  description = "URL for the Azure Local Configurator app (.msix or .exe) for the Hyper-V host VM. MSIX is recommended; use Add-AppxPackage path in setup.ps1."
  type        = string
  default     = "https://azurestackreleases.download.prss.microsoft.com/dbazure/AzureLocal/ConfiguratorApp/10.3372.1.3007/V2/ConfiguratorAppV2-10.3372.1.3007.msix"
  
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default = {
    ManagedBy = "Terraform"
  }
}

variable "enable_nsg_flow_logs" {
  description = "If true, deploys Network Watcher + Virtual Network flow logs (successor to NSG flow logs)."
  type        = bool
  default     = true
}

variable "enable_traffic_analytics" {
  description = "If true, enables Traffic Analytics for Virtual Network flow logs (requires Log Analytics workspace). Only applies when enable_nsg_flow_logs is true."
  type        = bool
  default     = true
}

variable "nsg_flow_logs_retention_days" {
  description = "Retention (days) for Virtual Network flow logs in the storage account. Only applies when enable_nsg_flow_logs is true."
  type        = number
  default     = 7
}

variable "log_analytics_retention_days" {
  description = "Retention (days) for the Log Analytics workspace used by Traffic Analytics. Only applies when enable_traffic_analytics is true."
  type        = number
  default     = 30
}

variable "flow_logs_storage_account_prefix" {
  description = "Prefix for the flow logs storage account name (alphanumeric, globally unique with random suffix). Only applies when enable_nsg_flow_logs is true."
  type        = string
  default     = "flowlogstor"
}
