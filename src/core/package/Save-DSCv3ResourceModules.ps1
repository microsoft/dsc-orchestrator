# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$ConfigPath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$RepositoryName = 'PSGallery',

    [Parameter()]
    [uri]$RepositoryUri,

    [Parameter()]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$LocalPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($RepositoryUri -and $LocalPath) {
    throw 'Specify either RepositoryUri or LocalPath, not both.'
}
if ($RepositoryUri -and -not $RepositoryUri.IsAbsoluteUri) {
    throw "RepositoryUri must be an absolute URI: $RepositoryUri"
}

Import-Module (Join-Path $PSScriptRoot '..\shared\Dsc.OrchestratorConfig.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Modules\Dsc.PackageResourceModules.psm1') -Force
$config = Read-DscOrchestratorConfig -Path $ConfigPath
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
if (-not (Test-Path -LiteralPath $OutputPath -PathType Container)) {
    New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop | Out-Null
}

$effectiveRepositoryName = $RepositoryName
$registeredRepositoryName = $null
$repositoryRegistered = $false
if ($RepositoryUri) {
    $registeredRepositoryName = 'DscOrchestrator-' + [guid]::NewGuid().ToString('N')
    $effectiveRepositoryName = $registeredRepositoryName
}

$stagedModules = [System.Collections.Generic.List[object]]::new()
try {
    foreach ($module in $config.Modules) {
        $moduleRoot = Join-Path $OutputPath $module.Name
        $destination = Join-Path $moduleRoot $module.Version
        if (-not $PSCmdlet.ShouldProcess($destination, "Stage module '$($module.Name)' version $($module.Version)")) {
            continue
        }

        if ($RepositoryUri -and -not $repositoryRegistered) {
            Register-PSRepository `
                -Name $registeredRepositoryName `
                -SourceLocation $RepositoryUri.AbsoluteUri `
                -InstallationPolicy Trusted `
                -ErrorAction Stop
            $repositoryRegistered = $true
        }

        if (Test-Path -LiteralPath $moduleRoot) {
            Remove-Item -LiteralPath $moduleRoot -Recurse -Force -ErrorAction Stop
        }

        if ($LocalPath) {
            $sourceModuleRoot = Join-Path $LocalPath $module.Name
            $sourceVersionFolder = Find-DSCv3ModuleVersionFolder `
                -ModuleRoot $sourceModuleRoot `
                -Version $module.Version
            if ($null -eq $sourceVersionFolder) {
                throw "Local module '$($module.Name)' version '$($module.Version)' was not found in a numerically equivalent version folder under '$sourceModuleRoot'."
            }
            New-Item -ItemType Directory -Path $moduleRoot -Force -ErrorAction Stop | Out-Null
            Copy-Item -LiteralPath $sourceVersionFolder.FullName -Destination $moduleRoot -Recurse -Force -ErrorAction Stop
        }
        else {
            $null = Save-Module `
                -Name $module.Name `
                -RequiredVersion $module.Version `
                -Repository $effectiveRepositoryName `
                -Path $OutputPath `
                -ErrorAction Stop
        }

        $stagedVersionFolder = Find-DSCv3ModuleVersionFolder `
            -ModuleRoot $moduleRoot `
            -Version $module.Version
        if ($null -eq $stagedVersionFolder) {
            throw "Module '$($module.Name)' version '$($module.Version)' was not staged in a numerically equivalent version folder under '$moduleRoot'."
        }
        $destination = $stagedVersionFolder.FullName

        if (-not (Test-Path -LiteralPath $destination -PathType Container)) {
            throw "Module '$($module.Name)' version folder '$($stagedVersionFolder.Name)' was not staged at '$destination'."
        }
        $manifests = @(Get-ChildItem -LiteralPath $destination -Filter '*.psd1' -Recurse -File -ErrorAction Stop)
        if ($manifests.Count -eq 0) {
            throw "Staged module '$($module.Name)' version '$($stagedVersionFolder.Name)' contains no module manifest."
        }

        $stagedModules.Add([pscustomobject]@{
            Name         = $module.Name
            Version      = $stagedVersionFolder.Name
            Source       = if ($LocalPath) { 'LocalPath' } elseif ($RepositoryUri) { $RepositoryUri.AbsoluteUri } else { $RepositoryName }
            ModulePath   = $destination
        })
    }
}
finally {
    if ($repositoryRegistered) {
        Unregister-PSRepository -Name $registeredRepositoryName -ErrorAction Stop
    }
}

@($stagedModules.ToArray())
