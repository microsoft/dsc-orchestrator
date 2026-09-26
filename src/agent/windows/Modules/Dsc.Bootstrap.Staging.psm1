
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Dsc.Security.psm1') -DisableNameChecking -ErrorAction Stop

function Install-ScopedModule {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$DestinationRoot
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        throw "Install-ScopedModule: source is not a directory: $Source"
    }

    $leaf = Split-Path -Path $Source -Leaf
    $dest = Join-Path -Path $DestinationRoot -ChildPath $leaf

    if ($PSCmdlet.ShouldProcess($dest, "Install scoped module '$leaf'")) {
        if (-not (Test-Path -LiteralPath $DestinationRoot)) {
            New-Item -ItemType Directory -Path $DestinationRoot -Force -ErrorAction Stop | Out-Null
        }
        # PS 5.1 Copy-Item nests when destination already exists.
        if (Test-Path -LiteralPath $dest) {
            Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction Stop
        }
        Copy-Item -LiteralPath $Source -Destination $dest -Recurse -Force -ErrorAction Stop
    }
}

function Wait-ForRuntimeFilesUnlocked {
    <#
    .SYNOPSIS
        Waits until no file under the runtime directory is locked, throwing if the timeout elapses.
    .DESCRIPTION
        Probes every file under $Path by opening it exclusively; a handle held by another process
        fails the open. On timeout it throws instead of proceeding, so a locked runtime fails clearly
        rather than as a later Remove-Item error. Callers stop enforcement first; this is the gate.
    .PARAMETER Path
        Runtime directory to probe.
    .PARAMETER TimeoutSeconds
        Maximum seconds to wait for all files to unlock before throwing.
    .PARAMETER FileProvider
        Returns the files to probe under a root. Inject a fixed list for tests.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'The wait-complete message is operator status in the bootstrap transcript.')]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 600)]
        [int]$TimeoutSeconds = 60,

        [ValidateNotNull()]
        [scriptblock]$FileProvider = { param($Root) Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction Stop }
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }

    $waited = 0
    $pollInterval = 2
    while ($true) {
        $locked = $null
        try {
            $filesToProbe = @(& $FileProvider $Path)
        }
        catch {
            throw "Failed to enumerate runtime files under '$Path': $($_.Exception.Message)"
        }
        foreach ($file in $filesToProbe) {
            try {
                $fs = [System.IO.File]::Open($file.FullName, [System.IO.FileMode]::Open,
                    [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
                $fs.Dispose()
            }
            catch {
                $locked = $file.FullName
                break
            }
        }
        if (-not $locked) {
            if ($waited -gt 0) { Write-Host "  Runtime files released after ${waited}s." -ForegroundColor Green }
            return
        }
        if ($waited -ge $TimeoutSeconds) {
            throw "Runtime files under '$Path' still locked after ${TimeoutSeconds}s (e.g. '$locked'); enforcement not fully quiesced."
        }
        Start-Sleep -Seconds $pollInterval
        $waited += $pollInterval
    }
}

function Remove-CurrentPath {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    if ($PSCmdlet.ShouldProcess($Path, 'Remove current runtime content')) {
        Dsc.Security\Remove-DscOrchestratorPathSafely -Path $Path
    }
}

function Replace-CurrentContent {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs','', Justification='Established seam name; CHANGELOG documents rationale.')]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        throw "Replace-CurrentContent: source directory does not exist: $Source"
    }

    $tempDestination = "$Destination.new"
    if (Test-Path -LiteralPath $tempDestination) {
        Remove-CurrentPath -Path $tempDestination
    }

    if ($PSCmdlet.ShouldProcess($Destination, "Replace runtime content from $Source")) {
        Copy-Item -LiteralPath $Source -Destination $tempDestination -Recurse -Force -ErrorAction Stop
        Wait-ForRuntimeFilesUnlocked -Path $Destination -TimeoutSeconds 60 | Out-Null
        Remove-CurrentPath -Path $Destination
        Move-Item -LiteralPath $tempDestination -Destination $Destination -Force -ErrorAction Stop
    }
}

<#
.SYNOPSIS
    Overwrites AllUsers PS5.1 modules from the current package source.

.DESCRIPTION
    For every module directory in $SourceModulesPath, replaces the
    corresponding directory under $TargetModulesPath unconditionally.
    Modules at the target that do NOT exist in source are left untouched.

    This function does NOT read manifests, prove ownership, or compare
    versions. Behaviour is a pure function of the package source contents.

.NOTES
    FILE-LOCK INVARIANT:
    This function MUST be called from a fresh PowerShell process that has
    NOT imported any of the modules it will overwrite. PowerShell 5.1 holds
    file locks on imported .psm1/.psd1 files; forced overwrite will fail
    with "file in use" if the invariant is violated.

    Bootstrap.ps1 satisfies this invariant by calling Sync-AllUsersModules
    before importing any package modules. Do not move this call later in
    the bootstrap sequence, and do not call this function from interactive
    sessions that have imported package modules.

    If the invariant IS violated, the failure is loud (terminating error),
    not silent. This is by design.

.PARAMETER SourceModulesPath
    Path to the extracted package's modules directory. Every child directory
    is treated as a module to sync.

.PARAMETER TargetModulesPath
    AllUsers module path. Defaults to the standard PS5.1 location.
    Modules here that are NOT in source are never touched.
#>
function Sync-AllUsersModules {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'The function synchronizes every staged module; its name is an existing agent module contract.')]
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$SourceModulesPath,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$TargetModulesPath = 'C:\Program Files\WindowsPowerShell\Modules'
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if (-not (Test-Path -LiteralPath $SourceModulesPath -PathType Container)) {
        throw "Sync-AllUsersModules: source modules path does not exist: $SourceModulesPath"
    }

    if (-not (Test-Path -LiteralPath $TargetModulesPath -PathType Container)) {
        if ($PSCmdlet.ShouldProcess($TargetModulesPath, 'Create AllUsers module root')) {
            New-Item -ItemType Directory -Path $TargetModulesPath -Force -ErrorAction Stop | Out-Null
        }
    }

    $sourceModules = @(Get-ChildItem -LiteralPath $SourceModulesPath -Directory -ErrorAction Stop)
    foreach ($module in $sourceModules) {
        $targetPath = Join-Path -Path $TargetModulesPath -ChildPath $module.Name
        if ($PSCmdlet.ShouldProcess($targetPath, "Replace AllUsers module '$($module.Name)'")) {
            if (Test-Path -LiteralPath $targetPath) {
                Remove-Item -LiteralPath $targetPath -Recurse -Force -ErrorAction Stop
            }
            Copy-Item -LiteralPath $module.FullName -Destination $targetPath -Recurse -Force -ErrorAction Stop
            Write-Information "Synced module '$($module.Name)' -> $targetPath"
        }
    }
}

Export-ModuleMember -Function Install-ScopedModule, Wait-ForRuntimeFilesUnlocked, Remove-CurrentPath, Replace-CurrentContent, Sync-AllUsersModules
