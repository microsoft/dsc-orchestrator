<#
.SYNOPSIS
    Builds a complete DSC Orchestrator package from dsc-orchestrator.config.json.
.DESCRIPTION
    Prepares fragments, stages declared resource modules, downloads and verifies the
    pinned DSC and PowerShell runtimes, and creates the package ZIP.
.PARAMETER ConfigPath
    Path to dsc-orchestrator.config.json. Relative paths resolve from the current directory.
.PARAMETER OutputPath
    Directory for the final package ZIP. Relative paths resolve from the current directory.
.PARAMETER RepositoryName
    Registered PowerShell repository used to stage resource modules. Defaults to PSGallery.
.PARAMETER RepositoryUri
    Optional temporary repository URI used to stage resource modules.
.PARAMETER LocalPath
    Optional local module tree laid out as <ModuleName>\<Version>\...
#>
[CmdletBinding()]
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
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'Package building requires PowerShell 7 (pwsh) for pinned DSC fragment schema validation. Run this script with pwsh.'
}
if (-not (Get-Module -Name 'powershell-yaml') -and
    -not (Get-Module -ListAvailable -Name 'powershell-yaml' | Select-Object -First 1)) {
    throw "The build-time powershell-yaml module is missing. Install it in this pwsh environment with: Install-Module -Name powershell-yaml -Scope CurrentUser -Repository PSGallery"
}

$ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
if (-not (Test-Path -LiteralPath $OutputPath -PathType Container)) {
    New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop | Out-Null
}

$workRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('dsc-orchestrator-build-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workRoot -Force -ErrorAction Stop | Out-Null

try {
    $preparedPath = Join-Path $workRoot 'prepared'
    $modulesPath = Join-Path $workRoot 'modules'
    $toolsPath = Join-Path $workRoot 'tools'

    $prepared = & (Join-Path $PSScriptRoot '..\src\core\compose\New-DSCv3PreparedFragments.ps1') `
        -ConfigPath $ConfigPath `
        -OutputPath $preparedPath

    $moduleStagingArgs = @{
        ConfigPath = $ConfigPath
        OutputPath = $modulesPath
        RepositoryName = $RepositoryName
    }
    if ($RepositoryUri) { $moduleStagingArgs.RepositoryUri = $RepositoryUri }
    if ($LocalPath) { $moduleStagingArgs.LocalPath = [System.IO.Path]::GetFullPath($LocalPath) }
    $null = & (Join-Path $PSScriptRoot '..\src\core\package\Save-DSCv3ResourceModules.ps1') @moduleStagingArgs

    $dsc = & (Join-Path $PSScriptRoot '..\src\core\package\Get-DSCv3Tool.ps1') `
        -ToolName 'dsc' `
        -OutputDirectory $toolsPath
    $pwsh = & (Join-Path $PSScriptRoot '..\src\core\package\Get-DSCv3Tool.ps1') `
        -ToolName 'pwsh' `
        -OutputDirectory $toolsPath

    $package = & (Join-Path $PSScriptRoot '..\src\core\package\New-DSCv3Package.ps1') `
        -PreparedFragmentsPath $prepared.OutputPath `
        -ModulesPath $modulesPath `
        -DscExePath $dsc.BinaryPath `
        -PwshRuntimePath $pwsh.ExtractPath `
        -OutputDirectory $OutputPath

    return $package
}
finally {
    if (Test-Path -LiteralPath $workRoot -PathType Container) {
        Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction Stop
    }
}
