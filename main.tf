# ---------------------------------------------------------------------------
# Provider
# ---------------------------------------------------------------------------
provider "azurerm" {
  features {}
}

# ---------------------------------------------------------------------------
# Resource group
# ---------------------------------------------------------------------------
resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# ---------------------------------------------------------------------------
# Virtual network and subnets
# ---------------------------------------------------------------------------
resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-hyperv-${replace(lower(var.location), " ", "-")}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]
  tags                = var.tags
}

resource "azurerm_subnet" "vm" {
  name                            = "snet-vm"
  resource_group_name             = azurerm_resource_group.rg.name
  virtual_network_name            = azurerm_virtual_network.vnet.name
  address_prefixes                = ["10.0.1.0/24"]
  default_outbound_access_enabled = false

}

# ---------------------------------------------------------------------------
# NSG for the Hyper-V host VM
# (Recommended for security. Flow logs are collected at the VNet level.)
# ---------------------------------------------------------------------------
resource "azurerm_network_security_group" "vm" {
  name                = "nsg-${var.vm_name}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = var.tags
}

# Allow Azure Bastion to RDP to the VM (AzureBastionSubnet -> VM NIC)
resource "azurerm_network_security_rule" "allow_bastion_rdp" {
  name                        = "Allow-AzureBastion-RDP"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "3389"
  source_address_prefixes     = azurerm_subnet.bastion.address_prefixes
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.vm.name
}

# Bastion requires a dedicated subnet named AzureBastionSubnet with /26 or larger
resource "azurerm_subnet" "bastion" {
  name                 = "AzureBastionSubnet"
  resource_group_name   = azurerm_resource_group.rg.name
  virtual_network_name  = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.2.0/26"]
}

# ---------------------------------------------------------------------------
# NAT Gateway (for outbound internet from VNet)
# ---------------------------------------------------------------------------
resource "azurerm_public_ip" "nat" {
  name                = "pip-nat-gateway"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway" "nat" {
  name                    = "nat-gateway"
  location                = azurerm_resource_group.rg.location
  resource_group_name     = azurerm_resource_group.rg.name
  sku_name                = "Standard"
  idle_timeout_in_minutes = 10
  tags                    = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "nat" {
  nat_gateway_id       = azurerm_nat_gateway.nat.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "vm" {
  subnet_id      = azurerm_subnet.vm.id
  nat_gateway_id = azurerm_nat_gateway.nat.id
}

# ---------------------------------------------------------------------------
# Azure Bastion
# ---------------------------------------------------------------------------
resource "azurerm_public_ip" "bastion" {
  name                = "pip-bastion"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_bastion_host" "bastion" {
  name                = "bastion-hyperv-host"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                 = "configuration"
    subnet_id            = azurerm_subnet.bastion.id
    public_ip_address_id = azurerm_public_ip.bastion.id
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Network interface for Windows Server VM
# ---------------------------------------------------------------------------
resource "azurerm_network_interface" "vm" {
  name                = "nic-${var.vm_name}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.vm.id
    private_ip_address_allocation = "Dynamic"
  }

  tags = var.tags
}

resource "azurerm_network_interface_security_group_association" "vm" {
  network_interface_id      = azurerm_network_interface.vm.id
  network_security_group_id = azurerm_network_security_group.vm.id
}

# ---------------------------------------------------------------------------
# Windows Server 2025 VM with nested virtualization (Ev5 series)
# Sized to run 3 nested VMs: 3 x (32 GB, 8 vCPUs) = 96 GB, 24 vCPUs
# Standard_E32s_v5: 32 vCPUs, 256 GB RAM - sufficient for host + 3 nested VMs
# ---------------------------------------------------------------------------
resource "azurerm_windows_virtual_machine" "vm" {
  name                = var.vm_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  size                = "Standard_E32s_v5" # Nested virtualization supported; 32 vCPUs, 256 GB
  admin_username      = var.admin_username
  admin_password      = var.admin_password

  network_interface_ids = [azurerm_network_interface.vm.id]

  os_disk {
    name                 = "osdisk-${var.vm_name}"
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2025-datacenter"
    version   = "latest"
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Auto-shutdown schedule (19:00 GMT every night)
# ---------------------------------------------------------------------------
resource "azurerm_dev_test_global_vm_shutdown_schedule" "vm" {
  virtual_machine_id = azurerm_windows_virtual_machine.vm.id
  location           = azurerm_resource_group.rg.location
  enabled            = true

  daily_recurrence_time = "1900"
  timezone              = "GMT Standard Time"

  notification_settings {
    enabled = false
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# 1 TB data disk
# ---------------------------------------------------------------------------
resource "azurerm_managed_disk" "data" {
  name                 = "disk-data-${var.vm_name}"
  location             = azurerm_resource_group.rg.location
  resource_group_name  = azurerm_resource_group.rg.name
  storage_account_type = "Premium_LRS"
  create_option        = "Empty"
  disk_size_gb         = var.data_disk_size_gb

  tags = var.tags
}

resource "azurerm_virtual_machine_data_disk_attachment" "data" {
  managed_disk_id    = azurerm_managed_disk.data.id
  virtual_machine_id = azurerm_windows_virtual_machine.vm.id
  lun                = 0
  caching            = "ReadWrite"
}

# ---------------------------------------------------------------------------
# Storage account for VM provisioning scripts
# ---------------------------------------------------------------------------
resource "random_string" "scripts_suffix" {
  length  = 8
  special = false
  upper   = false
}

resource "azurerm_storage_account" "scripts" {
  name                     = substr("${var.script_storage_account_prefix}${random_string.scripts_suffix.result}", 0, 24)
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"
  shared_access_key_enabled = true # Custom Script Extension + blob uploads use account key

  blob_properties {
    versioning_enabled = true
  }

  tags = var.tags
}

resource "azurerm_storage_container" "scripts" {
  name                  = "scripts"
  storage_account_id     = azurerm_storage_account.scripts.id
  container_access_type  = "private"
}

data "azurerm_storage_account_blob_container_sas" "scripts_read" {
  connection_string = azurerm_storage_account.scripts.primary_connection_string
  container_name    = azurerm_storage_container.scripts.name
  https_only        = true

  start  = "2024-01-01T00:00:00Z"
  expiry = "2034-01-01T00:00:00Z"

  permissions {
    read   = true
    add    = false
    create = false
    write  = false
    delete = false
    list   = true
  }
}

# Upload the setup script; content_md5 ensures Terraform re-uploads on change
resource "azurerm_storage_blob" "setup_script" {
  name                   = basename(var.setup_script_path)
  storage_account_name   = azurerm_storage_account.scripts.name
  storage_container_name = azurerm_storage_container.scripts.name
  type                   = "Block"
  source                 = var.setup_script_path
  content_md5            = filemd5(var.setup_script_path)
}

resource "azurerm_storage_blob" "voucher_script" {
  name                   = basename(var.voucher_script_path)
  storage_account_name   = azurerm_storage_account.scripts.name
  storage_container_name = azurerm_storage_container.scripts.name
  type                   = "Block"
  source                 = var.voucher_script_path
  content_md5            = filemd5(var.voucher_script_path)
}

resource "azurerm_storage_blob" "bootstrap_script" {
  name                   = basename(var.bootstrap_script_path)
  storage_account_name   = azurerm_storage_account.scripts.name
  storage_container_name = azurerm_storage_container.scripts.name
  type                   = "Block"
  source                 = var.bootstrap_script_path
  content_md5            = filemd5(var.bootstrap_script_path)
}

resource "azurerm_storage_blob" "k3s_arc_script" {
  name                   = "setup_k3s_arc.sh"
  storage_account_name   = azurerm_storage_account.scripts.name
  storage_container_name = azurerm_storage_container.scripts.name
  type                   = "Block"
  source                 = var.k3s_arc_script_path
  content_md5            = filemd5(var.k3s_arc_script_path)
}

resource "azurerm_storage_blob" "k3s_join_agent_script" {
  name                   = basename(var.k3s_join_agent_script_path)
  storage_account_name   = azurerm_storage_account.scripts.name
  storage_container_name = azurerm_storage_container.scripts.name
  type                   = "Block"
  source                 = var.k3s_join_agent_script_path
  content_md5            = filemd5(var.k3s_join_agent_script_path)
}

resource "azurerm_storage_blob" "k3s_bootstrap_agents_script" {
  name                   = basename(var.k3s_bootstrap_agents_script_path)
  storage_account_name   = azurerm_storage_account.scripts.name
  storage_container_name = azurerm_storage_container.scripts.name
  type                   = "Block"
  source                 = var.k3s_bootstrap_agents_script_path
  content_md5            = filemd5(var.k3s_bootstrap_agents_script_path)
}

resource "azurerm_storage_blob" "k3s_setup_instructions" {
  name                   = basename(var.k3s_setup_instructions_path)
  storage_account_name   = azurerm_storage_account.scripts.name
  storage_container_name = azurerm_storage_container.scripts.name
  type                   = "Block"
  source                 = var.k3s_setup_instructions_path
  content_md5            = filemd5(var.k3s_setup_instructions_path)
}

# ---------------------------------------------------------------------------
# Optional: Network Watcher + Virtual Network flow logs (to troubleshoot outbound)
# Note: Nested VMs egress through the host; Azure flow logs will show host VM NIC IP.
# ---------------------------------------------------------------------------
resource "azurerm_network_watcher" "nw" {
  count               = var.enable_nsg_flow_logs ? 1 : 0
  name                = "nw-${replace(lower(var.location), " ", "-")}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = var.tags
}

resource "random_string" "flowlogs_suffix" {
  count   = var.enable_nsg_flow_logs ? 1 : 0
  length  = 8
  special = false
  upper   = false
}

resource "azurerm_storage_account" "flowlogs" {
  count                    = var.enable_nsg_flow_logs ? 1 : 0
  name                     = substr("${var.flow_logs_storage_account_prefix}${random_string.flowlogs_suffix[0].result}", 0, 24)
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"
  tags                     = var.tags
}

resource "azurerm_log_analytics_workspace" "flowlogs" {
  count               = (var.enable_nsg_flow_logs && var.enable_traffic_analytics) ? 1 : 0
  name                = "law-flowlogs-${replace(lower(var.location), " ", "-")}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_analytics_retention_days
  tags                = var.tags
}

resource "azurerm_network_watcher_flow_log" "vm_nsg" {
  count                     = var.enable_nsg_flow_logs ? 1 : 0
  name                      = "flowlog-${azurerm_virtual_network.vnet.name}"
  network_watcher_name      = azurerm_network_watcher.nw[0].name
  resource_group_name       = azurerm_resource_group.rg.name
  target_resource_id        = azurerm_virtual_network.vnet.id
  storage_account_id        = azurerm_storage_account.flowlogs[0].id
  enabled                   = true
  version                   = 2

  retention_policy {
    enabled = true
    days    = var.nsg_flow_logs_retention_days
  }

  dynamic "traffic_analytics" {
    for_each = var.enable_traffic_analytics ? [1] : []
    content {
      enabled               = true
      workspace_id          = azurerm_log_analytics_workspace.flowlogs[0].workspace_id
      workspace_region      = azurerm_log_analytics_workspace.flowlogs[0].location
      workspace_resource_id = azurerm_log_analytics_workspace.flowlogs[0].id
      interval_in_minutes   = 10
    }
  }
}

# ---------------------------------------------------------------------------
# VM Extension: Install Hyper-V + deliver setup script with RunOnce
# (Only one CustomScriptExtension allowed per VM, so both tasks are merged.)
# ---------------------------------------------------------------------------
resource "azurerm_virtual_machine_extension" "provision" {
  name                 = "ProvisionHyperVHost"
  virtual_machine_id   = azurerm_windows_virtual_machine.vm.id
  publisher            = "Microsoft.Compute"
  type                 = "CustomScriptExtension"
  type_handler_version = "1.10"

  auto_upgrade_minor_version = true

  # timestamp is a CustomScriptExtension setting: changing its value forces a re-run.
  # We derive an integer from the script's MD5 so the extension re-executes only when
  # the file content changes.
  settings = jsonencode({
    fileUris = [
      "${azurerm_storage_blob.setup_script.url}${data.azurerm_storage_account_blob_container_sas.scripts_read.sas}",
      "${azurerm_storage_blob.voucher_script.url}${data.azurerm_storage_account_blob_container_sas.scripts_read.sas}",
      "${azurerm_storage_blob.bootstrap_script.url}${data.azurerm_storage_account_blob_container_sas.scripts_read.sas}",
      "${azurerm_storage_blob.k3s_arc_script.url}${data.azurerm_storage_account_blob_container_sas.scripts_read.sas}",
      "${azurerm_storage_blob.k3s_join_agent_script.url}${data.azurerm_storage_account_blob_container_sas.scripts_read.sas}",
      "${azurerm_storage_blob.k3s_bootstrap_agents_script.url}${data.azurerm_storage_account_blob_container_sas.scripts_read.sas}",
      "${azurerm_storage_blob.k3s_setup_instructions.url}${data.azurerm_storage_account_blob_container_sas.scripts_read.sas}"
    ]
    timestamp = parseint(substr(md5("${filemd5(var.setup_script_path)}${filemd5(var.voucher_script_path)}${filemd5(var.bootstrap_script_path)}${filemd5(var.k3s_arc_script_path)}${filemd5(var.k3s_join_agent_script_path)}${filemd5(var.k3s_bootstrap_agents_script_path)}${filemd5(var.k3s_setup_instructions_path)}"), 0, 8), 16)
  })

  protected_settings = jsonencode({
    storageAccountName = azurerm_storage_account.scripts.name
    storageAccountKey  = azurerm_storage_account.scripts.primary_access_key
    # Mirrors main.bicep: -File avoids brittle inline -Command quoting in Custom Script Extension.
    # CSE uses cmd.exe: single quotes are literal on args. Use double quotes for URLs and secrets.
    commandToExecute = join("", [
      "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\\",
      basename(var.bootstrap_script_path),
      " -SetupScriptFileName ",
      basename(var.setup_script_path),
      " -VoucherScriptFileName ",
      basename(var.voucher_script_path),
      " -K3sArcScriptFileName ",
      azurerm_storage_blob.k3s_arc_script.name,
      " -K3sJoinAgentScriptFileName ",
      azurerm_storage_blob.k3s_join_agent_script.name,
      " -K3sBootstrapAgentsScriptFileName ",
      azurerm_storage_blob.k3s_bootstrap_agents_script.name,
      " -BootstrapScriptFileName ",
      basename(var.bootstrap_script_path),
      " -K3sSetupInstructionsFileName ",
      azurerm_storage_blob.k3s_setup_instructions.name,
      " -OsImagePackageUrl \"",
      var.os_image_package_url,
      "\" -ConfiguratorAppUrl \"",
      var.configurator_app_url,
      "\" -NestedVmPrefix \"",
      var.nested_vm_prefix,
      "\" -NestedVmCount ",
      tostring(var.nested_vm_count),
      " -AdminUsername \"",
      var.admin_username,
      "\" -AdminPassword \"",
      var.admin_password,
      "\"",
    ])
  })

  tags = var.tags

  depends_on = [
    azurerm_storage_blob.setup_script,
    azurerm_storage_blob.voucher_script,
    azurerm_storage_blob.bootstrap_script,
    azurerm_storage_blob.k3s_arc_script,
    azurerm_storage_blob.k3s_join_agent_script,
    azurerm_storage_blob.k3s_bootstrap_agents_script,
    azurerm_storage_blob.k3s_setup_instructions
  ]
}
