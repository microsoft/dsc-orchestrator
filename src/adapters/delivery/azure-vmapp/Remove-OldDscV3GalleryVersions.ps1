# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

#Requires -Version 5.1

<#
.SYNOPSIS
    Removes old unassigned VM Application versions.

.DESCRIPTION
    Retains the newest semantic versions and every version assigned to a VM in the target resource group.
    Pruning fails closed when assignments cannot be read or a versionless app reference exists.
    An empty target resource group skips successfully, and individual deletion failures are non-terminating.

.PARAMETER GalleryName
    Compute Gallery containing the application.

.PARAMETER GalleryResourceGroup
    Resource group of the gallery.

.PARAMETER ApplicationName
    Explicit VM Application name. The value is normalized to an Azure-safe name.

.PARAMETER VMResourceGroupName
    Resource group containing the VMs whose application assignments must be preserved.

.PARAMETER KeepNewestCount
    Number of newest-by-semver versions always retained. Default 2.

.PARAMETER SubscriptionId
    Optional expected subscription ID. The script validates but does not switch context.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$GalleryName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$GalleryResourceGroup,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ApplicationName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$VMResourceGroupName,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 50)]
    [int]$KeepNewestCount = 2,

    [Parameter()]
    [AllowEmptyString()]
    [ValidatePattern('^(?:[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12})?$')]
    [string]$SubscriptionId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
# Avoid interactive confirmation in non-interactive callers while preserving -WhatIf.
$ConfirmPreference = 'None'

. "$PSScriptRoot/ConvertTo-AzureSafeGalleryApplicationName.ps1"
. "$PSScriptRoot/Assert-AzContext.ps1"

function ConvertTo-NormalizedResourceId {
    # Normalize ARM IDs for case-insensitive comparison.
    [CmdletBinding()]
    param([Parameter()][AllowNull()][string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { return $null }
    return $Id.TrimEnd('/').ToLowerInvariant()
}

$ApplicationName = ConvertTo-AzureSafeGalleryApplicationName -Name $ApplicationName

Write-Information "=== Remove-OldDscV3GalleryVersions ==="
$ctx = Assert-AzContext -ExpectedSubscriptionId $SubscriptionId
Write-Verbose "Az context OK (subscription=$($ctx.Subscription.Id), account=$($ctx.Account.Id))."

Write-Information ("Gallery/RG/App     : {0} / {1} / {2}" -f $GalleryName, $GalleryResourceGroup, $ApplicationName)
Write-Information ("VM RG              : {0}" -f $VMResourceGroupName)
Write-Information ("Keep newest        : {0}" -f $KeepNewestCount)

$applications = @(Get-AzGalleryApplication `
    -GalleryName $GalleryName -ResourceGroupName $GalleryResourceGroup -ErrorAction Stop)
$application = $applications |
    Where-Object { $_.Name -eq $ApplicationName } |
    Select-Object -First 1

if ($null -eq $application) {
    Write-Information "Gallery application '$ApplicationName' does not exist; nothing to prune."
    return
}
$appBaseIdNorm = ConvertTo-NormalizedResourceId -Id $application.Id

$versions = @(Get-AzGalleryApplicationVersion `
    -GalleryName $GalleryName -ResourceGroupName $GalleryResourceGroup `
    -GalleryApplicationName $ApplicationName -ErrorAction Stop)

$parsed = [System.Collections.Generic.List[object]]::new()
foreach ($v in $versions) {
    if ($v.Name -match '^\d+\.\d+\.\d+$') {
        $parsed.Add([pscustomobject]@{ Version = [version]$v.Name; Object = $v })
    }
    else {
        Write-Warning "Skipping non-semver gallery-application-version: $($v.Name)"
    }
}
if ($parsed.Count -eq 0) {
    Write-Information "No semver versions found for '$ApplicationName'; nothing to prune."
    return
}

# List first because application profiles require per-VM hydration.
$vmSummaries = @()
try {
    $vmResult = Get-AzVM -ResourceGroupName $VMResourceGroupName -ErrorAction Stop
    if ($null -ne $vmResult) { $vmSummaries = @($vmResult) }
}
catch {
    throw "Failed to enumerate VMs in RG '$VMResourceGroupName' (identity '$($ctx.Account.Id)'): $($_.Exception.Message)"
}

if ($vmSummaries.Count -eq 0) {
    Write-Information "VM resource group '$VMResourceGroupName' has zero VMs; skipping prune."
    return
}
Write-Information "Found $($vmSummaries.Count) VM(s) in '$VMResourceGroupName'."

# Skip all deletions only when VM assignments cannot be determined.
$assignedIdsNorm = [System.Collections.Generic.HashSet[string]]::new()
$readFailure = $false
$baseAppReferenced = $false

foreach ($summary in $vmSummaries) {
    $vm = $null
    try {
        $vm = Get-AzVM -ResourceGroupName $VMResourceGroupName -Name $summary.Name -ErrorAction Stop
    }
    catch {
        Write-Warning "Assigned-set undeterminable: hydrating VM '$($summary.Name)' failed: $($_.Exception.Message)."
        $readFailure = $true
        continue
    }
    if ($null -eq $vm) {
        Write-Warning "Assigned-set undeterminable: Get-AzVM -Name '$($summary.Name)' returned null."
        $readFailure = $true
        continue
    }

    if ($null -eq $vm.ApplicationProfile -or
        -not ($vm.ApplicationProfile.PSObject.Properties.Name -contains 'GalleryApplications') -or
        $null -eq $vm.ApplicationProfile.GalleryApplications) {
        continue   # A missing profile means no assigned versions.
    }

    foreach ($app in $vm.ApplicationProfile.GalleryApplications) {
        if ($null -eq $app -or [string]::IsNullOrWhiteSpace($app.PackageReferenceId)) { continue }
        $refNorm = ConvertTo-NormalizedResourceId -Id $app.PackageReferenceId
        [void]$assignedIdsNorm.Add($refNorm)
        if ($refNorm -eq $appBaseIdNorm) {
            # A versionless reference can resolve to any version.
            $baseAppReferenced = $true
        }
    }
}

if ($readFailure) {
    Write-Warning "One or more VM hydrations failed; the assigned-version set is undeterminable. FAIL CLOSED: skipping all deletions this run."
    return
}

if ($baseAppReferenced) {
    Write-Information "A base-app (version-less) reference to '$ApplicationName' is assigned; keeping all versions (skip prune)."
    return
}

$keepNewest = [System.Collections.Generic.HashSet[string]]::new()
foreach ($p in @($parsed | Sort-Object -Property Version -Descending | Select-Object -First $KeepNewestCount)) {
    [void]$keepNewest.Add($p.Object.Name)
}

$deleted = 0
$failed = 0
$wouldDeleteNames = [System.Collections.Generic.List[string]]::new()
foreach ($p in $parsed) {
    $verName = $p.Object.Name
    if ($keepNewest.Contains($verName)) {
        Write-Information "Keep '$verName' (in newest $KeepNewestCount)."
        continue
    }
    $verIdNorm = ConvertTo-NormalizedResourceId -Id $p.Object.Id
    if ($assignedIdsNorm.Contains($verIdNorm)) {
        Write-Information "Keep '$verName' (assigned to a VM)."
        continue
    }

    $targetDesc = "gallery-application-version '$ApplicationName/$verName' (id=$($p.Object.Id))"
    if (-not $PSCmdlet.ShouldProcess($targetDesc, 'Delete old unassigned gallery-application-version')) {
        if ($WhatIfPreference) {
            $wouldDeleteNames.Add($verName)
        }
        continue
    }
    try {
        Remove-AzGalleryApplicationVersion `
            -GalleryName $GalleryName -ResourceGroupName $GalleryResourceGroup `
            -GalleryApplicationName $ApplicationName -Name $verName -ErrorAction Stop | Out-Null
        Write-Information "Deleted '$verName'."
        $deleted++
    }
    catch {
        # Keep cleanup best-effort after a successful deployment.
        Write-Warning "Failed to delete '$verName': $($_.Exception.Message). Continuing."
        $failed++
    }
}

$kept = $parsed.Count - $wouldDeleteNames.Count - $deleted - $failed
$wouldDeleteList = $wouldDeleteNames -join ', '
Write-Information "=== Prune complete: kept=$kept, wouldDelete=$($wouldDeleteNames.Count) [$wouldDeleteList], deleted=$deleted, failed=$failed ==="
