@description('Name of the existing Log Analytics workspace.')
param workspaceName string

@description('Per-table retention in days. Use -1 to keep the workspace default.')
@minValue(-1)
param retentionInDays int

@description('Whether to create the optional module log table.')
param enableModuleLogs bool

@description('Run table column schema.')
param runsColumns array

@description('Resource table column schema.')
param resourcesColumns array

@description('Bootstrap table column schema.')
param bootstrapColumns array

@description('Optional module log table column schema.')
param moduleLogsColumns array

resource workspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' existing = {
  name: workspaceName
}

resource runsTable 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: workspace
  name: 'DscOrchestrator_Runs_CL'
  properties: {
    retentionInDays: retentionInDays == -1 ? null : retentionInDays
    schema: {
      name: 'DscOrchestrator_Runs_CL'
      columns: runsColumns
    }
  }
}

resource resourcesTable 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: workspace
  name: 'DscOrchestrator_Resources_CL'
  properties: {
    retentionInDays: retentionInDays == -1 ? null : retentionInDays
    schema: {
      name: 'DscOrchestrator_Resources_CL'
      columns: resourcesColumns
    }
  }
}

resource bootstrapTable 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: workspace
  name: 'DscOrchestrator_Bootstrap_CL'
  properties: {
    retentionInDays: retentionInDays == -1 ? null : retentionInDays
    schema: {
      name: 'DscOrchestrator_Bootstrap_CL'
      columns: bootstrapColumns
    }
  }
}

resource moduleLogsTable 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = if (enableModuleLogs) {
  parent: workspace
  name: 'DscOrchestrator_ModuleLogs_CL'
  properties: {
    retentionInDays: retentionInDays == -1 ? null : retentionInDays
    schema: {
      name: 'DscOrchestrator_ModuleLogs_CL'
      columns: moduleLogsColumns
    }
  }
}
