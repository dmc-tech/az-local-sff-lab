// Nested ARM: at RG scope the schedule name is one segment shutdown-computevm-{vm}; VM link is targetResourceId (see arm-templates/vm-shutdown.arm.json).
targetScope = 'resourceGroup'

@description('Virtual machine name (same as Microsoft.Compute/virtualMachines name).')
param vmName string

@description('Azure region for the schedule resource.')
param location string

var shutdownTemplate = loadJsonContent('../arm-templates/vm-shutdown.arm.json')

// Nested ARM is required for the DevTestLab compound resource name; parent uses a module instead of inline deployment.
#disable-next-line no-deployments-resources
resource shutdownScheduleDeployment 'Microsoft.Resources/deployments@2022-09-01' = {
  name: 'shutdown-tpl-${vmName}'
  properties: {
    mode: 'Incremental'
    template: shutdownTemplate
    parameters: {
      vmName: {
        value: vmName
      }
      location: {
        value: location
      }
    }
  }
}
