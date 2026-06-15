// Log Analytics + VNet flow log with Traffic Analytics (keeps LAW + flow log in one scope so BCP318 does not apply).
targetScope = 'resourceGroup'

param location string
param locationSlug string
param logAnalyticsRetentionDays int
param tags object
param flowLogName string
param nsgFlowLogsRetentionDays int
param vnetId string
param flowLogsStorageId string
param networkWatcherName string

resource networkWatcher 'Microsoft.Network/networkWatchers@2023-11-01' existing = {
  name: networkWatcherName
}

resource flowLogWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'law-flowlogs-${locationSlug}'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: logAnalyticsRetentionDays
  }
}

resource flowLog 'Microsoft.Network/networkWatchers/flowLogs@2023-11-01' = {
  parent: networkWatcher
  name: flowLogName
  location: location
  tags: tags
  properties: {
    storageId: flowLogsStorageId
    enabled: true
    retentionPolicy: {
      enabled: true
      days: nsgFlowLogsRetentionDays
    }
    format: {
      type: 'JSON'
      version: 2
    }
    targetResourceId: vnetId
    flowAnalyticsConfiguration: {
      networkWatcherFlowAnalyticsConfiguration: {
        enabled: true
        workspaceResourceId: flowLogWorkspace.id
        workspaceId: flowLogWorkspace.properties.customerId
        workspaceRegion: flowLogWorkspace.location
      }
    }
  }
}

output workspaceId string = flowLogWorkspace.id
