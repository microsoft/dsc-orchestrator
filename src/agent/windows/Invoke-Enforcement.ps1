
[CmdletBinding(SupportsShouldProcess)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Runtime progress is retained for the scheduled-task transcript; run and resource details are also recorded as JSONL.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification='GC_AppContext is an intentional process-global breadcrumb (current fragment name, "" between fragments) used as ambient run context for crash/diagnostic correlation; scoped Global by design and set only at fragment boundaries.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'GC_AppContext', Justification='Write-only ambient Global breadcrumb within this script; read out-of-process by diagnostics, so PSSA sees no in-script reader.')]
param(
    [Parameter(Mandatory = $false)]
    [switch]$AuditOnly,

    # SANDBOX-TEST-HOOK: tests regex-replace this default; keep shape stable.
    [Parameter(Mandatory = $false)]
    [string]$DscRoot = 'C:\ProgramData\DscOrchestrator',

    [Parameter(Mandatory = $false)]
    [string]$LogDir = '',

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$RegistryRoot = 'HKLM:\SOFTWARE\DscOrchestrator\Reboot',

    [Parameter(Mandatory = $false)]
    [ValidateSet('initial','scheduled')]
    [string]$RunTrigger = 'scheduled'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$DscRoot = [System.IO.Path]::GetFullPath($DscRoot)
if ([string]::IsNullOrWhiteSpace($LogDir)) {
    $LogDir = Join-Path $DscRoot 'logs'
}
$LogDir = [System.IO.Path]::GetFullPath($LogDir)
$env:DSC_ORCHESTRATOR_REBOOT_REGISTRY_ROOT = $RegistryRoot

$script:RunsSchemaVersion      = '3.0'
$script:ResourcesSchemaVersion = '3.0'
# Global safety cap -- an enforcement effort that reboots this many times without converging latches.
$script:RebootCap = 10

# Local JSONL records use duration strings, never null or missing values.
function script:Format-ElapsedDuration {
    param([System.Diagnostics.Stopwatch]$Stopwatch)
    if ($null -eq $Stopwatch) { return 'PT0S' }
    if (-not $Stopwatch.IsRunning -and $Stopwatch.ElapsedTicks -eq 0) { return 'PT0S' }
    return [System.Xml.XmlConvert]::ToString($Stopwatch.Elapsed)
}

function script:Format-TimeSpanDuration {
    param([TimeSpan]$Elapsed)
    return [System.Xml.XmlConvert]::ToString($Elapsed)
}

function script:Write-OptionalReasonDiagnostic {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object]$Text)

    try {
        Write-NativeStderr $Text
    } catch {
        # A failed diagnostic write cannot be allowed to fail enforcement; swallow it.
        $null = $_
    }
}

function script:Get-DscResourceResolutionFailureToken {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$NativeResult)

    if ([int]$NativeResult.ExitCode -eq 0) { return '' }
    $stderr = [string]$NativeResult.Stderr
    $patterns = @(
        'resource module not found',
        'Get-DscResource',
        'GetResourceFromKeyword',
        'GetCachedClassesForModule',
        'Cannot find.*DSC resource',
        'Could not find.*resource'
    )
    foreach ($pattern in $patterns) {
        if ($stderr -match $pattern) { return $pattern }
    }
    return ''
}

# manifest.json is authoritative; disk fallback is only for legacy/corrupt manifests.
function script:Get-OrderedFragments {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'The function returns the ordered fragment collection consumed by enforcement.')]
    param(
        [Parameter(Mandatory)][string]$ConfigsDir,
        [Parameter(Mandatory)][string]$ManifestPath
    )

    $fragFiles = @(Get-ChildItem -LiteralPath $ConfigsDir -Recurse -Filter '*.dsc.yaml' -File -ErrorAction Stop |
        Sort-Object FullName)
    if ($fragFiles.Count -lt 1) {
        throw "configs/ contains no *.dsc.yaml fragments under $ConfigsDir -- misbuilt artifact."
    }

    $fsByName = [System.Collections.Specialized.OrderedDictionary]::new()
    foreach ($f in $fragFiles) {
        $fname = Split-Path -Parent $f.FullName | Split-Path -Leaf
        if ([string]::IsNullOrEmpty($fname)) {
            throw "Cannot derive fragment name from path: $($f.FullName)"
        }
        if ($fsByName.Contains($fname)) {
            throw "Duplicate fragment name on disk: '$fname' (paths: $($fsByName[$fname]) AND $($f.FullName)) -- misbuilt artifact."
        }
        $fsByName.Add($fname, $f.FullName)
    }

    if (Test-Path -LiteralPath $ManifestPath -PathType Leaf) {
        $manifest = $null
        try {
            $manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        } catch {
            throw "manifest.json at $ManifestPath could not be parsed: $($_.Exception.Message)"
        }

        $manifestFrags = @()
        if ($null -ne $manifest -and $manifest.PSObject.Properties.Name -contains 'fragments' -and $null -ne $manifest.fragments) {
            $manifestFrags = @($manifest.fragments)
        }

        if ($manifestFrags.Count -gt 0) {
            $fsNamesSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($k in $fsByName.Keys) { [void]$fsNamesSet.Add([string]$k) }
            $manifestNames = @($manifestFrags | ForEach-Object { [string]$_.name } | Where-Object { -not [string]::IsNullOrEmpty($_) })
            $manifestSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$manifestNames, [System.StringComparer]::OrdinalIgnoreCase)

            $missingOnDisk = @($manifestNames | Where-Object { -not $fsNamesSet.Contains($_) })
            $extraOnDisk   = @(@($fsByName.Keys) | Where-Object { -not $manifestSet.Contains([string]$_) })
            if ($missingOnDisk.Count -gt 0 -or $extraOnDisk.Count -gt 0) {
                throw "manifest.json / configs/ divergence -- misbuilt artifact. Missing on disk: [$($missingOnDisk -join ',')]; extra on disk: [$($extraOnDisk -join ',')]."
            }

            $fragmentsRaw = @()
            foreach ($mf in $manifestFrags) {
                $n = [string]$mf.name
                $fragmentsRaw += [pscustomobject]@{
                    Name = $n
                    Path = [string]$fsByName[$n]
                    DependsOn = if ($mf.PSObject.Properties.Name -contains 'dependsOn') { @($mf.dependsOn) } else { @() }
                    Resources = if ($mf.PSObject.Properties.Name -contains 'resources') { @($mf.resources) } else { @() }
                }
            }

            $depGraph = @{}
            foreach ($frag in $fragmentsRaw) {
                $depGraph[$frag.Name] = @($frag.DependsOn)
            }

            $visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            $recStack = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            $pathList = [System.Collections.Generic.List[string]]::new()

            function Local:Find-Cycle {
                param([string]$node)
                if ($recStack.Contains($node)) {
                    $idx = $pathList.IndexOf($node)
                    $cycle = @($pathList[$idx..($pathList.Count-1)])
                    $cycle += $node
                    return ($cycle -join ' → ')
                }
                if ($visited.Contains($node)) { return $null }
                [void]$visited.Add($node)
                [void]$recStack.Add($node)
                [void]$pathList.Add($node)
                foreach ($dep in $depGraph[$node]) {
                    $c = Find-Cycle -node $dep
                    if ($null -ne $c) { return $c }
                }
                [void]$recStack.Remove($node)
                [void]$pathList.RemoveAt($pathList.Count - 1)
                return $null
            }

            foreach ($n in $depGraph.Keys) {
                $cycle = Find-Cycle -node $n
                if ($null -ne $cycle) { return ,$cycle }
            }

            $remaining = [System.Collections.Generic.List[string]]::new()
            $indexMap = @{}
            for ($i = 0; $i -lt $fragmentsRaw.Count; $i++) {
                $remaining.Add($fragmentsRaw[$i].Name)
                $indexMap[$fragmentsRaw[$i].Name] = $i
            }
            $ordered = [System.Collections.Generic.List[object]]::new()
            $placed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

            while ($remaining.Count -gt 0) {
                $ready = @($remaining | Where-Object {
                    $deps = $depGraph[$_]
                    if ($null -eq $deps -or $deps.Count -eq 0) {
                        $true
                    } else {
                        $allPlaced = $true
                        foreach ($d in $deps) { if (-not $placed.Contains($d)) { $allPlaced = $false } }
                        $allPlaced
                    }
                })
                if ($ready.Count -eq 0) { throw "Dependency graph has no ready nodes (cycle detection failure or logic error)." }
                $sorted = @($ready | Sort-Object { $indexMap[$_] })
                $next = $sorted[0]
                $frag = $fragmentsRaw | Where-Object { $_.Name -eq $next } | Select-Object -First 1
                $ordered.Add($frag)
                [void]$placed.Add($next)
                [void]$remaining.Remove($next)
            }
            return ,$ordered.ToArray()
        }
    }

    $ordered = @()
    foreach ($k in $fsByName.Keys) {
        $ordered += [pscustomobject]@{ Name = [string]$k; Path = [string]$fsByName[$k]; DependsOn = @(); Resources = @() }
    }
    return ,$ordered
}

function Update-RunSentinel {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)] [string] $LogDir,
        [Parameter(Mandatory)] [string] $RunId,
        [Parameter(Mandatory)] [datetime] $StartedAt,
        [Parameter(Mandatory)] [string] $Phase,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$ConfigurationHash = $null
    )
    $sentinel = Join-Path $LogDir '.in-progress.json'
    if (-not $PSCmdlet.ShouldProcess($sentinel, 'Write run sentinel')) { return }
    $payload = [ordered]@{
        schema_version = '1.0'
        run_id         = $RunId
        started_at     = $StartedAt.ToUniversalTime().ToString('o')
        phase          = $Phase
        phase_at       = (Get-Date).ToUniversalTime().ToString('o')
        configuration_hash = $ConfigurationHash
    }
    try {
        if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
        $payload | ConvertTo-Json -Compress -Depth 4 | Set-Content -LiteralPath $sentinel -Encoding utf8 -Force
    } catch {
        # Sentinel is best-effort; enforcement still owns the outcome.
        Write-Verbose "Sentinel update swallowed: $($_.Exception.Message)"
    }
}

function Remove-RunSentinel {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory)] [string] $LogDir)
    $sentinel = Join-Path $LogDir '.in-progress.json'
    try {
        if ((Test-Path -LiteralPath $sentinel) -and
            $PSCmdlet.ShouldProcess($sentinel, 'Remove run sentinel')) {
            Remove-Item -LiteralPath $sentinel -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Verbose "Sentinel removal swallowed: $($_.Exception.Message)"
    }
}

$currentDir   = Join-Path $DscRoot 'current'
$dscExe       = Join-Path $currentDir 'dsc.exe'
$configsDir   = Join-Path $currentDir 'configs'
$manifestFile = Join-Path $currentDir 'manifest.json'
$versionFile  = Join-Path $currentDir 'version.txt'
$metadataFile = Join-Path $currentDir 'metadata.json'
$runsLog       = Join-Path $LogDir 'runs.jsonl'
$resourcesLog  = Join-Path $LogDir 'resources.jsonl'

# Package stages agent helper modules under AppModules to avoid resource-module name collisions.
Import-Module (Join-Path $PSScriptRoot 'AppModules\Dsc.Toolkit.psd1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'AppModules\Dsc.Runtime.Dependencies.psm1') -DisableNameChecking

$totalSw = [System.Diagnostics.Stopwatch]::StartNew()

$runStartedAt           = [DateTime]::UtcNow
$runTimestamp           = $runStartedAt.ToString('o')
$runId                  = [Guid]::NewGuid().ToString()
# Correlates adapter/resource module logs with this run.
$env:GC_CORRELATION_ID = $runId
$runsSchemaVersion      = $script:RunsSchemaVersion
$resourcesSchemaVersion = $script:ResourcesSchemaVersion
$configVersion = Get-ConfigVersion -Path $versionFile
$configMetadata = Get-ConfigMetadata -Path $metadataFile
$group          = $configMetadata.Group
$role           = $configMetadata.Role
$configurationHash = $configMetadata.ConfigurationHash
$dscExeVersion  = Get-DscExeVersion -DscExePath $dscExe
$mode          = if ($AuditOnly) { 'audit' } else { 'enforce' }

$runSummaryDefaults = @{
    Path           = $runsLog
    ConfigVersion  = $configVersion
    RunId          = $runId
    SchemaVersion  = $runsSchemaVersion
    Group          = $group
    Role           = $role
    ConfigurationHash = $configurationHash
    DscExeVersion  = $dscExeVersion
    Mode           = $mode
    Trigger        = $RunTrigger
}

Write-Host "[$runTimestamp] Starting DSCv3 enforcement (version: $configVersion, mode: $mode, runId: $runId)..." -ForegroundColor Cyan

# One mutex covers the full pass; overlap logs 'skipped' and exits 0.
$enforcementMutex = $null
$mutexHeld        = $false
try {
    $enforcementMutex = [System.Threading.Mutex]::new($false, 'Global\DscOrchestrator-Enforcement')
}
catch {
    Write-NativeStderr "WARN: Failed to create re-entrancy mutex: $($_.Exception.Message). Proceeding without overlap protection.`n"
}

if ($null -ne $enforcementMutex) {
    try {
        $mutexHeld = $enforcementMutex.WaitOne(0)
    }
    catch [System.Threading.AbandonedMutexException] {
        $mutexHeld = $true
    }

    if (-not $mutexHeld) {
        Write-Host "  Prior enforcement run still in progress - skipping this trigger." -ForegroundColor Yellow
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
        Write-RunSummary @runSummaryDefaults -Timestamp $runTimestamp -Outcome 'skipped' `
            -TotalResources 0 -CompliantResources 0 -NonCompliantCount 0 -HadErrors $false `
            -TestDuration 'PT0S' -SetDuration 'PT0S' -VerifyDuration 'PT0S' `
            -TotalDuration (Format-ElapsedDuration $totalSw) `
            -ExitCode 0 -ErrorMessage 'skipped: prior enforcement still running' `
            -NonCompliantResources @()
        $enforcementMutex.Dispose()
        exit 0
    }
}

# Resume/override classification: evaluated before the stale-sentinel block so a valid
# override suppresses the false 'aborted' tombstone for our own clean reboot.
$restartStatePath = Join-Path $LogDir 'restart-state.json'
$script:RebootEnforcementId           = ''
$script:RebootCountIncoming       = 0
$script:RebootLoopLatchedIncoming = $false
$script:RebootEnforcementActive       = $false
$script:RebootPending             = $false
$script:RebootLoopLatched         = $false
$script:RebootKind                = ''
$script:RebootRequestedBy         = ''
$resumedThisRun = $false

try {
    $currentBootId = Get-CanonicalBootId
    $resumeEval = Test-OrchestratorRebootResume -Path $restartStatePath -ConfigVersion $configVersion -CurrentBootId $currentBootId
    if ($resumeEval.Override) {
        # restart-state-is-sole-override-trigger: Test-OrchestratorRebootResume already consumed it
        # (atomically, inline) before returning -- a crash in this resumed run then cannot re-fire the
        # override.
        $script:RebootEnforcementId     = [string]$resumeEval.EnforcementId
        $script:RebootCountIncoming = [int]$resumeEval.RebootCount
        $script:RebootKind          = [string]$resumeEval.RebootKind
        $script:RebootRequestedBy   = [string]$resumeEval.RebootRequestedBy
        $script:RebootEnforcementActive = $true
        $resumedThisRun = $true
        Remove-Item -LiteralPath (Join-Path $LogDir '.reboot-in-progress.json') -Force -ErrorAction SilentlyContinue
        Write-Host "  [resume] reboot override fired; resuming enforcement $($script:RebootEnforcementId) (reboot_count=$($script:RebootCountIncoming))." -ForegroundColor Cyan
    } elseif ($null -ne $resumeEval.State -and [string]$resumeEval.State.config_version -ne $configVersion) {
        # config_version changed since this enforcement was written -> retire it (also clears any latch); mint fresh below.
        Remove-DscRestartState -Path $restartStatePath
    } elseif ($null -ne $resumeEval.State -and ([bool]$resumeEval.State.reboot_pending -or [bool]$resumeEval.State.loop_latched)) {
        # Still-active effort (reboot pending on a same-boot rerun, or a live latch), boot-id gate didn't
        # fire -> carry enforcement/count/latch forward. A spent (consumed) state is not carried; fresh below.
        $script:RebootEnforcementId           = [string]$resumeEval.State.enforcement_id
        $script:RebootCountIncoming       = [int]$resumeEval.State.reboot_count
        $script:RebootLoopLatchedIncoming = [bool]$resumeEval.State.loop_latched
        $script:RebootEnforcementActive       = $true
    }
} catch {
    # Telemetry-blackhole guard: this runs before the main try/finally, so an unhandled CIM/registry
    # failure here would kill the run with no runs.jsonl row at all. Log and fall back to a fresh
    # enforcement (no override) rather than letting the whole run die silently.
    Write-NativeStderr "WARN: reboot resume/override classification failed ($($_.Exception.Message)); proceeding as a fresh enforcement.`n"
    $script:RebootEnforcementId           = ''
    $script:RebootCountIncoming       = 0
    $script:RebootLoopLatchedIncoming = $false
    $script:RebootEnforcementActive       = $false
    $resumedThisRun = $false
}
if ([string]::IsNullOrEmpty($script:RebootEnforcementId)) {
    $script:RebootEnforcementId = [Guid]::NewGuid().ToString()
}

# Stale sentinel means the prior run died before summary; emit an 'aborted' row. Suppressed when a
# valid reboot override just consumed this same sentinel (it is our own clean reboot, not a crash).
$staleSentinelPath = Join-Path $LogDir '.in-progress.json'
if (-not $resumedThisRun -and (Test-Path -LiteralPath $staleSentinelPath)) {
    try {
        $stale = Get-Content -LiteralPath $staleSentinelPath -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop
        $stalePhase    = if ($stale.phase) { [string]$stale.phase } else { 'unknown' }
        $staleStarted  = if ($stale.started_at) { [datetime]$stale.started_at } else { (Get-Date).ToUniversalTime() }
        $stalePhaseAt  = if ($stale.phase_at)   { [datetime]$stale.phase_at }   else { $staleStarted }
        $staleRunId    = if ($stale.run_id) { [string]$stale.run_id } else { 'unknown' }
        $staleConfigurationHash = $null
        if ($stale.PSObject.Properties.Name -contains 'configuration_hash') {
            $sentinelHash = [string]$stale.configuration_hash
            if (-not [string]::IsNullOrWhiteSpace($sentinelHash)) {
                $staleConfigurationHash = $sentinelHash
            }
        }
        $aliveSpan     = (Get-Date).ToUniversalTime() - $staleStarted.ToUniversalTime()
        $aliveDuration = [System.Xml.XmlConvert]::ToString($aliveSpan)
        $errMsg = "Previous run aborted before completion. Last known phase: $stalePhase at $($stalePhaseAt.ToString('o')). Run started: $($staleStarted.ToString('o')). Likely cause: scheduled task execution-time-limit kill, OS shutdown, or uncaught exception. Correlate by run_id with orphan records in the local resources.jsonl stream."
        $staleRunSummaryDefaults = @{
            Path          = $runsLog
            ConfigVersion = $configVersion
            RunId         = $staleRunId
            SchemaVersion = $runsSchemaVersion
            Group         = $group
            Role          = $role
            ConfigurationHash = $staleConfigurationHash
            DscExeVersion = $dscExeVersion
            Mode          = $mode
            Trigger       = $RunTrigger
        }
        Write-Host "  [aborted-prior] $staleRunId : $stalePhase" -ForegroundColor Yellow
        $staleRebootCount = if ($script:RebootEnforcementActive) { $script:RebootCountIncoming } else { 0 }
        Write-RunSummary @staleRunSummaryDefaults -Timestamp ($staleStarted.ToString('o')) `
            -Outcome 'aborted' `
            -TotalResources 0 -CompliantResources 0 -NonCompliantCount 0 -HadErrors $true `
            -TestDuration 'PT0S' -SetDuration 'PT0S' -VerifyDuration 'PT0S' `
            -TotalDuration $aliveDuration `
            -ExitCode 1 -ErrorMessage $errMsg `
            -NonCompliantResources @() -ErroringResources @() `
            -RebootCount $staleRebootCount -EnforcementId $script:RebootEnforcementId
    } catch {
        Write-NativeStderr "WARN: Could not parse stale sentinel ${staleSentinelPath}: $($_.Exception.Message). Deleting anyway.`n"
    }
    Remove-RunSentinel -LogDir $LogDir
}
if ($resumedThisRun) { Remove-RunSentinel -LogDir $LogDir }

# Publish Context + wipe the inbox so this run only sees requests written during its own Set phases
# (belt-and-suspenders: finalize already clears consumed requests pre-reboot).
Publish-DscRebootContext -EnforcementId $script:RebootEnforcementId -ConfigVersion $configVersion -RunId $runId -RegistryRoot $RegistryRoot
Clear-DscRebootRequests -RegistryRoot $RegistryRoot

Update-RunSentinel -LogDir $LogDir -RunId $runId -StartedAt $runStartedAt -Phase 'startup' -ConfigurationHash $configurationHash

try {

if (-not (Test-Path -LiteralPath $dscExe)) {
    Write-NativeStderr "ERROR: dsc.exe not found at $dscExe`n"
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    Write-RunSummary @runSummaryDefaults -Timestamp $runTimestamp -Outcome 'error' `
        -TotalResources 0 -CompliantResources 0 -NonCompliantCount 0 -HadErrors $true `
        -TestDuration 'PT0S' -SetDuration 'PT0S' -VerifyDuration 'PT0S' `
        -TotalDuration (Format-ElapsedDuration $totalSw) `
        -ExitCode 1 -ErrorMessage "dsc.exe missing: $dscExe" `
        -NonCompliantResources @()
    exit 1
}
if (-not (Test-Path -LiteralPath $configsDir -PathType Container)) {
    Write-NativeStderr "ERROR: configs directory not found at $configsDir`n"
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    Write-RunSummary @runSummaryDefaults -Timestamp $runTimestamp -Outcome 'error' `
        -TotalResources 0 -CompliantResources 0 -NonCompliantCount 0 -HadErrors $true `
        -TestDuration 'PT0S' -SetDuration 'PT0S' -VerifyDuration 'PT0S' `
        -TotalDuration (Format-ElapsedDuration $totalSw) `
        -ExitCode 1 -ErrorMessage "configs directory missing: $configsDir" `
        -NonCompliantResources @()
    exit 1
}

$preflightFragments = @(Get-ChildItem -LiteralPath $configsDir -Recurse -Filter '*.dsc.yaml' -File -ErrorAction SilentlyContinue)
if ($preflightFragments.Count -lt 1) {
    Write-NativeStderr "ERROR: configs directory contains no *.dsc.yaml fragments: $configsDir`n"
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    Write-RunSummary @runSummaryDefaults -Timestamp $runTimestamp -Outcome 'error' `
        -TotalResources 0 -CompliantResources 0 -NonCompliantCount 0 -HadErrors $true `
        -TestDuration 'PT0S' -SetDuration 'PT0S' -VerifyDuration 'PT0S' `
        -TotalDuration (Format-ElapsedDuration $totalSw) `
        -ExitCode 1 -ErrorMessage "no fragments under configs/: $configsDir" `
        -NonCompliantResources @()
    exit 1
}

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

# Do not set DSC_RESOURCE_PATH: dsc 3.1+ replaces PATH and breaks adapter discovery.
if (Test-Path -LiteralPath 'Env:\DSC_RESOURCE_PATH') {
    Remove-Item -LiteralPath 'Env:\DSC_RESOURCE_PATH' -Force -ErrorAction SilentlyContinue
}
# Bootstrap syncs resource modules to WinPS AllUsers; package modules stay off PSModulePath to avoid duplicate WinPS adapter resolution.

$fragments = Get-OrderedFragments -ConfigsDir $configsDir -ManifestPath $manifestFile

if ([string]$fragments -match '→') {
    Write-NativeStderr "ERROR: Dependency cycle detected (planning failure): $fragments`n"
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    $cycleErr = [pscustomobject]@{ summary = "dependency_cycle: $fragments"; failures = @([pscustomobject]@{ fragment = ''; phase = 'planning'; type = 'dependency_cycle'; name = ''; message = $fragments }) }
    $cycleJson = ConvertTo-Json -InputObject $cycleErr -Compress -Depth 5
    Write-RunSummary @runSummaryDefaults -Timestamp $runTimestamp -Outcome 'error' `
        -TotalResources 0 -CompliantResources 0 -NonCompliantCount 0 -HadErrors $true `
        -TestDuration 'PT0S' -SetDuration 'PT0S' -VerifyDuration 'PT0S' `
        -TotalDuration (Format-ElapsedDuration $totalSw) `
        -ExitCode 1 -ErrorMessage $cycleJson `
        -NonCompliantResources @()
    exit 1
}

if ($fragments.Count -eq 0) {
    Write-Host "  Empty fragment set; no work to do." -ForegroundColor Yellow
    Write-RunSummary @runSummaryDefaults -Timestamp $runTimestamp -Outcome 'compliant' `
        -TotalResources 0 -CompliantResources 0 -NonCompliantCount 0 -HadErrors $false `
        -TestDuration 'PT0S' -SetDuration 'PT0S' -VerifyDuration 'PT0S' `
        -TotalDuration (Format-ElapsedDuration $totalSw) `
        -ExitCode 0 -ErrorMessage '' `
        -NonCompliantResources @()
    exit 0
}

Write-Host ("  Per-fragment invocation: {0} fragment(s) to process." -f $fragments.Count) -ForegroundColor Cyan

$statusTracker = New-FragmentStatusTracker
foreach ($frag in $fragments) {
    Initialize-FragmentStatus -Tracker $statusTracker -FragmentName $frag.Name
}

$aggTestElapsed   = [TimeSpan]::Zero
$aggSetElapsed    = [TimeSpan]::Zero
$aggVerifyElapsed = [TimeSpan]::Zero
$aggTotalReal     = 0
$aggCompliant     = 0
$aggNonCompliant  = 0
$aggFailed        = 0
$aggSkipped       = 0
$aggUnevaluated   = 0
$aggNonCompliantResources = New-Object 'System.Collections.Generic.List[pscustomobject]'
$aggFailures              = New-Object 'System.Collections.Generic.List[object]'
$seenFailures             = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
$aggSkips                 = New-Object 'System.Collections.Generic.List[object]'
$aggHadErrors      = $false
$aggResourceResolutionFailed = $false
$aggNativeExitCode = 0
$aggDriftPersisted = $false
$anyDrift          = $false
$anyRemediated     = $false
$anyWhatIfSkipped  = $false
$errorMessages    = New-Object 'System.Collections.Generic.List[string]'
# Tracks position in $fragments for the actual-reboot path's unvisited-fragment accounting.
$fragmentLoopIndex = -1

$addFailure = {
    param($fragment, $phase, $type, $name, $message)
    $msg = if ([string]::IsNullOrEmpty($message)) { '' } else { [string]$message }
    if ($msg.Length -gt 8000) { $msg = $msg.Substring(0, 8000) }
    $key = "$fragment|$phase|$type|$name"
    if ($seenFailures.Add($key)) {
        $aggFailures.Add([pscustomobject]@{ fragment = [string]$fragment; phase = [string]$phase; type = [string]$type; name = [string]$name; message = $msg })
    }
}

$setIdentity = Get-HostIdentity

# Strip-and-retry recovery is always on. It isolates an attributable single-resource test
# abort (PowerShell/DSC#656 class) so the rest of the fragment still enforces. Happy path is
# one test invocation, same as before. See Dsc.Recovery.psm1 for the #656 removal runbook.

foreach ($fragment in $fragments) {
    # Only the actual-reboot path early-breaks the fragment loop. Checked at the top of the next
    # iteration (not after the prior fragment's try/finally) because `break` is illegal inside
    # `finally`, and a `continue` taken earlier in that iteration would skip a check placed after
    # its closing brace.
    if ($script:RebootPending) { break }
    $fragmentLoopIndex++
    $fragmentName = $fragment.Name
    $configFile   = $fragment.Path
    $fragmentDeps = @($fragment.DependsOn)
    $Global:GC_AppContext = $fragmentName

    $shouldSkip = Test-ShouldSkipDueToDependency -Tracker $statusTracker -DependsOn $fragmentDeps -AuditOnly:$AuditOnly
    if ($shouldSkip) {
        $blockedDetail = Get-BlockedByDetail -Tracker $statusTracker -DependsOn $fragmentDeps
        $blockedNames  = @($blockedDetail | ForEach-Object { $_.name })
        $blockedLabels = @($blockedDetail | ForEach-Object { "$($_.name)=$($_.status)" })
        Write-Host ("  [{0}] SKIPPED due to dependency gate: blocked by [{1}]" -f $fragmentName, ($blockedLabels -join ', ')) -ForegroundColor Yellow
        $aggSkips.Add([pscustomobject]@{ fragment = $fragmentName; blockedBy = @($blockedNames); reason = 'dependency_gate' })
        $skipCtx = @{
            SchemaVersion = $resourcesSchemaVersion
            RunId         = $runId
            Timestamp     = ([DateTime]::UtcNow.ToString('o'))
            Computer      = $env:COMPUTERNAME
            Group         = $group
            Role          = $role
            ConfigurationHash = $configurationHash
            ConfigVersion = $configVersion
            Trigger       = $RunTrigger
        }
        try {
            $skipEmit = Write-FragmentSkippedRows -FragmentName $fragmentName -FragmentPath $configFile `
                -BlockedBy @($blockedNames) -BlockedByDetail @($blockedDetail) -Context $skipCtx -ResourcesLogPath $resourcesLog
            $aggTotalReal += $skipEmit.EmittedCount
            $aggSkipped   += $skipEmit.EmittedCount
        } catch {
            Write-NativeStderr "WARN [$fragmentName]: Write-FragmentSkippedRows threw: $($_.Exception.Message)`n"
        }
        # Record 'skipped' for telemetry but leave Evaluated=$false: a skipped fragment was never
        # evaluated, so it does NOT satisfy a dependent's gate — this propagates the skip transitively.
        try {
            Set-FragmentTerminalStatus -Status (Get-FragmentStatus -Tracker $statusTracker -FragmentName $fragmentName) -Value 'skipped'
        } catch {
            Write-NativeStderr "WARN [$fragmentName]: Set-FragmentTerminalStatus (skipped) threw: $($_.Exception.Message)`n"
        }
        continue
    }

    if ($AuditOnly -and $fragmentDeps.Count -gt 0) {
        $blockedBy = Get-BlockedByList -Tracker $statusTracker -DependsOn $fragmentDeps
        if ($blockedBy.Count -gt 0) {
            Write-Host ("  [{0}] AuditOnly: would skip due to dependency gate (blocked by [{1}])" -f $fragmentName, ($blockedBy -join ', ')) -ForegroundColor Cyan
        }
    }

    Write-Host ("  [{0}] starting fragment ({1})" -f $fragmentName, $configFile) -ForegroundColor Cyan

    # Convergence owns test->reason-get->set->verify. The injected closures time the non-test
    # phases and $fragConvergeSw times the whole loop, so test_duration excludes all three.
    $fragConvergeSw = $null
    $fragTimers     = @{ Set = [TimeSpan]::Zero; Verify = [TimeSpan]::Zero; ReasonGet = [TimeSpan]::Zero }
    # Drives SET/VERIFY/GET. Equals $configFile unless recovery stripped a subset; cleaned in finally.
    $effectiveConfigFile   = $configFile
    $effectiveConfigIsTemp = $false
    $recovery              = $null

    # Updated in finally so runs.jsonl counts match post-set messages.
    $fragFinalTotal         = 0
    $fragFinalCompliant     = 0
    $fragFinalNonCompliant  = 0
    $fragFinalFailed        = 0
    $fragFinalUnevaluated   = 0
    $fragFinalNonCompliantList = @()
    $testTimestamp = $runTimestamp  # safe fallback if an exception fires before first assignment

    # Per-resource rows are emitted once in the finally below; stage the final test + verify
    # projections here so only the final pass's rows reach resources.jsonl. Null bundle = not emitted.
    $pendingTestBundle   = $null
    $pendingVerifyBundle = $null

    try {
        Update-RunSentinel -LogDir $LogDir -RunId $runId -StartedAt $runStartedAt -Phase 'test' -ConfigurationHash $configurationHash
        $testTimestamp = [DateTime]::UtcNow.ToString('o')

        # SET seam: targeted set of the drifted subset of the effective config (full-fragment
        # fallback on filter error). Buffers its lifecycle rows so the loop can discard an aborted
        # pass's rows on restart, and reports Aborted/Unreached so the loop can strip+restart.
        $setInvoker = {
            param($DscExePath, $ConfigFilePath, $ParsedTest)
            $drifted = Get-DriftedTopLevelResourceNames -ParsedTest $ParsedTest
            $cfg     = $ConfigFilePath
            $cfgTemp = $false
            if ($drifted.Count -gt 0 -and $drifted.Count -lt @($ParsedTest.Results).Count) {
                try {
                    $cfg = New-FilteredConfigForResources -SourcePath $ConfigFilePath -ResourceNames $drifted
                    $cfgTemp = $true
                    Write-Host "  [$fragmentName] targeting $($drifted.Count) drifted wrapper(s) for set." -ForegroundColor Cyan
                } catch {
                    Write-NativeStderr ("WARN [$fragmentName]: Could not build filtered set config (" + $_.Exception.Message + "); falling back to full fragment.`n")
                    $cfg = $ConfigFilePath; $cfgTemp = $false
                }
            }
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                Invoke-DscSet -DscExePath $DscExePath -ConfigFilePath $cfg -BufferRows `
                    -ResourcesLogPath $resourcesLog -ResourcesSchemaVersion $resourcesSchemaVersion `
                    -RunId $runId -HostName $setIdentity.HostName `
                    -Group $group -Role $role -ConfigurationHash $configurationHash -ConfigVersion $configVersion `
                    -RunTrigger $RunTrigger -FragmentName $fragmentName -DriftedSeedNames $drifted
            } finally {
                $sw.Stop(); $fragTimers.Set += $sw.Elapsed
                if ($cfgTemp -and (Test-Path -LiteralPath $cfg)) {
                    Remove-Item -LiteralPath $cfg -Force -ErrorAction SilentlyContinue
                }
            }
        }
        # VERIFY seam: re-test the effective config for post-set state.
        $verifyInvoker = {
            param($DscExePath, $ConfigFilePath)
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            try { Invoke-DscTestJson -DscExePath $DscExePath -ConfigFilePath $ConfigFilePath }
            finally { $sw.Stop(); $fragTimers.Verify += $sw.Elapsed }
        }
        # REASON GET seam: one pre-set `dsc config get` scoped to the drifted wrappers. Every harvest
        # failure mode (filter build, get throw / non-zero / parse error, stderr write, temp cleanup)
        # is swallowed here and returns $null, so the harvest cannot prevent the SET that follows.
        # Note the get is SYNCHRONOUS and runs before set: a hung `dsc config get` is bounded only by
        # the scheduled task's ExecutionTimeLimit, not by this callback.
        $testGetInvoker = {
            param($DscExePath, $ConfigFilePath, $DriftedNames)
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $getConfigFile = $null
            try {
                $getConfigFile = New-FilteredConfigForResources -SourcePath $ConfigFilePath -ResourceNames @($DriftedNames)
                $getInvocation = Invoke-DscGetJson -DscExePath $DscExePath -ConfigFilePath $getConfigFile
                Write-OptionalReasonDiagnostic $getInvocation.Native.Stderr
                if ($getInvocation.Native.ExitCode -eq 0 -and
                    $null -ne $getInvocation.Parsed -and
                    -not $getInvocation.Parsed.HadErrors) {
                    return $getInvocation.Parsed
                }

                $getHadErrors = if ($null -ne $getInvocation.Parsed) { $getInvocation.Parsed.HadErrors } else { 'parse-failed' }
                Write-OptionalReasonDiagnostic "WARN [$fragmentName]: targeted pre-set get exit=$($getInvocation.Native.ExitCode) hadErrors=$getHadErrors - test-phase rows fall back to synthetic reason.`n"
                return $null
            } catch {
                Write-OptionalReasonDiagnostic "WARN [$fragmentName]: targeted pre-set get threw: $($_.Exception.Message) - test-phase rows fall back to synthetic reason.`n"
                return $null
            } finally {
                if ($getConfigFile -and $getConfigFile -ne $ConfigFilePath -and (Test-Path -LiteralPath $getConfigFile)) {
                    Remove-Item -LiteralPath $getConfigFile -Force -ErrorAction SilentlyContinue
                }
                $sw.Stop()
                $fragTimers.ReasonGet += $sw.Elapsed
            }
        }

        # One decision governs set: AuditOnly observes only, and ShouldProcess (-WhatIf / -Confirm)
        # gates the rest. Folding it here means the loop never runs set after a decline.
        $enableSet = (-not $AuditOnly) -and $PSCmdlet.ShouldProcess("fragment '$fragmentName'", 'dsc config set')

        # Convergence wraps test->(targeted set)->verify, stripping an attributable abort's culprit +
        # reverse-dependsOn closure and restarting at test, or bailing to today's single-pass
        # behavior. Clean pass-1 test returns immediately (same cost as Invoke-DscTestJson).
        $fragConvergeSw = [System.Diagnostics.Stopwatch]::StartNew()
        $recovery = Invoke-FragmentConvergence -DscExePath $dscExe -ConfigFilePath $configFile `
            -SetInvoker $setInvoker -VerifyInvoker $verifyInvoker -TestGetInvoker $testGetInvoker -EnableSet:$enableSet
        $fragConvergeSw.Stop()

        $testInvocation        = $recovery.TestInvocation
        $effectiveConfigFile   = $recovery.EffectiveConfigPath
        $effectiveConfigIsTemp = $recovery.EffectiveConfigIsTemp

        # Read the reboot-request inbox for a committed Immediate request from this fragment's Set
        # (Context-filtered); first one seen applies the cap/latch gate BEFORE deciding
        # to reboot -- a latched/capped enforcement is ignored (no break, enforce to completion).
        if (-not $script:RebootPending -and -not $script:RebootLoopLatched) {
            $rebootRequests = Read-DscRebootRequests -EnforcementId $script:RebootEnforcementId -ConfigVersion $configVersion -RunId $runId -RegistryRoot $RegistryRoot
            $fragImmediate = $null
            foreach ($rr in $rebootRequests) {
                if ($rr.Kind -eq 'Immediate') { $fragImmediate = $rr; break }
            }
            if ($null -ne $fragImmediate) {
                $script:RebootKind          = $fragImmediate.Kind
                $script:RebootRequestedBy   = $fragImmediate.RequestedBy
                $script:RebootEnforcementActive = $true
                if ($script:RebootLoopLatchedIncoming -or ($script:RebootCountIncoming + 1) -gt $script:RebootCap) {
                    # cap-retires-the-pending-trigger: ignore the request, never break; enforce+bucket every fragment.
                    $script:RebootLoopLatched = $true
                } else {
                    $script:RebootPending = $true
                }
            }
        }

        $testResult = $testInvocation.Native
        $testTimings = $testInvocation.Timings
        Write-NativeStderr $testResult.Stderr

        # Emit the bail note before the parsed-null/token continue paths so every bail reaches telemetry.
        if ($null -ne $recovery -and -not [string]::IsNullOrEmpty([string]$recovery.BailReason)) {
            $culpritList = if ($recovery.Culprits.Count -gt 0) { ($recovery.Culprits -join ',') } else { '(none)' }
            $bailNote = "[$fragmentName] strip-and-retry bailed (reason=$($recovery.BailReason) passes=$($recovery.PassCount)); culprits: $culpritList"
            Write-Host "  $bailNote" -ForegroundColor Yellow
            $errorMessages.Add($bailNote) | Out-Null
        }

        # Quarantine rows are emitted further down (after the parsed-null/token paths, which continue on
        # the original full fragment), so the stripped set emits only on the survivor path. This holds
        # the split to fold by abort phase: test-abort culprit -> failed, set/verify-abort culprit ->
        # non_compliant, dependsOn collateral / crash -> unevaluated, after the survivor summary.
        $quarantineFailedCount       = 0
        $quarantineNonCompliantCount = 0
        $quarantineUnevaluatedCount  = 0

        $parsedTest = $testInvocation.Parsed
        if ($null -eq $parsedTest) {
            $nativeExitCode = [int]$testResult.ExitCode
            $signal = Find-DscErrorSignal -Stderr $testResult.Stderr
            $resPart = if ([string]::IsNullOrEmpty([string]$signal.ResourceName)) { '' } else { "/$($signal.ResourceName)" }
            $lastFailureResources = @()
            if (-not [string]::IsNullOrEmpty([string]$signal.ResourceName)) {
                $lastFailureResources = @([pscustomobject]@{ name = [string]$signal.ResourceName; type = [string]$signal.ResourceType })
            }
            Write-NativeStderr "ERROR [$fragmentName]: dsc config test returned unparseable JSON (native exit $nativeExitCode). Emitting per-resource unevaluated rows.`n"
            if (-not [string]::IsNullOrWhiteSpace($signal.Excerpt)) {
                Write-NativeStderr "  dsc stderr: $($signal.Excerpt)`n"
            }

            try {
                Write-LastFailures -LogDir $LogDir -RunId $runId -Timestamp $runTimestamp `
                    -ExitCode $nativeExitCode -FailingResources $lastFailureResources -StderrTail ([string]$testResult.Stderr)
            } catch {
                Write-NativeStderr "WARN [$fragmentName]: Write-LastFailures threw: $($_.Exception.Message)`n"
            }

            $aggHadErrors = $true
            $aggResourceResolutionFailed = $true
            if ($nativeExitCode -ne 0 -and $aggNativeExitCode -eq 0) { $aggNativeExitCode = $nativeExitCode }
            $errorMsg = "[$fragmentName$resPart]$($signal.Tag) native exit ${nativeExitCode}: $($signal.Excerpt)"
            $errorMessages.Add($errorMsg) | Out-Null
            
            $fragStatus = Get-FragmentStatus -Tracker $statusTracker -FragmentName $fragmentName
            $fragStatus.Evaluated = $true
            $fragStatus.HadErrors = $true
            
            $useRecoveryAttribution = ($null -ne $recovery -and $recovery.CulpritDetails.Count -gt 0)
            if ($useRecoveryAttribution) {
                foreach ($cd in $recovery.CulpritDetails) {
                    & $addFailure -fragment $fragmentName -phase 'test' -type ([string]$cd.Type) -name ([string]$cd.Name) -message ([string]$cd.Excerpt)
                }
            } else {
                & $addFailure -fragment $fragmentName -phase 'test' -type 'dsc_resource_resolution' -name $fragmentName -message $signal.Excerpt
            }

            try {
                $ctx = @{
                    SchemaVersion = $resourcesSchemaVersion
                    RunId         = $runId
                    Timestamp     = $testTimestamp
                    Computer      = $env:COMPUTERNAME
                    Group         = $group
                    Role          = $role
                    ConfigurationHash = $configurationHash
                    ConfigVersion = $configVersion
                    Trigger       = $RunTrigger
                }
                if ($useRecoveryAttribution) {
                    $culpritMap = @{}
                    foreach ($cd in $recovery.CulpritDetails) { $culpritMap[[string]$cd.Name] = @{ Excerpt = [string]$cd.Excerpt; Phase = [string]$cd.Phase } }
                    $emit = Write-FragmentUnevaluatedRows -FragmentName $fragmentName -FragmentPath $configFile `
                        -Cause 'parse_fail' -Excerpt ([string]$signal.Excerpt) -NativeExitCode $nativeExitCode `
                        -Context $ctx -ResourcesLogPath $resourcesLog `
                        -CulpritMap $culpritMap
                } else {
                    $emit = Write-FragmentUnevaluatedRows -FragmentName $fragmentName -FragmentPath $configFile `
                        -Cause 'parse_fail' -Excerpt ([string]$signal.Excerpt) -NativeExitCode $nativeExitCode `
                        -Context $ctx -ResourcesLogPath $resourcesLog `
                        -FailingResourceName ([string]$signal.ResourceName) -FailingResourceType ([string]$signal.ResourceType)
                }
                # Split the abort rows by phase: test-abort culprit -> failed, set/verify-abort culprit ->
                # non_compliant, collateral/crash -> unevaluated.
                $fragFinalTotal        += $emit.EmittedCount
                $fragFinalFailed       += $emit.FailedCount
                $fragFinalNonCompliant += $emit.NonCompliantCount
                $fragFinalUnevaluated  += $emit.UnevaluatedCount
            } catch {
                Write-NativeStderr "WARN [$fragmentName]: Write-FragmentUnevaluatedRows threw: $($_.Exception.Message)`n"
            }
            continue
        }

        $matchedToken = Get-DscResourceResolutionFailureToken -NativeResult $testResult
        if (-not [string]::IsNullOrWhiteSpace($matchedToken)) {
            $nativeExitCode = [int]$testResult.ExitCode
            $signal = Find-DscErrorSignal -Stderr $testResult.Stderr
            $resPart = if ([string]::IsNullOrEmpty([string]$signal.ResourceName)) { '' } else { "/$($signal.ResourceName)" }
            $lastFailureResources = @()
            if (-not [string]::IsNullOrEmpty([string]$signal.ResourceName)) {
                $lastFailureResources = @([pscustomobject]@{ name = [string]$signal.ResourceName; type = [string]$signal.ResourceType })
            }
            Write-NativeStderr "ERROR [$fragmentName]: dsc resource resolution failed (native exit $nativeExitCode). Emitting per-resource unevaluated rows.`n"
            if (-not [string]::IsNullOrWhiteSpace($signal.Excerpt)) {
                Write-NativeStderr "  dsc stderr: $($signal.Excerpt)`n"
            }

            try {
                Write-LastFailures -LogDir $LogDir -RunId $runId -Timestamp $runTimestamp `
                    -ExitCode $nativeExitCode -FailingResources $lastFailureResources -StderrTail ([string]$testResult.Stderr)
            } catch {
                Write-NativeStderr "WARN [$fragmentName]: Write-LastFailures threw: $($_.Exception.Message)`n"
            }

            $aggHadErrors = $true
            $aggResourceResolutionFailed = $true
            if ($nativeExitCode -ne 0 -and $aggNativeExitCode -eq 0) { $aggNativeExitCode = $nativeExitCode }
            $errorMsg = "[$fragmentName$resPart][regex_matched:$matchedToken] native exit ${nativeExitCode}: $($signal.Excerpt)"
            $errorMessages.Add($errorMsg) | Out-Null
            
            $useRecoveryAttribution = ($null -ne $recovery -and $recovery.CulpritDetails.Count -gt 0)
            if ($useRecoveryAttribution) {
                foreach ($cd in $recovery.CulpritDetails) {
                    & $addFailure -fragment $fragmentName -phase 'test' -type ([string]$cd.Type) -name ([string]$cd.Name) -message ([string]$cd.Excerpt)
                }
            } else {
                & $addFailure -fragment $fragmentName -phase 'test' -type 'dsc_resource_resolution' -name $fragmentName -message $signal.Excerpt
            }

            try {
                $ctx = @{
                    SchemaVersion = $resourcesSchemaVersion
                    RunId         = $runId
                    Timestamp     = $testTimestamp
                    Computer      = $env:COMPUTERNAME
                    Group         = $group
                    Role          = $role
                    ConfigurationHash = $configurationHash
                    ConfigVersion = $configVersion
                    Trigger       = $RunTrigger
                }
                if ($useRecoveryAttribution) {
                    $culpritMap = @{}
                    foreach ($cd in $recovery.CulpritDetails) { $culpritMap[[string]$cd.Name] = @{ Excerpt = [string]$cd.Excerpt; Phase = [string]$cd.Phase } }
                    $emit = Write-FragmentUnevaluatedRows -FragmentName $fragmentName -FragmentPath $configFile `
                        -Cause 'resource_resolution' -Excerpt ([string]$signal.Excerpt) -NativeExitCode $nativeExitCode `
                        -Context $ctx -ResourcesLogPath $resourcesLog `
                        -CulpritMap $culpritMap
                } else {
                    $emit = Write-FragmentUnevaluatedRows -FragmentName $fragmentName -FragmentPath $configFile `
                        -Cause 'resource_resolution' -Excerpt ([string]$signal.Excerpt) -NativeExitCode $nativeExitCode `
                        -Context $ctx -ResourcesLogPath $resourcesLog `
                        -FailingResourceName ([string]$signal.ResourceName) -FailingResourceType ([string]$signal.ResourceType)
                }
                # Split the abort rows by phase: test-abort culprit -> failed, set/verify-abort culprit ->
                # non_compliant, collateral/crash -> unevaluated.
                $fragFinalTotal        += $emit.EmittedCount
                $fragFinalFailed       += $emit.FailedCount
                $fragFinalNonCompliant += $emit.NonCompliantCount
                $fragFinalUnevaluated  += $emit.UnevaluatedCount
            } catch {
                Write-NativeStderr "WARN [$fragmentName]: Write-FragmentUnevaluatedRows threw: $($_.Exception.Message)`n"
            }
            continue
        }

        # Quarantine telemetry. Reaching here guarantees parsedTest != $null and no resolution token,
        # so the survivor summary below covers survivors ONLY -- the stripped set must be emitted here
        # or it vanishes. Fires whenever recovery stripped anything (recovered or bailed-after-strip);
        # the parsed-null/token paths above re-emit the full fragment and continue, so no double-emit.
        if ($null -ne $recovery -and $recovery.QuarantinedResources.Count -gt 0) {
            $qList       = ($recovery.QuarantinedResources -join ',')
            $culpritList = ($recovery.Culprits -join ',')
            if ($recovery.Recovered) {
                Write-Host ("  [{0}] strip-and-retry recovered after {1} pass(es); quarantined {2} wrapper(s): {3}" -f `
                    $fragmentName, $recovery.PassCount, $recovery.QuarantinedResources.Count, $qList) -ForegroundColor Yellow
                $errorMessages.Add("[$fragmentName] recovered via strip-and-retry ($($recovery.PassCount) pass(es)); quarantined: $qList") | Out-Null
            }
            # Bail note is emitted earlier (before the continue paths); none here.
            $aggHadErrors = $true
            foreach ($cd in $recovery.CulpritDetails) {
                & $addFailure -fragment $fragmentName -phase 'test' -type ([string]$cd.Type) -name ([string]$cd.Name) -message ([string]$cd.Excerpt)
            }

            try {
                Write-LastFailures -LogDir $LogDir -RunId $runId -Timestamp $runTimestamp `
                    -ExitCode 0 -FailingResources @($recovery.CulpritDetails | ForEach-Object { [pscustomobject]@{ name = [string]$_.Name; type = [string]$_.Type } }) `
                    -StderrTail "strip-and-retry culprits: $culpritList; quarantined: $qList"
            } catch {
                Write-NativeStderr "WARN [$fragmentName]: Write-LastFailures (recovery) threw: $($_.Exception.Message)`n"
            }

            try {
                # No dependsOn expansion: the set is already closed under reverse-dependsOn, so expanding
                # would re-pull surviving upstream wrappers and double-count them. Telemetry-only config.
                $quarantineConfig = New-FilteredConfigForResources -SourcePath $configFile -ResourceNames @($recovery.QuarantinedResources) -NoDependsOnExpansion
                try {
                    # Per-culprit excerpt + abort phase -> each named culprit gets had_errors=true + its own
                    # message, classified by phase (test -> failed, set/verify -> non_compliant); dependsOn
                    # collateral gets had_errors=false/empty (unevaluated).
                    $culpritMap = @{}
                    foreach ($cd in $recovery.CulpritDetails) { $culpritMap[[string]$cd.Name] = @{ Excerpt = [string]$cd.Excerpt; Phase = [string]$cd.Phase } }
                    $emitExit = if ($recovery.CulpritDetails.Count -gt 0) { [int]$recovery.CulpritDetails[0].ExitCode } else { 2 }
                    $ctx = @{
                        SchemaVersion = $resourcesSchemaVersion
                        RunId         = $runId
                        Timestamp     = $testTimestamp
                        Computer      = $env:COMPUTERNAME
                        Group         = $group
                        Role          = $role
                        ConfigurationHash = $configurationHash
                        ConfigVersion = $configVersion
                        Trigger       = $RunTrigger
                    }
                    $emit = Write-FragmentUnevaluatedRows -FragmentName $fragmentName -FragmentPath $quarantineConfig `
                        -Cause 'resource_resolution' -Excerpt '' -NativeExitCode $emitExit `
                        -Context $ctx -ResourcesLogPath $resourcesLog -CulpritMap $culpritMap
                    $quarantineFailedCount       = $emit.FailedCount
                    $quarantineNonCompliantCount = $emit.NonCompliantCount
                    $quarantineUnevaluatedCount  = $emit.UnevaluatedCount
                } finally {
                    if (Test-Path -LiteralPath $quarantineConfig) {
                        Remove-Item -LiteralPath $quarantineConfig -Force -ErrorAction SilentlyContinue
                    }
                }
            } catch {
                Write-NativeStderr "WARN [$fragmentName]: quarantine unevaluated-row emit threw: $($_.Exception.Message)`n"
            }
        }

        # Reasons come from the pre-set harvest run inside convergence (before any remediation), so a
        # non_compliant test row carries the reason for the state TEST saw. Null when the harvest was
        # unavailable or every wrapper's get failed; rows then fall back to a synthesized reason.
        $periodicGetParsed = $recovery.TestGet

        # Stage the final test projection for the single post-convergence emit; the pre-set GET
        # ($periodicGetParsed) stays alive to populate reasons on these rows.
        $pendingTestBundle = @{
            Parsed    = $parsedTest
            Get       = $periodicGetParsed
            Timestamp = $testTimestamp
            Timings   = $testTimings
        }

        # Survivor summary + quarantine split -> final buckets. The helper assigns (not folds), so the
        # verify-path call below recomputes (total == survivors + quarantine; quarantine counted once).
        $fragBuckets = Get-FragmentBucketCounts `
            -SurvivorSummary (Get-RealResourceSummary -ParsedTest $parsedTest) `
            -QuarantineFailedCount $quarantineFailedCount -QuarantineNonCompliantCount $quarantineNonCompliantCount -QuarantineUnevaluatedCount $quarantineUnevaluatedCount
        $fragFinalTotal            = $fragBuckets.Total
        $fragFinalCompliant        = $fragBuckets.Compliant
        $fragFinalNonCompliant     = $fragBuckets.NonCompliant
        $fragFinalFailed           = $fragBuckets.Failed
        $fragFinalUnevaluated      = $fragBuckets.Unevaluated
        $fragFinalNonCompliantList = $fragBuckets.NonCompliantList

        # exit 0 + top-level hadErrors=$false can still hide a per-resource error (an adapter envelope
        # whose inner results omit InDesiredState scores compliant), which would pass the success gate
        # and fail to block dependents. Treat any per-resource error as a fragment error.
        $anyResourceError = Test-ParsedTestHadResourceErrors -ParsedTest $parsedTest
        if ($testResult.ExitCode -ne 0 -or $parsedTest.HadErrors -or $anyResourceError) {
            Write-Host "  [$fragmentName] dsc config test reported errors (native exit=$($testResult.ExitCode), hadErrors=$($parsedTest.HadErrors), resourceErrors=$anyResourceError)." -ForegroundColor Red
            $aggHadErrors = $true
            (Get-FragmentStatus -Tracker $statusTracker -FragmentName $fragmentName).HadErrors = $true
            $errorMessages.Add("[$fragmentName] dsc test failed (exit=$($testResult.ExitCode), hadErrors=$($parsedTest.HadErrors), resourceErrors=$anyResourceError)") | Out-Null
            continue
        }

        $fragNonCompliant = 0
        foreach ($entry in $parsedTest.Results) {
            $c = Get-ResourceCompliance -Entry $entry
            if (-not $c.InDesiredState) { $fragNonCompliant++ }
        }
        $fragTotal = @($parsedTest.Results).Count
        $fragDrift = ($fragNonCompliant -gt 0)

        if (-not $fragDrift) {
            Write-Host "  [$fragmentName] all $fragTotal wrapper(s) in desired state." -ForegroundColor Green
            (Get-FragmentStatus -Tracker $statusTracker -FragmentName $fragmentName).Evaluated = $true
            continue
        }

        $anyDrift = $true

        if ($AuditOnly) {
            Write-Host "  [$fragmentName] [AuditOnly] drift observed: $fragNonCompliant of $fragTotal wrapper(s). Skipping remediation." -ForegroundColor Yellow
            continue
        }

        if (-not $enableSet) {
            # Drift present but set was declined at the pre-loop ShouldProcess gate (-WhatIf / -Confirm deny).
            Write-Host "  [$fragmentName] WhatIf: dsc config set skipped." -ForegroundColor Yellow
            $anyWhatIfSkipped = $true
            $errorMessages.Add("[$fragmentName] WhatIf: dsc config set skipped") | Out-Null
            continue
        }

        # EnableSet was true, so the loop ran the targeted set + verify; Phase 'test' means a bail
        # left no set running -- guard telemetry.
        if ($recovery.Phase -eq 'test') { continue }

        Update-RunSentinel -LogDir $LogDir -RunId $runId -StartedAt $runStartedAt -Phase 'set' -ConfigurationHash $configurationHash
        Write-Host "  [$fragmentName] Drift observed: $fragNonCompliant of $fragTotal wrapper(s) out of desired state. Remediated via convergence." -ForegroundColor Yellow

        # Source the convergence's final-pass set errors (the set-phase analogue of exit!=0||hadErrors).
        $setErrored = @($recovery.SetErrored)
        if ($setErrored.Count -gt 0) {
            Write-Host "  [$fragmentName] dsc config set reported per-resource errors." -ForegroundColor Red
            $aggHadErrors = $true
            # Set errors disqualify strict success even if the later verify reads clean.
            $fs = Get-FragmentStatus -Tracker $statusTracker -FragmentName $fragmentName
            $fs.Evaluated = $true; $fs.SetAttempted = $true; $fs.HadErrors = $true
            $errorMessages.Add("[$fragmentName] dsc set reported errors") | Out-Null

            foreach ($e in $setErrored) {
                $msg = if (-not [string]::IsNullOrWhiteSpace($e.message)) { $e.message } else { "dsc set failed for $($e.name)" }
                & $addFailure -fragment $fragmentName -phase 'set' -type $e.type -name $e.name -message $msg
            }
        }

        if ($null -eq $recovery.FinalVerify) {
            # Set aborted and the loop bailed before verify could run (DSC likely crashed) -- skip verify.
            Write-Host "  [$fragmentName] Set aborted before verify (DSC likely crashed) — skipping verify." -ForegroundColor Red
            continue
        }

        Update-RunSentinel -LogDir $LogDir -RunId $runId -StartedAt $runStartedAt -Phase 'verify' -ConfigurationHash $configurationHash
        $postTimestamp = [DateTime]::UtcNow.ToString('o')

        # Source the convergence's final-pass verify; the post-set GET runs here (the loop does no
        # file I/O), scoped to the final effective config, to populate verify rows.
        $verifyInvocation = $recovery.FinalVerify
        $verifyResult  = $verifyInvocation.Native
        $verifyTimings = $verifyInvocation.Timings
        Write-NativeStderr $verifyResult.Stderr

        $parsedVerify = $verifyInvocation.Parsed
        if ($null -eq $parsedVerify) {
            $verifyExitCode = $verifyResult.ExitCode
            if ($verifyExitCode -eq 2) {
                $signal = Find-DscErrorSignal -Stderr $verifyResult.Stderr
                $verifyFailureDetail = if ([string]::IsNullOrWhiteSpace($signal.Excerpt)) {
                    'unknown verify failure (native exit 2)'
                } else {
                    $signal.Excerpt
                }
                Write-NativeStderr "ERROR [$fragmentName]: post-remediation verify failed — $verifyFailureDetail`n"
            } else {
                Write-NativeStderr "ERROR [$fragmentName]: Could not parse post-remediation dsc test JSON output (native exit $verifyExitCode).`n"
            }
            $aggHadErrors = $true
            $verifyErrMsg = if ($verifyExitCode -eq 2) {
                "[$fragmentName] post-set verify: $verifyFailureDetail"
            } else {
                "[$fragmentName] post-set dsc test JSON parse failure (native exit $verifyExitCode)"
            }
            $errorMessages.Add($verifyErrMsg) | Out-Null
            continue
        }

        $postGetParsed = $null
        $postSnapshotClean = ($verifyResult.ExitCode -eq 0 -and -not $parsedVerify.HadErrors)
        if ($postSnapshotClean) {
            try {
                $postGetInvocation = Invoke-DscGetJson -DscExePath $dscExe -ConfigFilePath $effectiveConfigFile
                Write-NativeStderr $postGetInvocation.Native.Stderr
                if ($postGetInvocation.Native.ExitCode -eq 0 -and
                    $null -ne $postGetInvocation.Parsed -and
                    -not $postGetInvocation.Parsed.HadErrors) {
                    $postGetParsed = $postGetInvocation.Parsed
                } else {
                    $getHadErrors = if ($null -ne $postGetInvocation.Parsed) { $postGetInvocation.Parsed.HadErrors } else { 'parse-failed' }
                    Write-NativeStderr "WARN [$fragmentName]: dsc config get (post-remediation) returned exit=$($postGetInvocation.Native.ExitCode), hadErrors=$getHadErrors - resources.jsonl will fall back to wrapper-drift reason text.`n"
                }
            }
            catch {
                Write-NativeStderr "WARN [$fragmentName]: dsc config get (post-remediation) threw: $($_.Exception.Message) - resources.jsonl will fall back to wrapper-drift reason text.`n"
            }
        }

        # Stage the final verify projection for the single post-convergence emit; a non-null bundle
        # means a set ran and verify parsed, so verify rows are emitted in finally.
        $pendingVerifyBundle = @{
            Parsed    = $parsedVerify
            Get       = $postGetParsed
            Timestamp = $postTimestamp
            Timings   = $verifyTimings
        }

        # Verify re-tests the stripped config (survivors only); same reconciliation as the test path,
        # recomputed (not re-folded) so quarantine is counted exactly once.
        $fragBuckets = Get-FragmentBucketCounts `
            -SurvivorSummary (Get-RealResourceSummary -ParsedTest $parsedVerify) `
            -QuarantineFailedCount $quarantineFailedCount -QuarantineNonCompliantCount $quarantineNonCompliantCount -QuarantineUnevaluatedCount $quarantineUnevaluatedCount
        $fragFinalTotal            = $fragBuckets.Total
        $fragFinalCompliant        = $fragBuckets.Compliant
        $fragFinalNonCompliant     = $fragBuckets.NonCompliant
        $fragFinalFailed           = $fragBuckets.Failed
        $fragFinalUnevaluated      = $fragBuckets.Unevaluated
        $fragFinalNonCompliantList = $fragBuckets.NonCompliantList

        $postNonCompliant = 0
        foreach ($entry in $parsedVerify.Results) {
            $c = Get-ResourceCompliance -Entry $entry
            if (-not $c.InDesiredState) { $postNonCompliant++ }
        }
        $postTotal = @($parsedVerify.Results).Count

        # Same exit-0 per-resource-error hole as the test gate: an adapter envelope can report a
        # per-resource error while exit=0 and top-level hadErrors=$false, which would reach the
        # remediation-success path below and mark the fragment succeeded.
        $anyVerifyResourceError = Test-ParsedTestHadResourceErrors -ParsedTest $parsedVerify
        if ($verifyResult.ExitCode -ne 0 -or $parsedVerify.HadErrors -or $anyVerifyResourceError) {
            Write-Host "  [$fragmentName] post-remediation verify reported errors (native exit=$($verifyResult.ExitCode), hadErrors=$($parsedVerify.HadErrors), resourceErrors=$anyVerifyResourceError)." -ForegroundColor Red
            $aggHadErrors = $true
            (Get-FragmentStatus -Tracker $statusTracker -FragmentName $fragmentName).HadErrors = $true
            $errorMessages.Add("[$fragmentName] post-set verify failed (exit=$($verifyResult.ExitCode), hadErrors=$($parsedVerify.HadErrors), resourceErrors=$anyVerifyResourceError)") | Out-Null
            
            foreach ($e in @($parsedVerify.Results)) {
                if ($null -eq $e) { continue }
                $inners = Get-PowerShellAdapterInnerResources -Entry $e -RunDuration $parsedVerify.RunDuration
                foreach ($r in $inners) {
                    if ($r.HadErrors -eq $true) {
                        $msg = if (-not [string]::IsNullOrWhiteSpace($r.ErrorMessage)) {
                            $r.ErrorMessage
                        } elseif (-not [string]::IsNullOrWhiteSpace($r.Reason)) {
                            $r.Reason
                        } else {
                            "dsc verify failed for $($r.Name)"
                        }
                        if ($msg.Length -gt 1024) { $msg = $msg.Substring(0, 1024) }
                        & $addFailure -fragment $fragmentName -phase 'verify' -type $r.Type -name $r.Name -message $msg
                    }
                }
            }
            continue
        }

        if ($postNonCompliant -gt 0) {
            Write-Host "  [$fragmentName] drift persisted after remediation: $postNonCompliant of $postTotal wrapper(s) still out of desired state." -ForegroundColor Yellow
            $aggDriftPersisted = $true
            continue
        }

        Write-Host "  [$fragmentName] remediation successful: all $postTotal wrapper(s) now in desired state." -ForegroundColor Green
        $anyRemediated = $true
        $fragStatus = Get-FragmentStatus -Tracker $statusTracker -FragmentName $fragmentName
        $fragStatus.Evaluated = $true
        $fragStatus.SetAttempted = $true
        $fragStatus.VerifySucceeded = $true
        $fragStatus.FinalNonCompliantCount = 0

    } catch {
        $outerException = $_
        # Keep unexpected failures scoped to this fragment.
        $aggHadErrors = $true
        $errorMessages.Add("[$fragmentName] threw: $($outerException.Exception.Message)") | Out-Null
        Write-NativeStderr "ERROR [$fragmentName]: $($outerException.Exception.Message)`n"
        # If the fragment contributed nothing to any bucket yet, emit unevaluated rows so it
        # doesn't silently vanish from telemetry (blocking item 1 per plan).
        if ($fragFinalTotal -eq 0) {
            try {
                $catchCtx = @{
                    SchemaVersion = $resourcesSchemaVersion
                    RunId         = $runId
                    Timestamp     = $testTimestamp
                    Computer      = $env:COMPUTERNAME
                    Group         = $group
                    Role          = $role
                    ConfigurationHash = $configurationHash
                    ConfigVersion = $configVersion
                    Trigger       = $RunTrigger
                }
                $catchEmit = Write-FragmentUnevaluatedRows -FragmentName $fragmentName -FragmentPath $configFile `
                    -Cause 'parse_fail' -Excerpt ([string]$outerException.Exception.Message) -NativeExitCode 1 `
                    -Context $catchCtx -ResourcesLogPath $resourcesLog
                # No culprit/name passed -> an unattributable fragment crash: stays unevaluated (failed/
                # non_compliant counts are 0 here; the catch path never attributes).
                $fragFinalTotal        += $catchEmit.EmittedCount
                $fragFinalFailed       += $catchEmit.FailedCount
                $fragFinalNonCompliant += $catchEmit.NonCompliantCount
                $fragFinalUnevaluated  += $catchEmit.UnevaluatedCount
            } catch {
                Write-NativeStderr "WARN [$fragmentName]: catch-block Write-FragmentUnevaluatedRows threw: $($_.Exception.Message)`n"
            }
        }
    } finally {
        # Single post-convergence emit: write the staged final test + verify rows exactly once, on
        # every exit path (continue/return/throw all run finally). Early bail paths (parse_fail/token)
        # stage no test bundle and already emitted their own unevaluated rows, so they emit nothing here.
        if ($null -ne $pendingTestBundle) {
            try {
                $verifyParsed = if ($null -ne $pendingVerifyBundle) { $pendingVerifyBundle.Parsed }    else { $null }
                $verifyGet    = if ($null -ne $pendingVerifyBundle) { $pendingVerifyBundle.Get }       else { $null }
                $verifyTs     = if ($null -ne $pendingVerifyBundle) { [string]$pendingVerifyBundle.Timestamp } else { '' }
                $verifyTm     = if ($null -ne $pendingVerifyBundle) { $pendingVerifyBundle.Timings }   else { $null }
                Write-FinalStateResourceRecords `
                    -FinalTest $pendingTestBundle.Parsed -FinalTestGet $pendingTestBundle.Get `
                    -TestTimestamp ([string]$pendingTestBundle.Timestamp) -TestTimings $pendingTestBundle.Timings `
                    -FinalVerify $verifyParsed -FinalVerifyGet $verifyGet `
                    -VerifyTimestamp $verifyTs -VerifyTimings $verifyTm `
                    -Trigger $RunTrigger -Path $resourcesLog -SchemaVersion $resourcesSchemaVersion -RunId $runId `
                    -ConfigVersion $configVersion -Group $group -Role $role -ConfigurationHash $configurationHash -FragmentName $fragmentName
            } catch {
                Write-NativeStderr "WARN [$fragmentName]: final-state resource emit threw: $($_.Exception.Message)`n"
            }
        }

        # Flush the loop's buffered final-set rows once. Streaming them would double-write across
        # restart passes; the buffer + single flush is what prevents that.
        if ($null -ne $recovery -and $recovery.FinalSetRows.Count -gt 0) {
            foreach ($row in $recovery.FinalSetRows) {
                try {
                    Write-JsonLine -Path $resourcesLog -Record $row
                } catch {
                    Write-NativeStderr "WARN [$fragmentName]: set-row flush threw: $($_.Exception.Message)`n"
                }
            }
        }

        # Test wall-clock excludes set, verify, and the pre-set reason get without changing the schema.
        if ($null -ne $fragConvergeSw) {
            if ($fragConvergeSw.IsRunning) { $fragConvergeSw.Stop() }
            $aggSetElapsed    += $fragTimers.Set
            $aggVerifyElapsed += $fragTimers.Verify
            $testSpan = $fragConvergeSw.Elapsed - $fragTimers.Set - $fragTimers.Verify - $fragTimers.ReasonGet
            if ($testSpan -lt [TimeSpan]::Zero) { $testSpan = [TimeSpan]::Zero }
            $aggTestElapsed += $testSpan
        }

        # Strip-and-retry recovery temp config is owned here; clean it once the fragment is done.
        if ($effectiveConfigIsTemp -and $effectiveConfigFile -ne $configFile -and (Test-Path -LiteralPath $effectiveConfigFile)) {
            Remove-Item -LiteralPath $effectiveConfigFile -Force -ErrorAction SilentlyContinue
        }

        # Centralize aggregation so every continue path reports the final fragment state.
        $aggTotalReal    += $fragFinalTotal
        $aggCompliant    += $fragFinalCompliant
        $aggNonCompliant += $fragFinalNonCompliant
        $aggFailed       += $fragFinalFailed
        $aggUnevaluated  += $fragFinalUnevaluated
        foreach ($nc in $fragFinalNonCompliantList) { $aggNonCompliantResources.Add($nc) | Out-Null }

        # Record the fragment's terminal status for dependency-block telemetry. The gate decision stays
        # with Test-FragmentSucceeded; this only labels the outcome (worst-first from flags + buckets).
        # Guarded because a throw in finally would abort the whole enforcement loop.
        try {
            $fragStatusFinal = Get-FragmentStatus -Tracker $statusTracker -FragmentName $fragmentName
            if ([string]::IsNullOrEmpty([string]$fragStatusFinal.TerminalStatus)) {
                $terminal =
                    if ($fragStatusFinal.HadErrors -or $fragFinalFailed -gt 0) { 'failed' }
                    elseif ($fragFinalNonCompliant -gt 0 -or $fragStatusFinal.FinalNonCompliantCount -gt 0 -or $fragStatusFinal.HadDriftBeforeSet) { 'non_compliant' }
                    elseif ($fragFinalUnevaluated -gt 0 -or -not $fragStatusFinal.Evaluated) { 'unevaluated' }
                    elseif (Test-FragmentSucceeded -Status $fragStatusFinal) { 'compliant' }
                    else { 'failed' }
                Set-FragmentTerminalStatus -Status $fragStatusFinal -Value $terminal
            }
        } catch {
            Write-NativeStderr "WARN [$fragmentName]: terminal-status classification threw: $($_.Exception.Message)`n"
        }

        $Global:GC_AppContext = ''
    }
}

# Actual-reboot path only: the early break above left later fragments unrun this run -- account
# each declared resource as unevaluated so the 5-bucket invariant below still covers every
# declared resource, not just visited ones.
if ($script:RebootPending) {
    for ($unrunIdx = $fragmentLoopIndex + 1; $unrunIdx -lt $fragments.Count; $unrunIdx++) {
        $unrunFragment = $fragments[$unrunIdx]
        try {
            $unrunCtx = @{
                SchemaVersion = $resourcesSchemaVersion
                RunId         = $runId
                Timestamp     = ([DateTime]::UtcNow.ToString('o'))
                Computer      = $env:COMPUTERNAME
                Group         = $group
                Role          = $role
                ConfigurationHash = $configurationHash
                ConfigVersion = $configVersion
                Trigger       = $RunTrigger
            }
            $unreachedEmit = Write-FragmentRebootUnreachedRows -FragmentName $unrunFragment.Name -FragmentPath $unrunFragment.Path `
                -Context $unrunCtx -ResourcesLogPath $resourcesLog
            $aggTotalReal   += $unreachedEmit.EmittedCount
            $aggUnevaluated += $unreachedEmit.EmittedCount
        } catch {
            Write-NativeStderr "WARN [$($unrunFragment.Name)]: Write-FragmentRebootUnreachedRows threw: $($_.Exception.Message)`n"
        }
    }
}

# Eventual reboot (coalesced end-of-run): no Immediate request broke the walk, so every reachable
# fragment enforced this run and the buckets above are complete. If any committed request is
# Eventual, reboot once now -- at end of run rather than mid-walk. Deliberate parity with the
# Immediate path: the reboot is honored even if the run also had errors; the reboot_pending summary
# still carries had_errors + erroring_resources, so a real failure is not hidden from telemetry.
# Same cap/latch gate as Immediate, so this still sets exactly one of RebootPending/RebootLoopLatched.
if (-not $script:RebootPending -and -not $script:RebootLoopLatched) {
    $eventualCandidates = @(
        Read-DscRebootRequests -EnforcementId $script:RebootEnforcementId -ConfigVersion $configVersion -RunId $runId -RegistryRoot $RegistryRoot |
            Where-Object { $_.Kind -eq 'Eventual' } | Sort-Object RequesterId
    )
    if ($eventualCandidates.Count -gt 0) {
        $eventualReq = $eventualCandidates[0]
        $script:RebootKind              = $eventualReq.Kind
        $script:RebootRequestedBy       = $eventualReq.RequestedBy
        $script:RebootEnforcementActive = $true
        if ($script:RebootLoopLatchedIncoming -or ($script:RebootCountIncoming + 1) -gt $script:RebootCap) {
            $script:RebootLoopLatched = $true
        } else {
            $script:RebootPending = $true
        }
    }
}

$cappedNonCompliant = @($aggNonCompliantResources.ToArray() | Select-Object -First 10)

# Derive erroring_resources from distinct {type,name} of failures
if ($aggFailures.Count -gt 0) {
    $cappedErroring = @($aggFailures | Select-Object type, name -Unique | Select-Object -First 10)
} else {
    $cappedErroring = @()
}

$exitCode = if ($aggNativeExitCode -ne 0) { $aggNativeExitCode } elseif ($aggHadErrors) { 1 } else { 0 }

$outcome = if ($aggResourceResolutionFailed) {
    'resource_resolution_failed'
} elseif ($aggHadErrors) {
    'remediation_failed'
} elseif ($aggDriftPersisted) {
    'drift_persisted'
} elseif (($AuditOnly -or $anyWhatIfSkipped) -and $anyDrift) {
    'drift_observed'
} elseif ($anyRemediated) {
    'remediated'
} else {
    'compliant'
}

# Reboot/latch override: computed after the normal 7-way derivation so the row still
# carries real buckets. Mutually exclusive by construction (the mid-walk Immediate gate and the
# post-walk Eventual gate each set exactly one of RebootPending/RebootLoopLatched).
if     ($script:RebootLoopLatched) { $outcome = 'reboot_loop_detected' }
elseif ($script:RebootPending)     { $outcome = 'reboot_pending' }

# A latched/looping host must not report task success at the scheduled-task level even though the
# gate is outcome-keyed (and would already go red) -- force nonzero so naive exit-code monitors catch it too.
if ($script:RebootLoopLatched -and $exitCode -eq 0) { $exitCode = 1 }

$errorMessage = ''
if ($aggHadErrors -or $aggSkips.Count -gt 0) {
    $summaryText = if ($errorMessages.Count -gt 0) { ($errorMessages -join '; ') } else { '' }
    
    if ($aggFailures.Count -gt 0) {
        $ff = $aggFailures[0]
        $firstLine = "first failure: [$($ff.fragment)] $($ff.phase) $($ff.type)/$($ff.name)"
        $summaryText = if ($summaryText.Length -gt 0) { "$summaryText; $firstLine" } else { $firstLine }
    }
    
    if ($summaryText.Length -gt 16000) {
        $summaryText = $summaryText.Substring(0, 16000) + ' …[truncated]'
    }

    $errorObj = [pscustomobject]@{
        summary  = $summaryText
        failures = @($aggFailures.ToArray())
        skips    = @($aggSkips.ToArray())
    }
    $errorJson = ConvertTo-Json -InputObject $errorObj -Compress -Depth 5

    $maxBytes = 28672
    if ([System.Text.Encoding]::UTF8.GetByteCount($errorJson) -gt $maxBytes) {
        $origMsgs = @($aggFailures | ForEach-Object { [string]$_.message })
        $msgCap = 8000
        while ([System.Text.Encoding]::UTF8.GetByteCount($errorJson) -gt $maxBytes -and $msgCap -gt 200) {
            $msgCap = [int][Math]::Floor($msgCap * 0.7)
            for ($i = 0; $i -lt $aggFailures.Count; $i++) {
                $m = $origMsgs[$i]
                $aggFailures[$i].message = if ($m.Length -gt $msgCap) { $m.Substring(0, $msgCap) + ' …[truncated]' } else { $m }
            }
            $errorObj = [pscustomobject]@{ summary = $summaryText; failures = @($aggFailures.ToArray()); skips = @($aggSkips.ToArray()) }
            $errorJson = ConvertTo-Json -InputObject $errorObj -Compress -Depth 5
        }
        while ([System.Text.Encoding]::UTF8.GetByteCount($errorJson) -gt $maxBytes -and $summaryText.Length -gt 100) {
            $summaryText = $summaryText.Substring(0, [int][Math]::Max(100, [Math]::Floor($summaryText.Length * 0.8))) + ' …[truncated]'
            $errorObj = [pscustomobject]@{ summary = $summaryText; failures = @($aggFailures.ToArray()); skips = @($aggSkips.ToArray()) }
            $errorJson = ConvertTo-Json -InputObject $errorObj -Compress -Depth 5
        }
    }
    
    $errorMessage = $errorJson
}
# else: keep errorMessage = '' (empty string) for runs with no errors

Write-Host ("  Pass complete: outcome={0}, total_resources={1}, compliant={2}, non_compliant={3}, failed={4}, skipped={5}, unevaluated={6}" -f `
    $outcome, $aggTotalReal, $aggCompliant, $aggNonCompliant, $aggFailed, $aggSkipped, $aggUnevaluated) -ForegroundColor Cyan

# RUNTIME INVARIANT: total must equal the sum of the five pure buckets.
if ($aggTotalReal -ne ($aggCompliant + $aggNonCompliant + $aggFailed + $aggSkipped + $aggUnevaluated)) {
    Write-NativeStderr ("WARN [invariant-violation] total_resources={0} != compliant={1} + non_compliant={2} + failed={3} + skipped={4} + unevaluated={5}. Telemetry drift detected — investigate bucket accounting." -f `
        $aggTotalReal, $aggCompliant, $aggNonCompliant, $aggFailed, $aggSkipped, $aggUnevaluated)
}

Update-RunSentinel -LogDir $LogDir -RunId $runId -StartedAt $runStartedAt -Phase 'summary' -ConfigurationHash $configurationHash

$rebootCountForSummary       = if ($script:RebootPending) { $script:RebootCountIncoming + 1 } else { $script:RebootCountIncoming }

if ($script:RebootPending) {
    # Actual-reboot path: Invoke-OrchestratorRebootFinalize writes the reboot_pending
    # summary itself (real buckets) and owns the reboot; on rebooter failure it takes the explicit
    # failure path internally and returns a nonzero ExitCode instead of this script exiting.
    $rebootRunSummaryArgs = @{
        Group = $group; Role = $role; ConfigurationHash = $configurationHash; DscExeVersion = $dscExeVersion
        Mode = $mode; Trigger = $RunTrigger
        TotalResources = $aggTotalReal
        CompliantResources = $aggCompliant; NonCompliantCount = $aggNonCompliant
        FailedCount = $aggFailed
        SkippedCount = $aggSkipped; UnevaluatedCount = $aggUnevaluated
        HadErrors = $aggHadErrors
        TestDuration = (Format-TimeSpanDuration $aggTestElapsed)
        SetDuration = (Format-TimeSpanDuration $aggSetElapsed)
        VerifyDuration = (Format-TimeSpanDuration $aggVerifyElapsed)
        TotalDuration = (Format-ElapsedDuration $totalSw)
        ExitCode = 0
        ErrorMessage = $errorMessage
        NonCompliantResources = $cappedNonCompliant
        ErroringResources = $cappedErroring
    }
    Rotate-LogFile -Path $runsLog
    Rotate-LogFile -Path $resourcesLog
    $finalizeResult = Invoke-OrchestratorRebootFinalize -Path $restartStatePath `
        -RegistryRoot $RegistryRoot -SentinelPath $staleSentinelPath `
        -RebootInProgressPath (Join-Path $LogDir '.reboot-in-progress.json') -RunsLogPath $runsLog `
        -EnforcementId $script:RebootEnforcementId -ConfigVersion $configVersion -RunId $runId `
        -RequestedBy $script:RebootRequestedBy -Kind $script:RebootKind `
        -IncomingRebootCount $script:RebootCountIncoming -RunSummaryArgs $rebootRunSummaryArgs
    exit $finalizeResult.ExitCode
}

if ($script:RebootLoopLatched) {
    # Cap-retires-the-pending-trigger: never leaves a live override trigger at the cap.
    Invoke-OrchestratorRebootLatch -Path $restartStatePath -EnforcementId $script:RebootEnforcementId `
        -ConfigVersion $configVersion -RebootCount $script:RebootCountIncoming
} elseif ($resumedThisRun -and (Test-Path -LiteralPath $restartStatePath)) {
    # A resumed effort that didn't reboot again or latch is done -> retire the state, any outcome
    # (reboot bookkeeping is not tied to enforcement compliance).
    Remove-DscRestartState -Path $restartStatePath
}

Write-RunSummary @runSummaryDefaults -Timestamp $runTimestamp -Outcome $outcome `
    -TotalResources $aggTotalReal `
    -CompliantResources $aggCompliant -NonCompliantCount $aggNonCompliant `
    -FailedCount $aggFailed `
    -SkippedCount $aggSkipped -UnevaluatedCount $aggUnevaluated `
    -HadErrors $aggHadErrors `
    -TestDuration (Format-TimeSpanDuration $aggTestElapsed) `
    -SetDuration  (Format-TimeSpanDuration $aggSetElapsed) `
    -VerifyDuration (Format-TimeSpanDuration $aggVerifyElapsed) `
    -TotalDuration (Format-ElapsedDuration $totalSw) `
    -ExitCode $exitCode -ErrorMessage $errorMessage `
    -NonCompliantResources $cappedNonCompliant `
    -ErroringResources $cappedErroring `
    -RebootCount $rebootCountForSummary -EnforcementId $script:RebootEnforcementId
Rotate-LogFile -Path $runsLog
Rotate-LogFile -Path $resourcesLog
exit $exitCode

}
finally {
    Remove-RunSentinel -LogDir $LogDir
    if ($mutexHeld -and $null -ne $enforcementMutex) {
        try { $enforcementMutex.ReleaseMutex() } catch { Write-Verbose "Mutex release swallowed: $($_.Exception.Message)" }
    }
    if ($null -ne $enforcementMutex) {
        try { $enforcementMutex.Dispose() } catch { Write-Verbose "Mutex dispose swallowed: $($_.Exception.Message)" }
    }
}
