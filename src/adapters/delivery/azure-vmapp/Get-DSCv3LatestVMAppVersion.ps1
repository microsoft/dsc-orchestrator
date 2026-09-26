<#
.SYNOPSIS
    Gets the latest published VM Application version.

.DESCRIPTION
    Returns the highest semantic version without creating or incrementing a version.
    Throws when no version exists or the latest version is not ready. Azure lookup errors pass through.

.PARAMETER GalleryName
    Compute Gallery to inspect.

.PARAMETER GalleryResourceGroup
    Resource group containing the gallery.

.PARAMETER ApplicationName
    Explicit VM Application name. The value is normalized to an Azure-safe name.

.PARAMETER SubscriptionId
    Optional expected subscription ID. The script validates but does not switch context.

.OUTPUTS
    An object with ApplicationName, Version, and VMAppVersionId properties.
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Azure DevOps recognizes task.setvariable commands only when written to the host stream.')]
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

    [Parameter()]
    [AllowEmptyString()]
    [ValidatePattern('^(?:[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12})?$')]
    [string]$SubscriptionId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Use the same application naming contract as publishing.
. "$PSScriptRoot/ConvertTo-AzureSafeGalleryApplicationName.ps1"
. "$PSScriptRoot/Assert-AzContext.ps1"

$ctx = Assert-AzContext -ExpectedSubscriptionId $SubscriptionId
Write-Verbose "Az context OK (subscription=$($ctx.Subscription.Id), account=$($ctx.Account.Id))."

function Write-OptionalTFBuildVariable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value
    )

    if ($env:TF_BUILD -eq 'True') {
        Write-Host "##vso[task.setvariable variable=$Name;isOutput=true]$Value"
    }
}

$ApplicationName = ConvertTo-AzureSafeGalleryApplicationName -Name $ApplicationName
Write-Information "Gallery             : $GalleryName"
Write-Information "Gallery RG          : $GalleryResourceGroup"
Write-Information "Application Name    : $ApplicationName"

# Missing applications and empty version sets share the publish-first contract.
$publishFirst = "No VM Application version has been published for '$ApplicationName' in gallery '$GalleryName' (resource group '$GalleryResourceGroup'). Publish a version before requesting the latest version."

$applications = @(Get-AzGalleryApplication `
    -GalleryName       $GalleryName `
    -ResourceGroupName $GalleryResourceGroup `
    -ErrorAction       Stop)
$application = $applications |
    Where-Object { $_.Name -eq $applicationName } |
    Select-Object -First 1

if ($null -eq $application) {
    throw $publishFirst
}

Write-Information "Gallery application found (id=$($application.Id))."

$existingVersions = @(Get-AzGalleryApplicationVersion `
    -GalleryName            $GalleryName `
    -ResourceGroupName      $GalleryResourceGroup `
    -GalleryApplicationName $applicationName `
    -ErrorAction            Stop)

# Ignore non-semver versions when selecting the latest package.
$parsedVersions = @()
foreach ($av in $existingVersions) {
    if ($av.Name -match '^(\d+\.\d+\.\d+)$') {
        try {
            $parsedVersions += [pscustomobject]@{ Version = [version]$matches[1]; Object = $av }
            Write-Information "  Found version: $($av.Name)"
        }
        catch {
            Write-Warning "Invalid version format on gallery-application-version: $($av.Name)"
        }
    }
    else {
        Write-Warning "Skipping non-semver gallery-application-version: $($av.Name)"
    }
}

if ($parsedVersions.Count -eq 0) {
    throw $publishFirst
}

$selected = ($parsedVersions | Sort-Object -Property Version -Descending | Select-Object -First 1).Object
$hasProvisioningState = $selected.PSObject.Properties.Name -contains 'ProvisioningState'
$provisioningState = if ($hasProvisioningState) { [string]$selected.ProvisioningState } else { $null }

if (-not $hasProvisioningState -or
    [string]::IsNullOrWhiteSpace($provisioningState) -or
    $provisioningState -cne 'Succeeded') {
    $stateForMessage = if (-not $hasProvisioningState) {
        '<missing>'
    }
    elseif ([string]::IsNullOrWhiteSpace($provisioningState)) {
        '<empty>'
    }
    else {
        $provisioningState
    }
    throw "Selected VM Application version is not ready (application='$ApplicationName', version='$($selected.Name)', ProvisioningState='$stateForMessage'). Ensure publishing completed successfully and retry."
}

Write-Information "Latest published version: $($selected.Name)"
Write-Information "VM Application version ID: $($selected.Id)"

Write-OptionalTFBuildVariable -Name 'VMAppVersionId' -Value ([string]$selected.Id)
Write-OptionalTFBuildVariable -Name 'packageVersion' -Value ([string]$selected.Name)

[pscustomobject]@{
    ApplicationName = $ApplicationName
    Version         = [string]$selected.Name
    VMAppVersionId  = [string]$selected.Id
}
