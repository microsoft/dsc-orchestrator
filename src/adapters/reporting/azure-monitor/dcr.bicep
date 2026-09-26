@description('Full resource ID of the Log Analytics workspace that receives the JSONL streams.')
param workspaceResourceId string

@description('Azure region for the Data Collection Rule and Data Collection Endpoint.')
param location string

@description('Name of the Data Collection Rule.')
param dcrName string

@description('Name of the Data Collection Endpoint.')
param dceName string

@description('Public network access for the Data Collection Endpoint.')
@allowed([
  'Enabled'
  'Disabled'
])
param publicNetworkAccess string = 'Enabled'

@description('Additional tags applied to the Data Collection Endpoint and Data Collection Rule.')
param tags object = {}

@description('Per-table retention in days. Use -1 to keep the workspace default.')
@minValue(-1)
param retentionInDays int = -1

@description('Root directory used by the agent. The JSONL files are read from its logs subdirectory.')
@minLength(1)
param dscRoot string = 'C:\\ProgramData\\DscOrchestrator'

@description('Enable the optional module log table and file source.')
param enableModuleLogs bool = false

@description('Absolute path to the module JSONL file. Required when enableModuleLogs is true.')
param moduleLogPath string = ''

var workspaceIdParts = split(workspaceResourceId, '/')
var workspaceSubscriptionId = workspaceIdParts[2]
var workspaceResourceGroupName = workspaceIdParts[4]
var workspaceName = last(workspaceIdParts)

var runsColumns = [
  { name: 'schema_version', type: 'string' }
  { name: 'run_id', type: 'string' }
  { name: 'TimeGenerated', type: 'datetime' }
  { name: 'Computer', type: 'string' }
  { name: 'group', type: 'string' }
  { name: 'role', type: 'string' }
  { name: 'config_version', type: 'string' }
  { name: 'configuration_hash', type: 'string' }
  { name: 'dsc_exe_version', type: 'string' }
  { name: 'mode', type: 'string' }
  { name: 'trigger', type: 'string' }
  { name: 'outcome', type: 'string' }
  { name: 'total_resources', type: 'int' }
  { name: 'compliant_resources', type: 'int' }
  { name: 'non_compliant_count', type: 'int' }
  { name: 'failed_count', type: 'int' }
  { name: 'skipped_count', type: 'int' }
  { name: 'unevaluated_count', type: 'int' }
  { name: 'had_errors', type: 'boolean' }
  { name: 'test_duration', type: 'string' }
  { name: 'set_duration', type: 'string' }
  { name: 'verify_duration', type: 'string' }
  { name: 'total_duration', type: 'string' }
  { name: 'exit_code', type: 'int' }
  { name: 'error', type: 'string' }
  { name: 'non_compliant_resources', type: 'dynamic' }
  { name: 'erroring_resources', type: 'dynamic' }
  { name: 'reboot_count', type: 'int' }
  { name: 'enforcement_id', type: 'string' }
]

var resourcesColumns = [
  { name: 'schema_version', type: 'string' }
  { name: 'run_id', type: 'string' }
  { name: 'TimeGenerated', type: 'datetime' }
  { name: 'Computer', type: 'string' }
  { name: 'group', type: 'string' }
  { name: 'role', type: 'string' }
  { name: 'config_version', type: 'string' }
  { name: 'configuration_hash', type: 'string' }
  { name: 'fragment', type: 'string' }
  { name: 'trigger', type: 'string' }
  { name: 'phase', type: 'string' }
  { name: 'adapter', type: 'string' }
  { name: 'adapter_instance_name', type: 'string' }
  { name: 'resource_type', type: 'string' }
  { name: 'resource_name', type: 'string' }
  { name: 'in_desired_state', type: 'boolean' }
  { name: 'reasons', type: 'dynamic' }
  { name: 'action', type: 'string' }
  { name: 'event', type: 'string' }
  { name: 'result', type: 'string' }
  { name: 'had_errors', type: 'boolean' }
  { name: 'error_message', type: 'string' }
  { name: 'duration', type: 'string' }
  { name: 'duration_source', type: 'string' }
  { name: 'completion_kind', type: 'string' }
]

var bootstrapColumns = [
  { name: 'TimeGenerated', type: 'datetime' }
  { name: 'Computer', type: 'string' }
  { name: 'config_version', type: 'string' }
  { name: 'stage', type: 'string' }
  { name: 'status', type: 'string' }
  { name: 'message', type: 'string' }
  { name: 'pwsh_source', type: 'string' }
  { name: 'pwsh_path', type: 'string' }
  { name: 'pwsh_version', type: 'string' }
  { name: 'error_type', type: 'string' }
  { name: 'error_message', type: 'string' }
]

var moduleLogsColumns = [
  { name: 'TimeGenerated', type: 'datetime' }
  { name: 'Computer', type: 'string' }
  { name: 'schema_version', type: 'string' }
  { name: 'run_id', type: 'string' }
  { name: 'level', type: 'string' }
  { name: 'app_context', type: 'string' }
  { name: 'module_name', type: 'string' }
  { name: 'function_name', type: 'string' }
  { name: 'message', type: 'string' }
  { name: 'pid', type: 'int' }
]

var logFileSources = concat([
  {
    name: 'dsc-orchestrator-runs'
    streams: [ 'Custom-DscOrchestrator_Runs_CL' ]
    filePatterns: [ '${dscRoot}\\logs\\runs.jsonl' ]
    format: 'json'
  }
  {
    name: 'dsc-orchestrator-resources'
    streams: [ 'Custom-DscOrchestrator_Resources_CL' ]
    filePatterns: [ '${dscRoot}\\logs\\resources.jsonl' ]
    format: 'json'
  }
  {
    name: 'dsc-orchestrator-bootstrap'
    streams: [ 'Custom-DscOrchestrator_Bootstrap_CL' ]
    filePatterns: [ '${dscRoot}\\logs\\bootstrap.jsonl' ]
    format: 'json'
  }
], enableModuleLogs ? [
  {
    name: 'dsc-orchestrator-module-logs'
    streams: [ 'Custom-DscOrchestrator_ModuleLogs_CL' ]
    filePatterns: [ moduleLogPath ]
    format: 'json'
  }
] : [])

var streamDeclarations = union({
  'Custom-DscOrchestrator_Runs_CL': {
    columns: runsColumns
  }
  'Custom-DscOrchestrator_Resources_CL': {
    columns: resourcesColumns
  }
  'Custom-DscOrchestrator_Bootstrap_CL': {
    columns: bootstrapColumns
  }
}, enableModuleLogs ? {
  'Custom-DscOrchestrator_ModuleLogs_CL': {
    columns: moduleLogsColumns
  }
} : {})

var dataFlows = concat([
  {
    streams: [ 'Custom-DscOrchestrator_Runs_CL' ]
    destinations: [ 'dsc-orchestrator-log-analytics' ]
    outputStream: 'Custom-DscOrchestrator_Runs_CL'
  }
  {
    streams: [ 'Custom-DscOrchestrator_Resources_CL' ]
    destinations: [ 'dsc-orchestrator-log-analytics' ]
    outputStream: 'Custom-DscOrchestrator_Resources_CL'
  }
  {
    streams: [ 'Custom-DscOrchestrator_Bootstrap_CL' ]
    destinations: [ 'dsc-orchestrator-log-analytics' ]
    outputStream: 'Custom-DscOrchestrator_Bootstrap_CL'
  }
], enableModuleLogs ? [
  {
    streams: [ 'Custom-DscOrchestrator_ModuleLogs_CL' ]
    destinations: [ 'dsc-orchestrator-log-analytics' ]
    outputStream: 'Custom-DscOrchestrator_ModuleLogs_CL'
  }
] : [])

module workspaceTables './workspace-tables.bicep' = {
  name: 'dsc-orchestrator-workspace-tables'
  scope: resourceGroup(workspaceSubscriptionId, workspaceResourceGroupName)
  params: {
    workspaceName: workspaceName
    retentionInDays: retentionInDays
    enableModuleLogs: enableModuleLogs
    runsColumns: runsColumns
    resourcesColumns: resourcesColumns
    bootstrapColumns: bootstrapColumns
    moduleLogsColumns: moduleLogsColumns
  }
}

resource dce 'Microsoft.Insights/dataCollectionEndpoints@2023-03-11' = {
  name: dceName
  location: location
  tags: tags
  properties: {
    networkAcls: {
      publicNetworkAccess: publicNetworkAccess
    }
  }
}

resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: dcrName
  location: location
  tags: tags
  properties: {
    dataCollectionEndpointId: dce.id
    streamDeclarations: streamDeclarations
    dataSources: {
      logFiles: logFileSources
    }
    destinations: {
      logAnalytics: [
        {
          name: 'dsc-orchestrator-log-analytics'
          workspaceResourceId: workspaceResourceId
        }
      ]
    }
    dataFlows: dataFlows
  }
  dependsOn: [
    workspaceTables
  ]
}

output dcrId string = dcr.id
output dceId string = dce.id
output tableNames array = concat([
  'DscOrchestrator_Runs_CL'
  'DscOrchestrator_Resources_CL'
  'DscOrchestrator_Bootstrap_CL'
], enableModuleLogs ? [
  'DscOrchestrator_ModuleLogs_CL'
] : [])
