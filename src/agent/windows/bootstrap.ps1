
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Bootstrap progress is captured by the installation transcript and complements the structured bootstrap JSONL record.')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Version,

    [Parameter(Mandatory = $false)]
    [switch]$Update,

    [Parameter(Mandatory = $false)]
    [switch]$AuditOnly,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$DscRoot = 'C:\ProgramData\DscOrchestrator',

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$TaskName = 'DscOrchestrator-Enforcement',

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$RegistryRoot = 'HKLM:\SOFTWARE\DscOrchestrator\Reboot',

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$AllUsersModulesPath = 'C:\Program Files\WindowsPowerShell\Modules',

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$PackageRoot = $PSScriptRoot,

    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [AllowNull()]
    [string]$ModulesSource
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$DscRoot = [System.IO.Path]::GetFullPath($DscRoot)
if ([string]::IsNullOrWhiteSpace($PackageRoot) -or
    -not (Test-Path -LiteralPath $PackageRoot -PathType Container)) {
    throw "PackageRoot '$PackageRoot' is not a directory. Use Install-VmApplicationPackage.ps1 for archive-based delivery."
}
$PackageRoot = [System.IO.Path]::GetFullPath($PackageRoot)
$manifestPath = Join-Path $PackageRoot 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "PackageRoot '$PackageRoot' is missing manifest.json."
}
try {
    $packageManifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop |
        ConvertFrom-Json -ErrorAction Stop
}
catch {
    throw "PackageRoot '$PackageRoot' has an invalid manifest.json: $($_.Exception.Message)"
}
$manifestVersion = if ($null -ne $packageManifest -and
    $packageManifest.PSObject.Properties.Name -contains 'version') {
    [string]$packageManifest.version
} else {
    ''
}
if ([string]::IsNullOrWhiteSpace($manifestVersion)) {
    throw "PackageRoot '$PackageRoot' manifest.json does not declare a version."
}
if ($manifestVersion -ne $Version) {
    throw "PackageRoot manifest version '$manifestVersion' does not match requested version '$Version'."
}

# Win32 command-line parsing treats trailing backslashes before a quote as escapes.
function ConvertTo-WindowsCommandLineArgument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.Append([char]34)
    $backslashCount = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq [char]92) {
            $backslashCount++
            continue
        }
        if ($character -eq [char]34) {
            [void]$builder.Append([string]::new([char]92, ($backslashCount * 2) + 1))
            [void]$builder.Append([char]34)
        }
        else {
            if ($backslashCount -gt 0) {
                [void]$builder.Append([string]::new([char]92, $backslashCount))
            }
            [void]$builder.Append([char]$character)
        }
        $backslashCount = 0
    }
    if ($backslashCount -gt 0) {
        [void]$builder.Append([string]::new([char]92, $backslashCount * 2))
    }
    [void]$builder.Append([char]34)
    return $builder.ToString()
}

$logsRoot = Join-Path $DscRoot 'logs'
$currentLink     = Join-Path $DscRoot 'current'
$stagingRoot     = Join-Path $DscRoot 'staging'
$versionDir      = Join-Path $stagingRoot $Version
$modulesTarget   = Join-Path $versionDir 'modules'
$waitTimeoutSec  = 1800
$bootstrapJsonl  = Join-Path $logsRoot 'bootstrap.jsonl'
$pwshSource  = ''
$pwshPath    = ''
$pwshVersion = ''

if (-not (Test-Path -LiteralPath $logsRoot)) {
    New-Item -ItemType Directory -Path $logsRoot -Force -ErrorAction Stop | Out-Null
}

$sourceDir = $PackageRoot

# VM Application install context cannot rely on PSModulePath.
Import-Module (Join-Path $sourceDir 'AppModules\Dsc.Bootstrap.psd1') -DisableNameChecking

. (Join-Path $sourceDir 'Resolve-PwshExe.ps1')
. (Join-Path $sourceDir 'Write-BootstrapJsonLine.ps1')

$transcriptPath = Join-Path $logsRoot ("bootstrap-{0}-{1:yyyyMMddHHmmss}.log" -f $Version, (Get-Date))
Start-Transcript -Path $transcriptPath -Force | Out-Null

# Disable window: Step 5 disables the task, only a completed Step 9 puts it back.
# Set before the try because the catch reads them under StrictMode.
$hadPreExistingTask        = $false
$enforcementTaskRegistered = $false
$taskRestore               = 'not_needed'

try {
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "DSC Orchestrator bootstrap - Version $Version" -ForegroundColor Cyan
    Write-Host "Mode: $(if ($Update) { 'Update' } else { 'Fresh Install' })" -ForegroundColor Cyan
    Write-Host "Transcript: $transcriptPath"              -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    Write-Host ""
    Write-Host "Preflight: resolving PowerShell 7..." -ForegroundColor Cyan
    $pwshInfo    = Resolve-PwshExe
    $pwshSource  = $pwshInfo.Source
    $pwshPath    = $pwshInfo.Path
    $pwshVersion = $pwshInfo.Version
    Write-Host "  pwsh: $pwshPath (source=$pwshSource, version=$pwshVersion)" -ForegroundColor Green
    Write-BootstrapJsonLine -Path $bootstrapJsonl -Stage 'preflight' -Status 'ok' `
        -Message "Resolved PowerShell 7" `
        -ConfigVersion $Version `
        -PwshSource $pwshSource -PwshPath $pwshPath -PwshVersion $pwshVersion

    Write-Host ""
    Write-Host "Step 1: Creating staging directory..." -ForegroundColor Cyan

    if (Test-Path -LiteralPath $versionDir) {
        Remove-CurrentPath -Path $versionDir
    }
    New-Item -ItemType Directory -Path $versionDir -Force -ErrorAction Stop | Out-Null
    Write-Host "  Created: $versionDir" -ForegroundColor Green

    Write-Host ""
    Write-Host "Step 2: Copying DSC runtime and config..." -ForegroundColor Cyan

    # AppModules avoids collision with downloaded DSC resources under modules.
    $excludedRuntimeItems = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@('configs', 'manifest.json', 'modules', 'bootstrap.ps1', 'Invoke-Enforcement.ps1', 'Run-Enforcement.ps1', 'remove.ps1', 'version.txt'),
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($item in Get-ChildItem -LiteralPath $sourceDir -Force -ErrorAction Stop) {
        if ($excludedRuntimeItems.Contains($item.Name)) { continue }
        Copy-Item -LiteralPath $item.FullName -Destination $versionDir -Recurse -Force -ErrorAction Stop
        Write-Host "  Copied runtime item: $($item.Name)" -ForegroundColor Green
    }

    $requiredFiles = @('dsc.exe')
    foreach ($fileName in $requiredFiles) {
        $src = Join-Path $sourceDir $fileName
        if (-not (Test-Path -LiteralPath $src)) {
            throw "Required file not found in source directory: $src"
        }
        Copy-Item -Path $src -Destination $versionDir -Force -ErrorAction Stop
        Write-Host "  Copied: $fileName" -ForegroundColor Green
    }

    $configsSrc = Join-Path $sourceDir 'configs'
    if (-not (Test-Path -LiteralPath $configsSrc -PathType Container)) {
        throw "DSCv3 package missing 'configs/' directory at source: $configsSrc -- misbuilt artifact."
    }
    $fragmentFiles = @(Get-ChildItem -LiteralPath $configsSrc -Recurse -Filter '*.dsc.yaml' -File -ErrorAction Stop)
    if ($fragmentFiles.Count -lt 1) {
        throw "DSCv3 package missing fragments under configs/ -- misbuilt artifact (no *.dsc.yaml files found under $configsSrc)."
    }
    $manifestSrc = Join-Path $sourceDir 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestSrc -PathType Leaf)) {
        throw "DSCv3 package missing 'manifest.json' at source: $manifestSrc -- misbuilt artifact."
    }
    Copy-Item -Path $configsSrc -Destination (Join-Path $versionDir 'configs') -Recurse -Force -ErrorAction Stop
    Write-Host "  Copied: configs/ ($($fragmentFiles.Count) fragment(s))" -ForegroundColor Green
    Copy-Item -Path $manifestSrc -Destination (Join-Path $versionDir 'manifest.json') -Force -ErrorAction Stop
    Write-Host "  Copied: manifest.json" -ForegroundColor Green

    Write-Host ""
    Write-Host "Step 3: Installing scoped PowerShell modules..." -ForegroundColor Cyan

    if (-not [string]::IsNullOrWhiteSpace($ModulesSource)) {
        $modulesSourcePath = $ModulesSource
        Write-Host "  Using override modules source: $modulesSourcePath" -ForegroundColor Gray
    }
    else {
        $modulesSourcePath = Join-Path $sourceDir 'modules'
    }
    if (Test-Path -LiteralPath $modulesSourcePath) {
        $modulesDirs = Get-ChildItem -Path $modulesSourcePath -Directory -ErrorAction Stop
        foreach ($mod in $modulesDirs) {
            Install-ScopedModule -Source $mod.FullName -DestinationRoot $modulesTarget
            Write-Host "  Installed (scoped): $($mod.Name) -> $modulesTarget" -ForegroundColor Green
        }
    }
    else {
        Write-Host "  No modules directory found - skipping module install." -ForegroundColor Gray
    }

    Write-Host ""
    Write-Host "Step 4: Copying enforcement scripts..." -ForegroundColor Cyan

    foreach ($scriptName in @('Invoke-Enforcement.ps1', 'Run-Enforcement.ps1')) {
        $scriptSrc = Join-Path $sourceDir $scriptName
        if (-not (Test-Path -LiteralPath $scriptSrc)) {
            throw "Required file not found in source directory: $scriptSrc"
        }
        Copy-Item -Path $scriptSrc -Destination $versionDir -Force -ErrorAction Stop
        Write-Host "  Copied: $scriptName" -ForegroundColor Green
    }

    Set-Content -Path (Join-Path $versionDir 'version.txt') -Value $Version -Force -ErrorAction Stop
    Write-Host "  Wrote: version.txt" -ForegroundColor Green

    $hadPreExistingTask = $null -ne (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)

    Write-Host ""
    Write-Host "Step 5: Quiescing enforcement task..." -ForegroundColor Cyan

    Wait-ForEnforcementTaskQuiet -TaskName $taskName -TimeoutSeconds $waitTimeoutSec -DscRoot $DscRoot

    Write-Host ""
    Write-Host "Step 6: Replacing 'current' runtime content..." -ForegroundColor Cyan

    Replace-CurrentContent -Source $versionDir -Destination $currentLink
    Write-Host "  Current runtime replaced: $currentLink" -ForegroundColor Green

    Write-Host ""
    Write-Host "Step 7: Syncing modules to AllUsers scope..." -ForegroundColor Cyan

    $currentModulesPath = Join-Path $currentLink 'modules'
    if (Test-Path -LiteralPath $currentModulesPath -PathType Container) {
        Sync-AllUsersModules -SourceModulesPath $currentModulesPath -TargetModulesPath $AllUsersModulesPath
        Write-Host "  Modules synced to AllUsers scope (WinPS adapter compatibility)" -ForegroundColor Green
    }
    else {
        Write-Host "  No modules directory in current runtime - skipping AllUsers sync" -ForegroundColor Gray
    }

    Write-Host ""
    Write-Host "Step 8: Cleaning up stale staging content..." -ForegroundColor Cyan

    if (Test-Path -LiteralPath $stagingRoot) {
        Get-ChildItem -Path $stagingRoot -Directory -ErrorAction Stop |
            Where-Object { $_.FullName -ne $versionDir } |
            ForEach-Object {
                try {
                    Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
                    Write-Host "  Removed stale staging directory: $($_.Name)" -ForegroundColor Gray
                }
                catch {
                    Write-Host "  WARNING: Could not remove stale staging directory $($_.Name): $_" -ForegroundColor Yellow
                }
            }
    }

    Write-Host ""
    Write-Host "Step 9: Registering scheduled task..." -ForegroundColor Cyan

    try {
        $runEnforcementPath = Join-Path $currentLink 'Run-Enforcement.ps1'
        $auditFlag = if ($AuditOnly) { ' -AuditOnly' } else { '' }
        $actionArgs = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File {0}{1} -DscRoot {2} -LogDir {3} -RegistryRoot {4}' -f `
            (ConvertTo-WindowsCommandLineArgument $runEnforcementPath), $auditFlag, `
            (ConvertTo-WindowsCommandLineArgument $DscRoot), `
            (ConvertTo-WindowsCommandLineArgument $logsRoot), `
            (ConvertTo-WindowsCommandLineArgument $RegistryRoot))
        $taskDescription = if ($AuditOnly) { 'DSC Orchestrator enforcement (AUDIT-ONLY)' } else { 'DSC Orchestrator enforcement' }

        $action    = New-ScheduledTaskAction    -Execute 'powershell.exe' -Argument $actionArgs
        $trigger   = New-ScheduledTaskTrigger   -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 15)
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

        # 3h ExecutionTimeLimit: first-boot enforcement (full resource set + strip-and-retry, plus a reboot-and-resume cycle) can exceed 2h; avoids a false aborted+non-convergence.
        $settings  = New-ScheduledTaskSettingsSet `
            -MultipleInstances IgnoreNew `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 180) `
            -StartWhenAvailable `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries

        # Write before Register-ScheduledTask; -At (Get-Date) fires immediately.
        $initialRunMarker = Join-Path $logsRoot '.initial-run'
        if (-not (Test-Path -LiteralPath $logsRoot)) {
            New-Item -ItemType Directory -Path $logsRoot -Force -ErrorAction Stop | Out-Null
        }
        New-Item -ItemType File -Path $initialRunMarker -Force -ErrorAction Stop | Out-Null

        Register-ScheduledTask `
            -TaskName    $taskName `
            -Action      $action `
            -Trigger     $trigger `
            -Principal   $principal `
            -Settings    $settings `
            -Description $taskDescription `
            -Force -ErrorAction Stop | Out-Null

        # -Force returns the task registered and enabled: window closed.
        $enforcementTaskRegistered = $true

        Start-ScheduledTask -TaskName $taskName -ErrorAction Stop

        Write-Host "  Scheduled task registered and enabled (fires immediately, then every 15 min)." -ForegroundColor Green
    }
    catch {
        Write-Host "  FAILED to register scheduled task: $_" -ForegroundColor Red
        throw
    }

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "DSC Orchestrator bootstrap complete - Version $Version" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green

    Write-BootstrapJsonLine -Path $bootstrapJsonl -Stage 'success' -Status 'ok' `
        -Message "Bootstrap complete for version $Version" `
        -ConfigVersion $Version `
        -PwshSource $pwshSource -PwshPath $pwshPath -PwshVersion $pwshVersion
}
catch {
    $bootstrapError = $_
    $errorType = 'BootstrapError'
    if ($bootstrapError.Exception) { $errorType = $bootstrapError.Exception.GetType().Name }

    # Fail toward enabled: restore a pre-existing task so the next run fails loudly rather than
    # the host going silently unenforced. Fresh install has no task and must not fabricate one.
    # Runs after the capture above: the inner catch rebinds $_.
    if ($hadPreExistingTask -and -not $enforcementTaskRegistered) {
        try {
            Enable-ScheduledTask -TaskName $taskName -ErrorAction Stop | Out-Null
            $taskRestore = 'restored'
            Write-Host "  Restored enforcement task '$taskName' to enabled after an incomplete update." -ForegroundColor Yellow
        }
        catch {
            $taskRestore = "failed: $($_.Exception.Message)"
            Write-Host "  WARNING: could not restore enforcement task '$taskName' to enabled: $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    try {
        Write-BootstrapJsonLine -Path $bootstrapJsonl -Stage 'fatal' -Status 'error' `
            -Message "Bootstrap failed for version $Version; task_restore=$taskRestore" `
            -ConfigVersion $Version `
            -PwshSource $pwshSource -PwshPath $pwshPath -PwshVersion $pwshVersion `
            -ErrorType $errorType -ErrorMessage $bootstrapError.Exception.Message
    }
    catch {
        Write-Host "  (failed to write bootstrap.jsonl fatal row: $($_.Exception.Message))" -ForegroundColor DarkGray
    }
    throw
}
finally {
    try { Stop-Transcript | Out-Null } catch { Write-Host "  (transcript already stopped)" -ForegroundColor DarkGray }
}
