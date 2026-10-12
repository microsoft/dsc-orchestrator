# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

#Requires -Version 5.1

<#
.SYNOPSIS
    Publishes a package and VM Application version into an Azure Compute Gallery.

.DESCRIPTION
    Uploads a caller-provided package to blob storage,
    ensures gallery-application parent exists, then creates (or skips/recreates) version.

    Design choices: Az.Compute cmdlets only (no REST fallback that masks idempotency bugs);
    -IfExists {Fail|Skip|Force} controls version collision handling (default Fail = immutable);
    never silently switches Az context; AAD-only upload (no SAS/shared-key); application
    identity is supplied explicitly; ShouldProcess supports safe previews and confirmations.

    Use compatible Az.Accounts, Az.Compute, Az.Resources, and Az.Storage modules; see README.

.PARAMETER PackagePath
    Path to the core builder ZIP. The root manifest version must match -Version.

.PARAMETER StorageAccountName
    Storage account name (3-24 lowercase alnum).

.PARAMETER StorageAccountResourceGroup
    Resource group of the storage account.

.PARAMETER ContainerName
    Blob container inside StorageAccountName.

.PARAMETER GalleryName
    Target Azure Compute Gallery name.

.PARAMETER GalleryResourceGroup
    Compute gallery resource group. If empty, defaults to StorageAccountResourceGroup.

.PARAMETER ApplicationName
    Explicit gallery application name. The value is normalized to an Azure-safe name.

.PARAMETER Version
    Explicit manifest version in major.minor.patch form.

.PARAMETER Location
    Azure source region for the gallery application version. Detected VM regions become
    replication target regions.

.PARAMETER DscRoot
    Install root passed to the packaged VM Application entry point. Defaults to the
    Windows agent's C:\ProgramData\DscOrchestrator root.

.PARAMETER VMResourceGroupName
    Optional resource group whose VM locations are used as replication targets. An empty
    resource group falls back to Location only.

.PARAMETER TargetRegions
    Explicit list of Azure regions for ACG replication targets. When supplied (non-empty),
    bypasses VM location discovery. Source region (Location) is always added implicitly.

.PARAMETER SubscriptionId
    If provided, Az context subscription must match or script aborts. Never switches context.

.PARAMETER IfExists
    Handle pre-existing version: Fail (default, safe), Skip (idempotent), Force (destructive).

.PARAMETER AllowSharedKeyFallback
    Deprecated. VM Application publish fails if supplied.

.EXAMPLE
    .\Publish-DSCv3VMApp.ps1 -PackagePath .\package.zip -StorageAccountName sampleacct `
        -StorageAccountResourceGroup storage-rg -ContainerName packages `
        -GalleryName gallery -GalleryResourceGroup gallery-rg -ApplicationName sample-agent `
        -Version 1.4.0 -Location eastus -IfExists Skip

.EXAMPLE
    # Force-recreate an existing version (destructive)
    Publish-DSCv3VMApp.ps1 @params -IfExists Force -Confirm:$false
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Azure DevOps recognizes task.setvariable commands only when written to the host stream.')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [ValidateScript({
        if (-not (Test-Path -LiteralPath $_ -PathType Leaf)) {
            throw "PackagePath not found or not a file: $_"
        }
        if ([System.IO.Path]::GetExtension($_) -ne '.zip') {
            throw "PackagePath must be a .zip file: $_"
        }
        $true
    })]
    [string]$PackagePath,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9]{3,24}$')]
    [string]$StorageAccountName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$StorageAccountResourceGroup,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9]([a-z0-9-]{1,61}[a-z0-9])?$')]
    [string]$ContainerName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$GalleryName,

    # Allow an empty value so the body can default the gallery resource group to the storage resource group.
    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$GalleryResourceGroup = '',

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ApplicationName,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Location,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$DscRoot = 'C:\ProgramData\DscOrchestrator',

    # Auto-detects VM regions from this RG -> ACG replication targets.
    # Source region stays pinned to $Location (storage account region) for blob read.
    [Parameter()]
    [AllowEmptyString()]
    [string]$VMResourceGroupName = '',

    # Explicit ACG replication targets. When non-empty, overrides VM auto-detect entirely.
    # Source region ($Location) is always added if missing.
    [Parameter()]
    [AllowNull()]
    [AllowEmptyCollection()]
    [string[]]$TargetRegions = @(),

    [Parameter()]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [Parameter()]
    [ValidateSet('Fail', 'Skip', 'Force')]
    [string]$IfExists = 'Fail',

    [Parameter()]
    [switch]$AllowSharedKeyFallback
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
$ConfirmPreference = 'None'  # Non-interactive agents; -WhatIf still works

# Dot-source shared name normalization used by all adapter entry points.
. "$PSScriptRoot/ConvertTo-AzureSafeGalleryApplicationName.ps1"
. "$PSScriptRoot/Assert-AzContext.ps1"

# Aggregate manifest loads Dsc.Publish.* nested modules into this scope.
Import-Module (Join-Path $PSScriptRoot 'Modules\Dsc.Publish.psd1') -DisableNameChecking

function Get-VMAppPackageManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        foreach ($entryName in @(
                'manifest.json',
                'Install-VmApplicationPackage.ps1',
                'bootstrap.ps1',
                'remove.ps1'
            )) {
            if ($null -eq $archive.GetEntry($entryName)) {
                throw "Package archive '$Path' is missing root entry '$entryName'."
            }
        }

        $manifestEntry = $archive.GetEntry('manifest.json')
        $reader = [System.IO.StreamReader]::new($manifestEntry.Open())
        try {
            $manifestText = $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $archive.Dispose()
    }

    $manifest = ConvertFrom-Json -InputObject $manifestText -ErrorAction Stop
    foreach ($propertyName in @('schemaVersion', 'name', 'version')) {
        if ($manifest.PSObject.Properties.Name -notcontains $propertyName) {
            throw "Package manifest '$Path' is missing required property '$propertyName'."
        }
    }
    if ([string]$manifest.schemaVersion -ne '1.0') {
        throw "Package manifest schema '$($manifest.schemaVersion)' is not supported; expected '1.0'."
    }
    if ([string]$manifest.name -notmatch '^[A-Za-z0-9._-]+$') {
        throw "Package manifest name '$($manifest.name)' is invalid."
    }
    if ([string]$manifest.version -notmatch '^\d+\.\d+\.\d+$') {
        throw "Package manifest version '$($manifest.version)' is not numeric major.minor.patch."
    }

    return $manifest
}

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

function Get-VMAppPublishResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ApplicationName,
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$VersionId,
        [Parameter(Mandatory = $true)][ValidateSet('published', 'skipped')][string]$Action,
        [Parameter()][AllowNull()][string]$BlobUri
    )

    Write-OptionalTFBuildVariable -Name 'VMAppVersionId' -Value $VersionId
    Write-OptionalTFBuildVariable -Name 'VMAppVersion' -Value $Version
    Write-OptionalTFBuildVariable -Name 'VMAppPublishAction' -Value $Action

    [pscustomobject]@{
        ApplicationName = $ApplicationName
        Version         = $Version
        VMAppVersionId  = $VersionId
        Action          = $Action
        BlobUri         = $BlobUri
    }
}

Write-Information "=== Publish-DSCv3VMApp ==="

if ($AllowSharedKeyFallback.IsPresent) {
    throw "-AllowSharedKeyFallback is not supported. Grant AAD storage RBAC to the current identity and Compute Gallery managed identity instead."
}

if ([string]::IsNullOrWhiteSpace($GalleryResourceGroup)) {
    Write-Information ("GalleryResourceGroup empty; coalescing to StorageAccountResourceGroup '{0}'." -f $StorageAccountResourceGroup)
    $GalleryResourceGroup = $StorageAccountResourceGroup
}

$ApplicationName = ConvertTo-AzureSafeGalleryApplicationName -Name $ApplicationName
$packageManifest = Get-VMAppPackageManifest -Path $PackagePath
if ([string]$packageManifest.version -ne $Version) {
    throw "Requested version '$Version' does not match package manifest version '$($packageManifest.version)'."
}
$packageFileName = [System.IO.Path]::GetFileName($PackagePath)

Write-Information ("PackagePath                 : {0}" -f $PackagePath)
Write-Information ("Package manifest            : {0} / {1}" -f $packageManifest.name, $packageManifest.version)
Write-Information ("VM Application package file : {0}" -f $packageFileName)
Write-Information ("StorageAccount/RG/Container : {0} / {1} / {2}" -f $StorageAccountName, $StorageAccountResourceGroup, $ContainerName)
Write-Information ("Gallery/RG/App/Version      : {0} / {1} / {2} / {3}" -f $GalleryName, $GalleryResourceGroup, $ApplicationName, $Version)
Write-Information ("Location                    : {0}" -f $Location)
Write-Information ("DscRoot                     : {0}" -f $DscRoot)
Write-Information ("IfExists                    : {0}" -f $IfExists)

$ctx = Assert-AzContext -ExpectedSubscriptionId $SubscriptionId
$effectiveSubscriptionId = $ctx.Subscription.Id
Write-Verbose "Az context OK (subscription=$effectiveSubscriptionId, account=$($ctx.Account.Id))."

# Auto-detect target regions from VMs in the selected resource group. Source region stays
# pinned to -Location (the storage account region) so blob read succeeds.
# Explicit -TargetRegions overrides VM location discovery.
$explicitTargets = @($TargetRegions | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($explicitTargets.Count -gt 0) {
    Write-Information "Explicit -TargetRegions supplied; bypassing VM auto-detect. Targets: $($explicitTargets -join ', ')."
    $TargetRegions = $explicitTargets
}
elseif (-not [string]::IsNullOrWhiteSpace($VMResourceGroupName)) {
    $vms = @(Get-AzVM -ResourceGroupName $VMResourceGroupName -ErrorAction Stop)
    if ($vms.Count -eq 0) {
        Write-Information "VM resource group '$VMResourceGroupName' is empty; version will replicate to source region '$Location' only."
        $TargetRegions = @($Location)
    }
    else {
        $vmLocations = @($vms | Select-Object -ExpandProperty Location | Sort-Object -Unique)
        Write-Information "Detected VM region(s): $($vmLocations -join ', '). ACG version source='$Location', targets=$($vmLocations -join ', ')."
        $TargetRegions = @($vmLocations)
    }
}
else {
    Write-Information "No VM RG provided; ACG version will replicate to source region '$Location' only."
    $TargetRegions = @($Location)
}

# Ensure source region is always in target regions (ACG requirement)
if ($TargetRegions -notcontains $Location) {
    Write-Information "Adding source region '$Location' to target regions (required for ACG)."
    $TargetRegions = @($Location) + $TargetRegions
}

Assert-GalleryManagedIdentityBlobAccess `
    -GalleryName                 $GalleryName `
    -GalleryResourceGroup        $GalleryResourceGroup `
    -StorageAccountName          $StorageAccountName `
    -StorageAccountResourceGroup $StorageAccountResourceGroup `
    -ContainerName               $ContainerName

# Idempotency gate (checked BEFORE upload so -IfExists Skip costs no blob traffic)
$existingVersion = Get-ExistingGalleryApplicationVersion `
    -GalleryName       $GalleryName `
    -ResourceGroupName $GalleryResourceGroup `
    -ApplicationName   $ApplicationName `
    -Version           $Version

if ($null -ne $existingVersion) {
    Write-Information "Gallery-application-version '$ApplicationName/$Version' already exists (id=$($existingVersion.Id))."
    switch ($IfExists) {
        'Fail' {
            throw "Gallery-application-version '$ApplicationName/$Version' already exists. Gallery application versions are immutable. Re-run with -IfExists Skip for idempotent behavior, or -IfExists Force to delete and recreate (destructive). Existing id: $($existingVersion.Id)"
        }
        'Skip' {
            Write-Information "IfExists=Skip: returning the existing version without uploading the package."
            return (Get-VMAppPublishResult `
                -ApplicationName $ApplicationName `
                -Version $Version `
                -VersionId ([string]$existingVersion.Id) `
                -Action 'skipped' `
                -BlobUri $null)
        }
        'Force' {
            $target = "gallery-application-version '$ApplicationName/$Version' (id=$($existingVersion.Id))"
            if (-not $PSCmdlet.ShouldProcess($target, 'Delete existing version before recreate (-IfExists Force)')) {
                throw "IfExists=Force but deletion was not confirmed. Aborting to avoid partial state."
            }
            Write-Warning "IfExists=Force: deleting existing $target."
            Remove-AzGalleryApplicationVersion `
                -GalleryName            $GalleryName `
                -ResourceGroupName      $GalleryResourceGroup `
                -GalleryApplicationName $ApplicationName `
                -Name                   $Version `
                -ErrorAction            Stop | Out-Null
            Write-Information "Existing version deleted; proceeding to upload and recreate."
        }
    }
}

$blobName = "$ApplicationName-$Version.zip"
$uploadTarget = "blob $StorageAccountName/$ContainerName/$blobName"
Write-Verbose "Blob name: $blobName"

if ($PSCmdlet.ShouldProcess($uploadTarget, 'Upload package')) {
    $blobUri = Invoke-PackageUpload `
        -LocalPath              $PackagePath `
        -StorageAccount         $StorageAccountName `
        -StorageResourceGroup   $StorageAccountResourceGroup `
        -Container              $ContainerName `
        -Blob                   $blobName

    Test-BlobUri -Uri $blobUri -ExpectedStorageAccount $StorageAccountName -ExpectedContainer $ContainerName
    Write-Information "Package uploaded: $blobUri"
}
else {
    $blobUri = "https://$StorageAccountName.blob.core.windows.net/$ContainerName/$blobName"
    Write-Warning "WhatIf: skipped upload; using synthetic URI $blobUri for preview."
}

$null = Ensure-GalleryApplication `
    -GalleryName       $GalleryName `
    -ResourceGroupName $GalleryResourceGroup `
    -ApplicationName   $ApplicationName `
    -Location          $Location `
    -ExpectedTags      $null

$appVersion = $null
try {
    $appVersion = New-DscV3GalleryApplicationVersion `
        -GalleryName       $GalleryName `
        -ResourceGroupName $GalleryResourceGroup `
        -ApplicationName   $ApplicationName `
        -Version           $Version `
        -Location          $Location `
        -BlobUri           $blobUri `
        -PackageFileName   $packageFileName `
        -DscRoot           $DscRoot `
        -TargetRegions     $TargetRegions
}
catch {
    throw ("Failed to create gallery-application-version '{0}/{1}' in {2}/{3}: {4}. Remediation hints: (1) verify the current identity '{5}' has Compute Gallery 'Contributor' (or Gallery Application Version write) on '{2}'; (2) verify the package blob '{6}' is reachable and the media link is correct; (3) re-run with -Verbose for full SDK output." -f `
        $ApplicationName, $Version, $GalleryResourceGroup, $GalleryName, $_.Exception.Message, $ctx.Account.Id, $blobUri)
}

$appVersionId = $null
if ($null -ne $appVersion -and $appVersion.PSObject.Properties.Name -contains 'Id') {
    $appVersionId = $appVersion.Id
}
if ([string]::IsNullOrEmpty($appVersionId)) {
    $appVersionId = "/subscriptions/$effectiveSubscriptionId/resourceGroups/$GalleryResourceGroup/providers/Microsoft.Compute/galleries/$GalleryName/applications/$ApplicationName/versions/$Version"
    Write-Warning "Synthetic appVersionId (WhatIf): $appVersionId"
}

Write-Information "=== Publish complete ==="
Write-Information ("Version ID : {0}" -f $appVersionId)
Write-Information ("Version    : {0}" -f $Version)

Get-VMAppPublishResult `
    -ApplicationName $ApplicationName `
    -Version $Version `
    -VersionId $appVersionId `
    -Action 'published' `
    -BlobUri $blobUri
