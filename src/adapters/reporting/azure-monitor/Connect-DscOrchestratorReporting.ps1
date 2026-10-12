# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

#Requires -Version 5.1

<#
.SYNOPSIS
    Configures selected virtual machines to send DSC Orchestrator JSONL files to Azure Monitor.

.DESCRIPTION
    Ensures a system-assigned identity and the Azure Monitor Agent extension are
    present, then creates a Data Collection Rule association. Existing agents and
    correct associations are left unchanged.

.PARAMETER ResourceGroupName
    Resource group containing the target virtual machines.

.PARAMETER DcrResourceId
    Full resource ID of the Data Collection Rule to associate with each VM.

.PARAMETER VMNames
    Optional explicit VM names within ResourceGroupName. When omitted, all VMs in
    the resource group are targeted.

.PARAMETER AssociationName
    Name of the per-VM Data Collection Rule association.

.EXAMPLE
    .\Connect-DscOrchestratorReporting.ps1 -ResourceGroupName 'workload-rg' `
        -DcrResourceId '/subscriptions/<subscription-id>/resourceGroups/<monitoring-rg>/providers/Microsoft.Insights/dataCollectionRules/<dcr-name>' `
        -VMNames @('vm01', 'vm02') -WhatIf
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Insights/dataCollectionRules/[^/]+$')]
    [string]$DcrResourceId,

    [Parameter()]
    [AllowNull()]
    [string[]]$VMNames,

    [Parameter()]
    [ValidatePattern('^[a-z0-9][a-z0-9-]{0,62}$')]
    [string]$AssociationName = 'dsc-orchestrator-reporting'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
$ConfirmPreference = [System.Management.Automation.ConfirmImpact]::None

try {
    $context = Get-AzContext -ErrorAction Stop
}
catch {
    throw "Unable to read the current Az context. Authenticate and select the target context before connecting VMs. $($_.Exception.Message)"
}

if ($null -eq $context -or $null -eq $context.Subscription) {
    throw 'No Az context is available. Authenticate and select the target context before connecting VMs.'
}

$vms = @()
if ($PSBoundParameters.ContainsKey('VMNames')) {
    $seenVmNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($vmName in $VMNames) {
        if ([string]::IsNullOrWhiteSpace($vmName)) {
            throw '-VMNames must not contain null, empty, or whitespace-only entries.'
        }
        if (-not $seenVmNames.Add($vmName)) {
            throw "-VMNames contains duplicate entry '$vmName'."
        }

        try {
            $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $vmName -ErrorAction Stop
        }
        catch {
            throw "Failed to retrieve requested VM '$vmName' in resource group '$ResourceGroupName': $($_.Exception.Message)"
        }
        if ($null -eq $vm) {
            throw "Requested VM '$vmName' was not found in resource group '$ResourceGroupName'."
        }
        $vms += $vm
    }
}
else {
    try {
        $vmResults = Get-AzVM -ResourceGroupName $ResourceGroupName -ErrorAction Stop
        if ($null -ne $vmResults) {
            $vms = @($vmResults)
        }
    }
    catch {
        throw "Failed to enumerate VMs in resource group '$ResourceGroupName': $($_.Exception.Message)"
    }
}

Write-Information "Found $($vms.Count) VM(s) in '$ResourceGroupName'."
if ($vms.Count -eq 0) {
    Write-Information "No target VMs found in resource group '$ResourceGroupName'; skipping Azure Monitor configuration."
    return [pscustomobject]@{
        ResourceGroupName = $ResourceGroupName
        DcrResourceId = $DcrResourceId
        VmCount = 0
        IdentityEnabledCount = 0
        AmaInstalledCount = 0
        AssociationCreatedCount = 0
        AssociationExistsCount = 0
        Skipped = $true
    }
}

$identityEnabledCount = 0
$amaInstalledCount = 0
$associationCreatedCount = 0
$associationExistsCount = 0
$skippedCount = 0
$extensionName = 'AzureMonitorWindowsAgent'
$extensionPublisher = 'Microsoft.Azure.Monitor'
$extensionType = 'AzureMonitorWindowsAgent'

foreach ($vmSummary in $vms) {
    $vmName = [string]$vmSummary.Name
    try {
        $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $vmName -ErrorAction Stop
    }
    catch {
        throw "Failed to retrieve VM '$vmName' before configuration: $($_.Exception.Message)"
    }
    if ($null -eq $vm) {
        throw "VM '$vmName' could not be retrieved before configuration."
    }

    $vmResourceId = [string]$vm.Id
    if ([string]::IsNullOrWhiteSpace($vmResourceId)) {
        throw "VM '$vmName' has no resource ID; cannot create a Data Collection Rule association."
    }

    $identity = $vm.Identity
    $identityTypeText = if ($null -ne $identity -and $null -ne $identity.Type) {
        [string]$identity.Type
    }
    else {
        ''
    }
    $identityParts = @($identityTypeText -split '[,\s]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $hasSystemAssignedIdentity = @($identityParts | Where-Object { $_ -ieq 'SystemAssigned' }).Count -gt 0
    $hasUserAssignedIdentity = @($identityParts | Where-Object { $_ -ieq 'UserAssigned' }).Count -gt 0

    if (-not $hasSystemAssignedIdentity) {
        $identityIds = @()
        if ($hasUserAssignedIdentity -and
            $null -ne $identity -and
            $identity.PSObject.Properties.Name -contains 'UserAssignedIdentities' -and
            $null -ne $identity.UserAssignedIdentities) {
            if ($identity.UserAssignedIdentities -is [System.Collections.IDictionary]) {
                $identityIds = @($identity.UserAssignedIdentities.Keys | ForEach-Object { [string]$_ })
            }
            else {
                $identityIds = @($identity.UserAssignedIdentities.PSObject.Properties | ForEach-Object { [string]$_.Name })
            }
        }

        if ($hasUserAssignedIdentity -and $identityIds.Count -eq 0) {
            throw "VM '$vmName' reports a user-assigned identity but its identity IDs could not be read safely."
        }

        $targetIdentityType = if ($hasUserAssignedIdentity) { 'SystemAssignedUserAssigned' } else { 'SystemAssigned' }
        if (-not $PSCmdlet.ShouldProcess("VM '$vmName' in '$ResourceGroupName'", 'enable a system-assigned managed identity')) {
            $skippedCount++
            continue
        }

        $identityParameters = @{
            ResourceGroupName = $ResourceGroupName
            VM = $vm
            IdentityType = $targetIdentityType
            ErrorAction = 'Stop'
        }
        if ($identityIds.Count -gt 0) {
            $identityParameters.IdentityId = [string[]]$identityIds
        }
        Update-AzVM @identityParameters | Out-Null
        $identityEnabledCount++
        Write-Information "Enabled a system-assigned identity on '$vmName'."
    }

    try {
        $extensions = @(Get-AzVMExtension -ResourceGroupName $ResourceGroupName -VMName $vmName -ErrorAction Stop)
    }
    catch {
        throw "Failed to list extensions on VM '$vmName': $($_.Exception.Message)"
    }

    $namedAmaExtensions = @($extensions | Where-Object {
        [string]$_.Name -ieq $extensionName
    })
    $typedAmaExtensions = @($extensions | Where-Object {
        [string]$_.Publisher -ieq $extensionPublisher -and
        [string]$_.ExtensionType -ieq $extensionType
    })

    if ($namedAmaExtensions.Count -gt 0 -and $typedAmaExtensions.Count -eq 0) {
        throw "VM '$vmName' already has an extension named '$extensionName' with a different publisher or type; refusing to overwrite it."
    }
    if ($typedAmaExtensions.Count -gt 1) {
        throw "VM '$vmName' has multiple Azure Monitor Agent extensions; refusing to create an ambiguous configuration."
    }
    if ($typedAmaExtensions.Count -eq 0) {
        if (-not $PSCmdlet.ShouldProcess("VM '$vmName' in '$ResourceGroupName'", 'install the Azure Monitor Agent extension')) {
            $skippedCount++
            continue
        }

        Set-AzVMExtension `
            -ResourceGroupName $ResourceGroupName `
            -VMName $vmName `
            -Name $extensionName `
            -Publisher $extensionPublisher `
            -ExtensionType $extensionType `
            -TypeHandlerVersion '1.0' `
            -EnableAutomaticUpgrade $true `
            -Settings @{} `
            -ErrorAction Stop | Out-Null
        $amaInstalledCount++
        Write-Information "Installed the Azure Monitor Agent extension on '$vmName'."
    }
    else {
        Write-Information "Azure Monitor Agent is already present on '$vmName'; leaving the extension unchanged."
    }

    try {
        $associations = @(Get-AzDataCollectionRuleAssociation -ResourceUri $vmResourceId -ErrorAction Stop)
    }
    catch {
        throw "Failed to list Data Collection Rule associations on VM '$vmName': $($_.Exception.Message)"
    }

    $hasCorrectAssociation = $false
    $nameCollisionId = $null
    foreach ($association in $associations) {
        $associatedDcrId = if ($association.PSObject.Properties.Name -contains 'DataCollectionRuleId') {
            [string]$association.DataCollectionRuleId
        }
        else {
            ''
        }
        $existingAssociationName = if ($association.PSObject.Properties.Name -contains 'Name') {
            [string]$association.Name
        }
        else {
            ''
        }

        if (-not [string]::IsNullOrWhiteSpace($associatedDcrId) -and
            [string]::Equals($associatedDcrId, $DcrResourceId, [System.StringComparison]::OrdinalIgnoreCase)) {
            $hasCorrectAssociation = $true
            break
        }
        if (-not [string]::IsNullOrWhiteSpace($existingAssociationName) -and
            [string]::Equals($existingAssociationName, $AssociationName, [System.StringComparison]::OrdinalIgnoreCase) -and
            -not [string]::IsNullOrWhiteSpace($associatedDcrId)) {
            $nameCollisionId = $associatedDcrId
        }
    }

    if ($hasCorrectAssociation) {
        $associationExistsCount++
        Write-Information "A Data Collection Rule association for '$DcrResourceId' is already present on '$vmName'."
        continue
    }
    if (-not [string]::IsNullOrWhiteSpace($nameCollisionId)) {
        throw "VM '$vmName' already has association '$AssociationName' pointing to '$nameCollisionId'; refusing to replace it."
    }

    if (-not $PSCmdlet.ShouldProcess("VM '$vmName' in '$ResourceGroupName'", "associate Data Collection Rule '$DcrResourceId'")) {
        $skippedCount++
        continue
    }

    New-AzDataCollectionRuleAssociation `
        -AssociationName $AssociationName `
        -ResourceUri $vmResourceId `
        -DataCollectionRuleId $DcrResourceId `
        -Description 'Collect DSC Orchestrator JSONL files with Azure Monitor Agent.' `
        -ErrorAction Stop | Out-Null
    $associationCreatedCount++
    Write-Information "Created the Data Collection Rule association on '$vmName'."
}

[pscustomobject]@{
    ResourceGroupName = $ResourceGroupName
    DcrResourceId = $DcrResourceId
    VmCount = $vms.Count
    IdentityEnabledCount = $identityEnabledCount
    AmaInstalledCount = $amaInstalledCount
    AssociationCreatedCount = $associationCreatedCount
    AssociationExistsCount = $associationExistsCount
    SkippedCount = $skippedCount
    VMNames = @($vms | ForEach-Object { [string]$_.Name })
    Skipped = $false
}
