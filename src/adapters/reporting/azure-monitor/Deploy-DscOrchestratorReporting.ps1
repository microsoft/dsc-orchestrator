# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

#Requires -Version 5.1

<#
.SYNOPSIS
    Deploys DSC Orchestrator Azure Monitor reporting tables, endpoint, and collection rule.

.DESCRIPTION
    Uses the caller's active Az PowerShell context and the checked-in ARM template.
    The script never signs in or changes subscriptions.

.PARAMETER ResourceGroupName
    Resource group where the endpoint and collection rule will be deployed.

.PARAMETER WorkspaceResourceId
    Full resource ID of the Log Analytics workspace that receives the streams.

.PARAMETER Location
    Azure region for the endpoint and collection rule.

.PARAMETER DcrName
    Name of the Data Collection Rule.

.PARAMETER DceName
    Name of the Data Collection Endpoint.

.PARAMETER PublicNetworkAccess
    Public network access setting for the endpoint.

.PARAMETER Tags
    Additional tags applied to the endpoint and collection rule.

.PARAMETER RetentionInDays
    Per-table retention in days. Use -1 to keep the workspace default.

.PARAMETER DscRoot
    Agent root directory used to build the JSONL file patterns.

.PARAMETER EnableModuleLogs
    Creates and configures the optional module log table and source.

.PARAMETER ModuleLogPath
    Absolute path to the module JSONL file. Required when module logs are enabled.

.EXAMPLE
    .\Deploy-DscOrchestratorReporting.ps1 -ResourceGroupName 'monitoring-rg' `
        -WorkspaceResourceId '/subscriptions/<subscription-id>/resourceGroups/<workspace-rg>/providers/Microsoft.OperationalInsights/workspaces/<workspace>' `
        -Location '<region>' -DcrName '<dcr-name>' -DceName '<dce-name>' -WhatIf
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.OperationalInsights/workspaces/[^/]+$')]
    [string]$WorkspaceResourceId,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Location,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DcrName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DceName,

    [Parameter()]
    [ValidateSet('Enabled', 'Disabled')]
    [string]$PublicNetworkAccess = 'Enabled',

    [Parameter()]
    [hashtable]$Tags = @{},

    [Parameter()]
    [ValidateRange(-1, 3653)]
    [int]$RetentionInDays = -1,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$DscRoot = 'C:\ProgramData\DscOrchestrator',

    [Parameter()]
    [switch]$EnableModuleLogs,

    [Parameter()]
    [AllowEmptyString()]
    [string]$ModuleLogPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
$ConfirmPreference = [System.Management.Automation.ConfirmImpact]::None

if ($EnableModuleLogs -and [string]::IsNullOrWhiteSpace($ModuleLogPath)) {
    throw '-ModuleLogPath is required when -EnableModuleLogs is specified.'
}

try {
    $context = Get-AzContext -ErrorAction Stop
}
catch {
    throw "Unable to read the current Az context. Authenticate and select the target context before deployment. $($_.Exception.Message)"
}

if ($null -eq $context -or $null -eq $context.Subscription) {
    throw 'No Az context is available. Authenticate and select the target context before deployment.'
}

$templatePath = Join-Path $PSScriptRoot 'dcr.json'
if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
    throw "Compiled ARM template not found: $templatePath"
}

$templateParameters = @{
    workspaceResourceId = $WorkspaceResourceId
    location = $Location
    dcrName = $DcrName
    dceName = $DceName
    publicNetworkAccess = $PublicNetworkAccess
    tags = $Tags
    retentionInDays = $RetentionInDays
    dscRoot = $DscRoot
    enableModuleLogs = [bool]$EnableModuleLogs
    moduleLogPath = $ModuleLogPath
}

Write-Information "Deploying DSC Orchestrator Azure Monitor reporting resources to '$ResourceGroupName' using the current Az context."
if (-not $PSCmdlet.ShouldProcess("resource group '$ResourceGroupName'", "deploy reporting rule '$DcrName'")) {
    return
}

$deploymentParameters = @{
    ResourceGroupName = $ResourceGroupName
    Name = $DcrName
    Mode = 'Incremental'
    TemplateFile = $templatePath
    TemplateParameterObject = $templateParameters
    ErrorAction = 'Stop'
}

$deployment = New-AzResourceGroupDeployment @deploymentParameters
if ($null -eq $deployment -or $null -eq $deployment.Outputs) {
    throw "Deployment to resource group '$ResourceGroupName' returned no outputs."
}

foreach ($outputName in @('dcrId', 'dceId', 'tableNames')) {
    if (-not $deployment.Outputs.ContainsKey($outputName) -or $null -eq $deployment.Outputs[$outputName].Value) {
        throw "Deployment output '$outputName' is missing. Check the deployment result in resource group '$ResourceGroupName'."
    }
}

[pscustomobject]@{
    DcrId = [string]$deployment.Outputs['dcrId'].Value
    DceId = [string]$deployment.Outputs['dceId'].Value
    TableNames = @($deployment.Outputs['tableNames'].Value)
}
