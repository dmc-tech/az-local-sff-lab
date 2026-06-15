/* ---------------------------------------------------------------------------
   Hyper-V lab host (Windows Server 2025 + Bastion + NAT + optional flow logs)
   Resource-group scoped deployment — parity with main.tf
   Deploy: az deployment group create -g <rg> -f main.bicep -p @main.bicepparam
--------------------------------------------------------------------------- */

targetScope = 'resourceGroup'

@description('Azure region for resources (must match the resource group location unless you intentionally differ).')
param location string = resourceGroup().location

@description('Local administrator username for the Windows VM.')
param adminUsername string = 'azureadmin'

@secure()
@description('Local administrator password for the Windows VM.')
param adminPassword string

@description('Name of the Windows Server VM (≤15 characters for the computer name).')
@maxLength(15)
param vmName string = 'vm-hv-host-1'

@description('Prefix used for nested Hyper-V VMs created by setup.ps1.')
param nestedVmPrefix string = 'NestedVM'

@description('Size of the attached data disk in GB.')
param dataDiskSizeGb int = 1024

@description('Prefix for the scripts storage account name (alphanumeric; combined with a hash to fit 3–24 chars).')
@maxLength(16)
param scriptStorageAccountPrefix string = 'scriptstor'

@description('Prefix for the flow logs storage account when flow logs are enabled.')
@maxLength(16)
param flowLogsStorageAccountPrefix string = 'flowlogstor'

@description('File name for the setup script blob (must match scripts uploaded from repo).')
param setupScriptFileName string = 'setup.ps1'

@description('File name for the voucher script blob.')
param voucherScriptFileName string = 'Get-SffNodeVoucher.ps1'

@description('Blob name for vm-bootstrap.ps1 (must match scripts/vm-bootstrap.ps1 in the repo).')
param bootstrapScriptFileName string = 'vm-bootstrap.ps1'

@description('Blob name for setup-k3s-arc.sh staged on the Hyper-V host for later nested-VM copy.')
param k3sArcScriptFileName string = 'setup_k3s_arc.sh'

@description('Blob name for k3s-join-agent.sh staged on the Hyper-V host for nested VM copy.')
param k3sJoinAgentScriptFileName string = 'k3s-join-agent.sh'

@description('Blob name for bootstrap-k3s-agents.sh staged on the Hyper-V host for nested VM copy.')
param k3sBootstrapAgentsScriptFileName string = 'bootstrap-k3s-agents.sh'

@description('Blob name for K3S-CLUSTER-SETUP.txt on the Hyper-V host (K3s setup instructions).')
param k3sSetupInstructionsFileName string = 'K3S-CLUSTER-SETUP.txt'

@description('URL for the Azure Local OS package or direct ISO URL (passed to setup.ps1).')
param osImagePackageUrl string = 'https://azurestackreleases.download.prss.microsoft.com/dbazure/AzureLocal/OS-Composition-Linux/10.2604.0.3100/roe-10.2604.0.3100.zip'

@description('URL for the Azure Local Configurator app (passed to setup.ps1).')
param configuratorAppUrl string = 'https://azurestackreleases.download.prss.microsoft.com/dbazure/AzureLocal/ConfiguratorApp/10.3372.1.3007/V2/ConfiguratorAppV2-10.3372.1.3007.msix'

@description('Tags applied to supported resources.')
param tags object = {
  ManagedBy: 'Bicep'
}

@description('Deploy Network Watcher and Virtual Network flow logs (v2).')
param enableNsgFlowLogs bool = true

@description('Enable Traffic Analytics for flow logs (requires Log Analytics workspace).')
param enableTrafficAnalytics bool = true

@description('Retention (days) for flow logs in the storage account.')
param nsgFlowLogsRetentionDays int = 7

@description('Retention (days) for the Log Analytics workspace used by Traffic Analytics.')
param logAnalyticsRetentionDays int = 30

@description('Base value for Custom Script Extension timestamp; bump when you change provisioning scripts or need a forced re-run.')
param customScriptTimestamp int = 1

// Paths are relative to this template file (repo root).
var setupScriptPath = 'scripts/setup.ps1'
var voucherScriptPath = 'scripts/Get-SffNodeVoucher.ps1'
var bootstrapScriptPath = 'scripts/vm-bootstrap.ps1'
var k3sArcScriptPath = 'scripts/setup-k3s-arc.sh'
var k3sJoinAgentScriptPath = 'scripts/k3s-join-agent.sh'
var k3sBootstrapAgentsScriptPath = 'scripts/bootstrap-k3s-agents.sh'
var k3sSetupInstructionsPath = 'scripts/K3S-CLUSTER-SETUP.txt'

var setupScriptContent = loadTextContent(setupScriptPath)
var voucherScriptContent = loadTextContent(voucherScriptPath)
var bootstrapScriptContent = loadTextContent(bootstrapScriptPath)
var k3sArcScriptContent = loadTextContent(k3sArcScriptPath)
var k3sJoinAgentScriptContent = loadTextContent(k3sJoinAgentScriptPath)
var k3sBootstrapAgentsScriptContent = loadTextContent(k3sBootstrapAgentsScriptPath)
var k3sSetupInstructionsContent = loadTextContent(k3sSetupInstructionsPath)

var locationSlug = replace(toLower(location), ' ', '-')
var vnetName = 'vnet-hyperv-${locationSlug}'
var vmSubnetPrefix = '10.0.1.0/24'
var bastionSubnetPrefix = '10.0.2.0/26'

var scriptsAccountNameFull = toLower(
  '${scriptStorageAccountPrefix}${uniqueString(resourceGroup().id, deployment().name, 'scripts')}'
)
var scriptsAccountName = substring(scriptsAccountNameFull, 0, min(length(scriptsAccountNameFull), 24))

var flowLogsAccountNameFull = toLower(
  '${flowLogsStorageAccountPrefix}${uniqueString(resourceGroup().id, deployment().name, 'flow')}'
)
var flowLogsAccountName = substring(flowLogsAccountNameFull, 0, min(length(flowLogsAccountNameFull), 24))

var networkWatcherName = 'nw-${locationSlug}'
var flowLogName = 'flowlog-${vnetName}'

var extensionTimestamp = customScriptTimestamp + length(setupScriptContent) + length(voucherScriptContent) + length(bootstrapScriptContent) + length(k3sArcScriptContent) + length(k3sJoinAgentScriptContent) + length(k3sBootstrapAgentsScriptContent) + length(k3sSetupInstructionsContent)

// --- Virtual network ---
resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
  }
}

resource snetBastion 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' = {
  parent: vnet
  name: 'AzureBastionSubnet'
  properties: {
    addressPrefixes: [
      bastionSubnetPrefix
    ]
  }
}

resource pipNat 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: 'pip-nat-gateway'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource natGateway 'Microsoft.Network/natGateways@2023-11-01' = {
  name: 'nat-gateway'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    idleTimeoutInMinutes: 10
    publicIpAddresses: [
      {
        id: pipNat.id
      }
    ]
  }
}

resource snetVm 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' = {
  parent: vnet
  name: 'snet-vm'
  properties: {
    addressPrefixes: [
      vmSubnetPrefix
    ]
    defaultOutboundAccess: false
    natGateway: {
      id: natGateway.id
    }
  }
  dependsOn: [
    snetBastion
  ]
}

resource nsgVm 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'nsg-${vmName}'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-AzureBastion-RDP'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '3389'
          sourceAddressPrefixes: [
            bastionSubnetPrefix
          ]
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

resource pipBastion 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: 'pip-bastion'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource bastion 'Microsoft.Network/bastionHosts@2023-11-01' = {
  name: 'bastion-hyperv-host'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    ipConfigurations: [
      {
        name: 'configuration'
        properties: {
          subnet: {
            id: snetBastion.id
          }
          publicIPAddress: {
            id: pipBastion.id
          }
        }
      }
    ]
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: 'nic-${vmName}'
  location: location
  tags: tags
  properties: {
    networkSecurityGroup: {
      id: nsgVm.id
    }
    ipConfigurations: [
      {
        name: 'internal'
        properties: {
          subnet: {
            id: snetVm.id
          }
          primary: true
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource dataDisk 'Microsoft.Compute/disks@2023-04-02' = {
  name: 'disk-data-${vmName}'
  location: location
  tags: tags
  sku: {
    name: 'Premium_LRS'
  }
  properties: {
    diskSizeGB: dataDiskSizeGb
    creationData: {
      createOption: 'Empty'
    }
  }
}

// --- Scripts storage + seed blobs (Custom Script uses account key + HTTPS blob URLs) ---
// Upload scripts before the VM / extension (Terraform: extension depends_on storage blobs).
resource scriptsAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: scriptsAccountName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    accessTier: 'Hot'
    allowSharedKeyAccess: true // CSE + deployment script uploads use shared key; explicit for policy-safe defaults
  }
}

resource scriptsBlobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  name: 'default'
  parent: scriptsAccount
  properties: {
    isVersioningEnabled: true
  }
}

resource scriptsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  name: 'scripts'
  parent: scriptsBlobService
  properties: {
    publicAccess: 'None'
  }
}

resource seedScripts 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'seed-hyperv-scripts-${uniqueString(resourceGroup().id, deployment().name)}'
  location: location
  kind: 'AzureCLI'
  properties: {
    azCliVersion: '2.63.0'
    retentionInterval: 'PT26H'
    timeout: 'PT30M'
    cleanupPreference: 'OnSuccess'
    environmentVariables: [
      {
        name: 'AZURE_STORAGE_ACCOUNT'
        value: scriptsAccount.name
      }
      {
        name: 'AZURE_STORAGE_KEY'
        secureValue: scriptsAccount.listKeys().keys[0].value
      }
      {
        name: 'SETUP_CONTENT'
        value: setupScriptContent
      }
      {
        name: 'VOUCHER_CONTENT'
        value: voucherScriptContent
      }
      {
        name: 'SETUP_NAME'
        value: setupScriptFileName
      }
      {
        name: 'VOUCHER_NAME'
        value: voucherScriptFileName
      }
      {
        name: 'BOOTSTRAP_CONTENT'
        value: bootstrapScriptContent
      }
      {
        name: 'BOOTSTRAP_NAME'
        value: bootstrapScriptFileName
      }
      {
        name: 'K3S_ARC_CONTENT'
        value: k3sArcScriptContent
      }
      {
        name: 'K3S_ARC_NAME'
        value: k3sArcScriptFileName
      }
      {
        name: 'K3S_JOIN_AGENT_CONTENT'
        value: k3sJoinAgentScriptContent
      }
      {
        name: 'K3S_JOIN_AGENT_NAME'
        value: k3sJoinAgentScriptFileName
      }
      {
        name: 'K3S_BOOTSTRAP_AGENTS_CONTENT'
        value: k3sBootstrapAgentsScriptContent
      }
      {
        name: 'K3S_BOOTSTRAP_AGENTS_NAME'
        value: k3sBootstrapAgentsScriptFileName
      }
      {
        name: 'K3S_SETUP_INSTRUCTIONS_CONTENT'
        value: k3sSetupInstructionsContent
      }
      {
        name: 'K3S_SETUP_INSTRUCTIONS_NAME'
        value: k3sSetupInstructionsFileName
      }
    ]
    scriptContent: '''
set -e
printf '%s' "$SETUP_CONTENT" > /tmp/setup.ps1
printf '%s' "$VOUCHER_CONTENT" > /tmp/voucher.ps1
printf '%s' "$BOOTSTRAP_CONTENT" > /tmp/bootstrap.ps1
printf '%s' "$K3S_ARC_CONTENT" > /tmp/setup_k3s_arc.sh
printf '%s' "$K3S_JOIN_AGENT_CONTENT" > /tmp/k3s_join_agent.sh
printf '%s' "$K3S_BOOTSTRAP_AGENTS_CONTENT" > /tmp/bootstrap_k3s_agents.sh
printf '%s' "$K3S_SETUP_INSTRUCTIONS_CONTENT" > /tmp/k3s_cluster_setup.txt
az storage blob upload --account-name "$AZURE_STORAGE_ACCOUNT" --account-key "$AZURE_STORAGE_KEY" -c scripts -f /tmp/setup.ps1 -n "$SETUP_NAME" --overwrite
az storage blob upload --account-name "$AZURE_STORAGE_ACCOUNT" --account-key "$AZURE_STORAGE_KEY" -c scripts -f /tmp/voucher.ps1 -n "$VOUCHER_NAME" --overwrite
az storage blob upload --account-name "$AZURE_STORAGE_ACCOUNT" --account-key "$AZURE_STORAGE_KEY" -c scripts -f /tmp/bootstrap.ps1 -n "$BOOTSTRAP_NAME" --overwrite
az storage blob upload --account-name "$AZURE_STORAGE_ACCOUNT" --account-key "$AZURE_STORAGE_KEY" -c scripts -f /tmp/setup_k3s_arc.sh -n "$K3S_ARC_NAME" --overwrite
az storage blob upload --account-name "$AZURE_STORAGE_ACCOUNT" --account-key "$AZURE_STORAGE_KEY" -c scripts -f /tmp/k3s_join_agent.sh -n "$K3S_JOIN_AGENT_NAME" --overwrite
az storage blob upload --account-name "$AZURE_STORAGE_ACCOUNT" --account-key "$AZURE_STORAGE_KEY" -c scripts -f /tmp/bootstrap_k3s_agents.sh -n "$K3S_BOOTSTRAP_AGENTS_NAME" --overwrite
az storage blob upload --account-name "$AZURE_STORAGE_ACCOUNT" --account-key "$AZURE_STORAGE_KEY" -c scripts -f /tmp/k3s_cluster_setup.txt -n "$K3S_SETUP_INSTRUCTIONS_NAME" --overwrite
'''
  }
  dependsOn: [
    scriptsContainer
  ]
}

var blobBase = scriptsAccount.properties.primaryEndpoints.blob
var blobBaseNormalized = endsWith(blobBase, '/') ? blobBase : '${blobBase}/'

// Use -File + vm-bootstrap.ps1; long inline -Command strings are fragile and can appear to succeed without running installs.
// Do not put a quote immediately after the -File script name: PowerShell treats .\foo.ps1' as the path and errors (not a .ps1 file).
// CSE invokes commandToExecute via cmd.exe: single quotes are NOT stripped; use spaces for simple names and " for values that may contain & or spaces.
var commandToExecute = join([
  'powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\\'
  bootstrapScriptFileName
  ' -SetupScriptFileName '
  setupScriptFileName
  ' -VoucherScriptFileName '
  voucherScriptFileName
  ' -K3sArcScriptFileName '
  k3sArcScriptFileName
  ' -K3sJoinAgentScriptFileName '
  k3sJoinAgentScriptFileName
  ' -K3sBootstrapAgentsScriptFileName '
  k3sBootstrapAgentsScriptFileName
  ' -BootstrapScriptFileName '
  bootstrapScriptFileName
  ' -K3sSetupInstructionsFileName '
  k3sSetupInstructionsFileName
  ' -OsImagePackageUrl \u{22}'
  osImagePackageUrl
  '\u{22} -ConfiguratorAppUrl \u{22}'
  configuratorAppUrl
  '\u{22} -NestedVmPrefix \u{22}'
  nestedVmPrefix
  '\u{22} -AdminUsername \u{22}'
  adminUsername
  '\u{22} -AdminPassword \u{22}'
  adminPassword
  '\u{22}'
], '')

resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: vmName
  location: location
  tags: tags
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_E32s_v5'
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2025-datacenter'
        version: 'latest'
      }
      osDisk: {
        name: 'osdisk-${vmName}'
        caching: 'ReadWrite'
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
      dataDisks: [
        {
          lun: 0
          createOption: 'Attach'
          managedDisk: {
            id: dataDisk.id
          }
        }
      ]
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
          properties: {
            primary: true
          }
        }
      ]
    }
  }
}

// Same flow as Terraform: CustomScriptExtension installs Hyper-V/DHCP, copies scripts, sets RunOnce + one-time auto-logon, reboots; setup.ps1 runs on next boot.
resource vmExtension 'Microsoft.Compute/virtualMachines/extensions@2024-03-01' = {
  name: 'ProvisionHyperVHost'
  parent: vm
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    // fileUris + storage keys belong in protected settings for private blobs (Learn: custom-script-windows).
    settings: {
      timestamp: extensionTimestamp
    }
    protectedSettings: {
      storageAccountName: scriptsAccount.name
      storageAccountKey: scriptsAccount.listKeys().keys[0].value
      fileUris: [
        '${blobBaseNormalized}scripts/${setupScriptFileName}'
        '${blobBaseNormalized}scripts/${voucherScriptFileName}'
        '${blobBaseNormalized}scripts/${bootstrapScriptFileName}'
        '${blobBaseNormalized}scripts/${k3sArcScriptFileName}'
        '${blobBaseNormalized}scripts/${k3sJoinAgentScriptFileName}'
        '${blobBaseNormalized}scripts/${k3sBootstrapAgentsScriptFileName}'
        '${blobBaseNormalized}scripts/${k3sSetupInstructionsFileName}'
      ]
      commandToExecute: commandToExecute
    }
  }
  dependsOn: [
    seedScripts
  ]
}

// Auto-shutdown: after extension is registered (avoids concurrent VM update races with some subscriptions).
module vmShutdownSchedule 'modules/vm-shutdown.bicep' = {
  name: 'shutdown-${vmName}-${uniqueString(resourceGroup().id, deployment().name)}'
  params: {
    vmName: vmName
    location: location
  }
  dependsOn: [
    vmExtension
  ]
}

// --- Optional: flow logs + Traffic Analytics ---
resource flowLogsStorage 'Microsoft.Storage/storageAccounts@2023-01-01' = if (enableNsgFlowLogs) {
  name: flowLogsAccountName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    accessTier: 'Hot'
  }
}

resource networkWatcher 'Microsoft.Network/networkWatchers@2023-11-01' = if (enableNsgFlowLogs) {
  name: networkWatcherName
  location: location
  tags: tags
  properties: {}
}

// Flow logs without Traffic Analytics only; TA path lives in modules/flow-log-traffic-analytics.bicep (non-null workspace typing).
resource flowLogWithoutTrafficAnalytics 'Microsoft.Network/networkWatchers/flowLogs@2023-11-01' = if (enableNsgFlowLogs && !enableTrafficAnalytics) {
  parent: networkWatcher
  name: flowLogName
  location: location
  tags: tags
  properties: {
    storageId: flowLogsStorage.id
    enabled: true
    retentionPolicy: {
      enabled: true
      days: nsgFlowLogsRetentionDays
    }
    format: {
      type: 'JSON'
      version: 2
    }
    targetResourceId: vnet.id
  }
}

module flowLogTrafficAnalytics 'modules/flow-log-traffic-analytics.bicep' = if (enableNsgFlowLogs && enableTrafficAnalytics) {
  name: 'flow-log-traffic-analytics-${uniqueString(resourceGroup().id, deployment().name)}'
  params: {
    location: location
    locationSlug: locationSlug
    logAnalyticsRetentionDays: logAnalyticsRetentionDays
    tags: tags
    flowLogName: flowLogName
    nsgFlowLogsRetentionDays: nsgFlowLogsRetentionDays
    vnetId: vnet.id
    flowLogsStorageId: flowLogsStorage.id
    networkWatcherName: networkWatcherName
  }
  dependsOn: [
    networkWatcher
  ]
}

// --- Outputs ---
output resourceGroupName string = resourceGroup().name
output vmId string = vm.id
output vmNameOut string = vm.name
output vmPrivateIp string = nic.properties.ipConfigurations[0].properties.privateIPAddress
output bastionHostId string = bastion.id
output natGatewayPublicIp string = pipNat.properties.ipAddress
output vnetNameOut string = vnet.name
output scriptsStorageAccountName string = scriptsAccount.name
output hypervHostNsgId string = nsgVm.id
output nsgFlowLogsEnabled bool = enableNsgFlowLogs
output flowLogsStorageAccountName string = enableNsgFlowLogs ? flowLogsStorage.name : ''
#disable-next-line BCP318
output trafficAnalyticsWorkspaceId string = (enableNsgFlowLogs && enableTrafficAnalytics) ? flowLogTrafficAnalytics.outputs.workspaceId : ''
output hypervReadyNote string = 'Provisioning: deployment script uploads setup.ps1 to storage, then Custom Script Extension installs Hyper-V/DHCP, registers RunOnce + one-time auto-logon, and reboots. After that reboot, setup.ps1 runs automatically (log: C:\\Scripts\\setup.log). Connect via Azure Bastion. To re-run the extension, bump customScriptTimestamp.'
