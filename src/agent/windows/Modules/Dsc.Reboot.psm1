<#
.SYNOPSIS
    Orchestrator-owned reboot handling: registry inbox, restart-state state machine, and the
    finalize-before-reboot sequence.
.DESCRIPTION
    DSC resources request reboots through the Orchestrator-owned Request-DscReboot
    helper rather than calling Restart-Computer inline. See
    docs/operations/reboot-requests.md for the wire specification.

      - Registry inbox (HKLM:\SOFTWARE\DscOrchestrator\Reboot): Publish-DscRebootContext,
        Read-DscRebootRequests, Clear-DscRebootRequests.
      - restart-state.json consume-once state machine: Test-OrchestratorRebootResume (read-only
        override predicate), Set-DscRestartStateConsumed, Set-DscRestartStateRetired,
        Remove-DscRestartState.
      - Get-CanonicalBootId: the one shared boot-identity helper used by both the finalize write
        and the resume read (never raw/localized LastBootUpTime strings).
      - Invoke-OrchestratorRebootFinalize: the finalize-before-reboot sequence, with
        -Rebooter/-Clock injection so it is unit-testable without a real reboot.

    All registry/disk-touching functions take an explicit -RegistryRoot or -Path so tests never
    touch the real registry or restart-state.json.

    The cap/latch decision itself (loop-protection) is orchestrator-script logic
    (Invoke-Enforcement.ps1), not this module -- this module only supplies the primitives.
.NOTES
    restart-state.json schema 1.1: schema_version, enforcement_id, config_version,
    reboot_pending, pre_reboot_boot_id, loop_latched, reboot_count, reboot_kind,
    reboot_requested_by, pre_reboot_run_id, initiated_at, requesters[].
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:DscRestartStateSchemaVersion = '1.1'
$script:DscRebootRunsSchemaVersion   = '3.0'


function Get-CanonicalBootId {
    <#
    .SYNOPSIS
        Canonical boot identity -- the one shared helper used by both the finalize write and the
        resume read.
    .DESCRIPTION
        No stable per-boot id source exists on this fleet today, so this canonicalizes
        Win32_OperatingSystem.LastBootUpTime: UTC, rounded to whole seconds (CIM/WMI precision),
        serialized 'o'-format. Never compare raw/localized LastBootUpTime strings -- the same boot
        can render differently across cultures/runs and produce a false override or false block.
    .PARAMETER BootTimeUtc
        Optional override (unit tests); omit to query the live CIM boot time.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][Nullable[datetime]]$BootTimeUtc = $null
    )
    $utc = if ($null -ne $BootTimeUtc) {
        ([datetime]$BootTimeUtc).ToUniversalTime()
    } else {
        ([datetime](Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime).ToUniversalTime()
    }
    $rounded = [datetime]::new($utc.Year, $utc.Month, $utc.Day, $utc.Hour, $utc.Minute, $utc.Second, [DateTimeKind]::Utc)
    return $rounded.ToString('o')
}


function Publish-DscRebootContext {
    <#
    .SYNOPSIS
        Publishes this run's EnforcementId/ConfigVersion/RunId so Request-DscReboot
        helper can stamp requests with the live context.
    .DESCRIPTION
        Writes the Context registry key at run start so a request a module writes during its Set is
        stamped with, and later filtered back to, the current enforcement.
    .PARAMETER EnforcementId
        GUID identifying the enforcement effort this run belongs to.
    .PARAMETER ConfigVersion
        Deployed config version the run is enforcing.
    .PARAMETER RunId
        This run's unique id.
    .PARAMETER RegistryRoot
        Reboot registry root; defaults to HKLM:\SOFTWARE\DscOrchestrator\Reboot.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$EnforcementId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ConfigVersion,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RunId,
        [string]$RegistryRoot = 'HKLM:\SOFTWARE\DscOrchestrator\Reboot'
    )
    $contextKey = Join-Path $RegistryRoot 'Context'
    if (-not $PSCmdlet.ShouldProcess($contextKey, 'Publish reboot context')) { return }
    if (-not (Test-Path -LiteralPath $contextKey)) {
        New-Item -Path $contextKey -Force | Out-Null
    }
    Set-ItemProperty -LiteralPath $contextKey -Name 'EnforcementId' -Value $EnforcementId -Type String -Force
    Set-ItemProperty -LiteralPath $contextKey -Name 'ConfigVersion' -Value $ConfigVersion -Type String -Force
    Set-ItemProperty -LiteralPath $contextKey -Name 'RunId'         -Value $RunId -Type String -Force
}


function Read-DscRebootRequests {
    <#
    .SYNOPSIS
        Returns committed (Complete=1) reboot requests matching this run's published Context.
    .DESCRIPTION
        Filters on EnforcementId + ConfigVersion (and RunId when the request carries one) so a request
        stamped for a different/stale enforcement is ignored even if Complete=1 -- defends against
        a module that wrote a request in a prior run/enforcement whose inbox wipe was missed.
        A subkey missing Complete=1 is a torn/partial write and stays invisible (the commit fence).
    .PARAMETER EnforcementId
        Enforcement id the requests must match.
    .PARAMETER ConfigVersion
        Config version the requests must match.
    .PARAMETER RunId
        When set, a request carrying a different RunId is ignored.
    .PARAMETER RegistryRoot
        Reboot registry root; defaults to HKLM:\SOFTWARE\DscOrchestrator\Reboot.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Returns all committed requests for the current enforcement run.')]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$EnforcementId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ConfigVersion,
        [Parameter()][AllowEmptyString()][string]$RunId = '',
        [string]$RegistryRoot = 'HKLM:\SOFTWARE\DscOrchestrator\Reboot'
    )
    $requestsKey = Join-Path $RegistryRoot 'Requests'
    $results = New-Object 'System.Collections.Generic.List[object]'
    if (-not (Test-Path -LiteralPath $requestsKey)) { return @($results.ToArray()) }

    foreach ($sub in Get-ChildItem -LiteralPath $requestsKey -ErrorAction SilentlyContinue) {
        $props = $null
        try {
            $props = Get-ItemProperty -LiteralPath $sub.PSPath -ErrorAction Stop
        } catch {
            continue
        }
        if (-not ($props.PSObject.Properties.Name -contains 'Complete') -or [int]$props.Complete -ne 1) {
            continue
        }
        $reqEnforcement = [string]$props.EnforcementId
        $reqConfig  = [string]$props.ConfigVersion
        $reqRunId   = if ($props.PSObject.Properties.Name -contains 'RunId') { [string]$props.RunId } else { '' }
        $reqAt      = if ($props.PSObject.Properties.Name -contains 'RequestedAt') { [string]$props.RequestedAt } else { '' }
        if ($reqEnforcement -ne $EnforcementId -or $reqConfig -ne $ConfigVersion) { continue }
        if (-not [string]::IsNullOrEmpty($RunId) -and -not [string]::IsNullOrEmpty($reqRunId) -and $reqRunId -ne $RunId) {
            continue
        }
        $results.Add([pscustomobject]@{
            RequesterId   = $sub.PSChildName
            Kind          = [string]$props.Kind
            RequestedBy   = [string]$props.RequestedBy
            EnforcementId     = $reqEnforcement
            ConfigVersion = $reqConfig
            RunId         = $reqRunId
            RequestedAt   = $reqAt
        }) | Out-Null
    }
    return @($results.ToArray())
}


function Clear-DscRebootRequests {
    <#
    .SYNOPSIS
        Deletes every subkey under Requests\ -- the inbox-wipe (run start) and post-finalize clear.
    .DESCRIPTION
        Removes the Requests inbox so a run only acts on requests written during its own Set phases.
    .PARAMETER RegistryRoot
        Reboot registry root; defaults to HKLM:\SOFTWARE\DscOrchestrator\Reboot.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Clears every request subkey owned by the current enforcement run.')]
    param(
        [string]$RegistryRoot = 'HKLM:\SOFTWARE\DscOrchestrator\Reboot'
    )
    $requestsKey = Join-Path $RegistryRoot 'Requests'
    if ((Test-Path -LiteralPath $requestsKey) -and $PSCmdlet.ShouldProcess($requestsKey, 'Clear reboot requests')) {
        Remove-Item -LiteralPath $requestsKey -Recurse -Force -ErrorAction SilentlyContinue
    }
}


function script:Write-DscRestartStateAtomic {
    # Durable write: same-dir .tmp via exclusive FileStream, UTF-8 bytes, Flush($true)
    # (flush-to-disk, not just OS cache), close, then same-dir atomic replace/move as the commit.
    # A crash before commit leaves only a non-authoritative .tmp; readers never see a torn file.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Record
    )
    $Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $dir = Split-Path -Parent $Path
    if (-not [string]::IsNullOrEmpty($dir) -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $tmpPath = "$Path.tmp"
    $json  = $Record | ConvertTo-Json -Depth 10 -Compress
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($json)
    $stream = [System.IO.File]::Open($tmpPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }
    if ([System.IO.File]::Exists($Path)) {
        $backupPath = "$Path.bak"
        if ([System.IO.File]::Exists($backupPath)) {
            [System.IO.File]::Delete($backupPath)
        }
        [System.IO.File]::Replace($tmpPath, $Path, $backupPath)
        if ([System.IO.File]::Exists($backupPath)) {
            [System.IO.File]::Delete($backupPath)
        }
    }
    else {
        [System.IO.File]::Move($tmpPath, $Path)
    }
}


function script:Read-DscRestartStateRaw {
    # Corrupt/partial/absent restart-state is never authoritative -- treat as absent.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        return (Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        return $null
    }
}


function script:ConvertTo-DscCanonicalTimestamp {
    # ConvertFrom-Json silently auto-converts ISO8601-looking strings to [datetime]; a plain
    # [string] cast on that then yields a culture-formatted string, not the original ISO text.
    # Re-parse/reformat through 'o' so comparisons and round-trips are format-independent.
    param($Value)
    if ($null -eq $Value -or [string]::IsNullOrEmpty([string]$Value)) { return [string]$Value }
    try {
        $dt = if ($Value -is [datetime]) {
            $Value
        } else {
            [datetime]::Parse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        }
        return $dt.ToUniversalTime().ToString('o')
    } catch {
        return [string]$Value
    }
}


function Test-OrchestratorRebootResume {
    <#
    .SYNOPSIS
        Reboot-resume override predicate: does a committed reboot restart-state warrant overriding
        the stale-sentinel -> aborted path and resuming this enforcement? Consumes the override inline.
    .DESCRIPTION
        Override fires iff ALL FOUR hold: the file exists and parses; reboot_pending == true (the
        pending state -- never consumed, never latched); config_version matches the current run;
        and the caller-supplied current canonical boot identity (Get-CanonicalBootId, computed by
        the CALLER so this function never touches CIM) differs from the persisted
        pre_reboot_boot_id (a same-boot rerun/redeploy/cap-hit never overrides). restart-state is
        the sole override trigger: when it fires, this function atomically consumes it
        (Set-DscRestartStateConsumed) BEFORE returning -- a crash in the resumed run can never
        re-fire it (predicate 2 then blocks it). No separate consume call exists; this
        single call site is the contract.
    .PARAMETER Path
        Path to restart-state.json.
    .PARAMETER ConfigVersion
        Current run's config version; a mismatch never overrides.
    .PARAMETER CurrentBootId
        Caller-computed canonical boot identity; must differ from the persisted pre-reboot boot id to override.
    .OUTPUTS
        [pscustomobject] @{ Override; EnforcementId; RebootCount; RebootKind; RebootRequestedBy;
        Requesters; State (raw parsed restart-state, post-consume on override, or $null); Reason }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ConfigVersion,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$CurrentBootId
    )
    $state = Read-DscRestartStateRaw -Path $Path
    if ($null -eq $state) {
        return [pscustomobject]@{ Override = $false; EnforcementId = ''; RebootCount = 0; RebootKind = ''; RebootRequestedBy = ''; Requesters = @(); State = $null; Reason = 'no_state' }
    }
    if (-not [bool]$state.reboot_pending) {
        return [pscustomobject]@{ Override = $false; EnforcementId = [string]$state.enforcement_id; RebootCount = [int]$state.reboot_count; RebootKind = [string]$state.reboot_kind; RebootRequestedBy = [string]$state.reboot_requested_by; Requesters = @($state.requesters); State = $state; Reason = 'not_pending' }
    }
    if ([string]$state.config_version -ne $ConfigVersion) {
        return [pscustomobject]@{ Override = $false; EnforcementId = [string]$state.enforcement_id; RebootCount = [int]$state.reboot_count; RebootKind = [string]$state.reboot_kind; RebootRequestedBy = [string]$state.reboot_requested_by; Requesters = @($state.requesters); State = $state; Reason = 'config_mismatch' }
    }
    if ((ConvertTo-DscCanonicalTimestamp $state.pre_reboot_boot_id) -eq (ConvertTo-DscCanonicalTimestamp $CurrentBootId)) {
        return [pscustomobject]@{ Override = $false; EnforcementId = [string]$state.enforcement_id; RebootCount = [int]$state.reboot_count; RebootKind = [string]$state.reboot_kind; RebootRequestedBy = [string]$state.reboot_requested_by; Requesters = @($state.requesters); State = $state; Reason = 'same_boot' }
    }

    $consumed = Set-DscRestartStateConsumed -Path $Path
    return [pscustomobject]@{
        Override          = $true
        EnforcementId         = [string]$consumed.enforcement_id
        RebootCount       = [int]$consumed.reboot_count
        RebootKind        = [string]$consumed.reboot_kind
        RebootRequestedBy = [string]$consumed.reboot_requested_by
        Requesters        = @($consumed.requesters)
        State             = $consumed
        Reason            = 'override'
    }
}


function Set-DscRestartStateConsumed {
    <#
    .SYNOPSIS
        Consumes a fired override: atomically rewrites reboot_pending=false BEFORE the
        fragment loop so a crash in this resumed run can never re-fire it (predicate 2 blocks it).
        enforcement_id/reboot_count are preserved.
    .DESCRIPTION
        Called once by Test-OrchestratorRebootResume when the override fires; returns the consumed record.
    .PARAMETER Path
        Path to restart-state.json.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)
    $state = Read-DscRestartStateRaw -Path $Path
    if ($null -eq $state) { return $null }
    $record = [ordered]@{
        schema_version      = $script:DscRestartStateSchemaVersion
        enforcement_id          = [string]$state.enforcement_id
        config_version      = [string]$state.config_version
        reboot_pending      = $false
        pre_reboot_boot_id  = ConvertTo-DscCanonicalTimestamp $state.pre_reboot_boot_id
        loop_latched        = [bool]$state.loop_latched
        reboot_count        = [int]$state.reboot_count
        reboot_kind         = [string]$state.reboot_kind
        reboot_requested_by = [string]$state.reboot_requested_by
        pre_reboot_run_id   = [string]$state.pre_reboot_run_id
        initiated_at        = ConvertTo-DscCanonicalTimestamp $state.initiated_at
        requesters          = @($state.requesters)
    }
    if ($PSCmdlet.ShouldProcess($Path, 'Consume reboot override')) {
        Write-DscRestartStateAtomic -Path $Path -Record $record
    }
    return [pscustomobject]$record
}


function Invoke-OrchestratorRebootLatch {
    <#
    .SYNOPSIS
        Cap/latch retire: atomically rewrites reboot_pending=false, loop_latched=true,
        preserving enforcement_id/reboot_count. Never leaves a live override trigger at the cap.
    .DESCRIPTION
        The cap/latch DECISION is orchestrator-inline logic (Invoke-Enforcement.ps1); this is
        only the durable retire-write primitive, exposed as its own seam so it is unit-testable.
    .PARAMETER Path
        Path to restart-state.json.
    .PARAMETER EnforcementId
        Enforcement id to preserve on the latched record.
    .PARAMETER ConfigVersion
        Config version the latch is keyed to; cleared on a config change.
    .PARAMETER RebootCount
        Cumulative reboot count to preserve on the latched record.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$EnforcementId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ConfigVersion,
        [Parameter(Mandatory)][int]$RebootCount
    )
    $existing = Read-DscRestartStateRaw -Path $Path
    $record = [ordered]@{
        schema_version      = $script:DscRestartStateSchemaVersion
        enforcement_id          = $EnforcementId
        config_version      = $ConfigVersion
        reboot_pending      = $false
        pre_reboot_boot_id  = if ($null -ne $existing) { ConvertTo-DscCanonicalTimestamp $existing.pre_reboot_boot_id } else { '' }
        loop_latched        = $true
        reboot_count        = $RebootCount
        reboot_kind         = if ($null -ne $existing) { [string]$existing.reboot_kind } else { '' }
        reboot_requested_by = if ($null -ne $existing) { [string]$existing.reboot_requested_by } else { '' }
        pre_reboot_run_id   = if ($null -ne $existing) { [string]$existing.pre_reboot_run_id } else { '' }
        initiated_at        = if ($null -ne $existing) { ConvertTo-DscCanonicalTimestamp $existing.initiated_at } else { '' }
        requesters          = if ($null -ne $existing) { @($existing.requesters) } else { @() }
    }
    if ($PSCmdlet.ShouldProcess($Path, 'Retire reboot enforcement (cap/latch)')) {
        Write-DscRestartStateAtomic -Path $Path -Record $record
    }
}


function Remove-DscRestartState {
    <#
    .SYNOPSIS
        Enforcement retirement: terminal compliant/remediated, or a config_version change.
    .DESCRIPTION
        Deletes restart-state.json so the next run starts a fresh enforcement with no owed reboot.
    .PARAMETER Path
        Path to restart-state.json.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path)
    if ((Test-Path -LiteralPath $Path) -and $PSCmdlet.ShouldProcess($Path, 'Remove restart-state (enforcement retired)')) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }
}


function Invoke-OrchestratorRebootFinalize {
    <#
    .SYNOPSIS
        Finalize-before-reboot sequence: commit restart-state pending, clear the registry
        inbox, rewrite the typed sentinel, drop .reboot-in-progress, append the reboot_pending run
        summary, then reboot -- inside the caller's held run mutex.
    .DESCRIPTION
        Mutex invariant: the caller holds the run mutex throughout this call. On the expected path
        the OS force-terminates the process during the reboot step, abandoning the mutex by design
        (next run re-acquires via AbandonedMutexException) -- this function never returns on that
        path. If the injected -Rebooter returns or throws instead, this function takes
        the explicit failure path: restart-state is atomically rewritten non-pending (so no later
        run phantom-resumes) and an APPENDED corrective terminal row is written -- same run_id, a
        strictly-later timestamp (never an overwrite -- runs.jsonl is append-only), outcome
        remediation_failed/reboot_invocation_failed. This function never calls real `exit` itself
        (it must stay unit-testable: the default -Exit is a no-op); it returns ExitCode and the
        caller exits. reboot_count and the requesters[] merge (existing state at -Path, if any) are
        computed internally so the caller never assembles them by hand.
    .PARAMETER RunSummaryArgs
        Hashtable splatted into Write-RunSummary for the reboot_pending row (Mode/Trigger/Group/
        Role/ConfigurationHash/DscExeVersion/Total.../Had.../*Duration/ExitCode/ErrorMessage/etc). Path,
        Timestamp, ConfigVersion, RunId, SchemaVersion, Outcome, EnforcementId, RebootCount are supplied
        by this function -- do not include them here.
        Cloned (ExitCode/ErrorMessage overridden) for the corrective row on the failure path.
    .PARAMETER Rebooter
        Scriptblock invoked to reboot. Defaults to `Restart-Computer -Force -ErrorAction
        SilentlyContinue` followed by a 600s hold (SilentlyContinue keeps a transient reboot
        failure non-terminating so the explicit failure path records it rather than throwing).
        Inject a no-op/mock for tests.
    .PARAMETER Clock
        Scriptblock returning the current [datetime] (UTC). Inject a fixed/incrementing clock for tests.
    .PARAMETER Exit
        Scriptblock invoked with the exit code on the failure path. Defaults to a no-op (this
        function must never terminate the host test process) -- inject a capturing scriptblock to
        observe it; the caller's own `exit $result.ExitCode` is what actually exits in production.
    .PARAMETER StepRecorder
        Test-observability seam for finalize step ordering; invoked with a step-name string at each
        commit point. No-op when not supplied.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RegistryRoot,
        [Parameter(Mandatory)][string]$SentinelPath,
        [Parameter(Mandatory)][string]$RebootInProgressPath,
        [Parameter(Mandatory)][string]$RunsLogPath,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$EnforcementId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ConfigVersion,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RunId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RequestedBy,
        [Parameter(Mandatory)][ValidateSet('Immediate', 'Eventual')][string]$Kind,
        [Parameter(Mandatory)][int]$IncomingRebootCount,
        [Parameter(Mandatory)][hashtable]$RunSummaryArgs,
        # Restart-Computer -Force (no -Wait) returns immediately whether or not the box actually goes
        # down; the trailing hold gives the OS a real window to kill us before we ever reach the
        # failure path below -- without it, a reboot that silently never happens looks
        # identical to a successful one. -ErrorAction SilentlyContinue is required because this
        # module runs under $ErrorActionPreference='Stop': without it, a transient Restart-Computer
        # failure (e.g. an intermittently unresponsive CIM/WMI/DCOM stack) throws an
        # ActionPreferenceStopException that unwinds the run, instead of letting the explicit
        # failure path below record reboot_invocation_failed and exit cleanly.
        [Parameter()][ValidateNotNull()][scriptblock]$Rebooter = { Restart-Computer -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 600 },
        [Parameter()][ValidateNotNull()][scriptblock]$Clock = { [DateTime]::UtcNow },
        [Parameter()][ValidateNotNull()][scriptblock]$Exit = { param($Code) [void]$Code },
        [Parameter()][scriptblock]$StepRecorder = $null
    )


    $newRebootCount = $IncomingRebootCount + 1
    $existing = Read-DscRestartStateRaw -Path $Path
    $nowIso = { (& $Clock).ToUniversalTime().ToString('o') }

    # Carry requesters forward across reboots in the same enforcement; mint the first entry otherwise.
    $requesters = New-Object 'System.Collections.Generic.List[object]'
    $matched = $false
    if ($null -ne $existing -and $null -ne $existing.requesters) {
        foreach ($r in @($existing.requesters)) {
            if ([string]$r.requester_id -eq $RequestedBy) {
                $requesters.Add([ordered]@{
                    requester_id      = $RequestedBy
                    kind              = $Kind
                    request_count     = [int]$r.request_count + 1
                    last_requested_at = (& $nowIso)
                }) | Out-Null
                $matched = $true
            } else {
                $requesters.Add($r) | Out-Null
            }
        }
    }
    if (-not $matched) {
        $requesters.Add([ordered]@{
            requester_id      = $RequestedBy
            kind              = $Kind
            request_count     = 1
            last_requested_at = (& $nowIso)
        }) | Out-Null
    }

    $initiatedAt = (& $nowIso)

    # Step 1: commit the pending restart-state -- the authoritative resume signal (durable write).
    $pendingRecord = [ordered]@{
        schema_version      = $script:DscRestartStateSchemaVersion
        enforcement_id          = $EnforcementId
        config_version      = $ConfigVersion
        reboot_pending      = $true
        pre_reboot_boot_id  = (Get-CanonicalBootId)
        loop_latched        = $false
        reboot_count        = $newRebootCount
        reboot_kind         = $Kind
        reboot_requested_by = $RequestedBy
        pre_reboot_run_id   = $RunId
        initiated_at        = $initiatedAt
        requesters          = @($requesters.ToArray())
    }
    Write-DscRestartStateAtomic -Path $Path -Record $pendingRecord
    if ($null -ne $StepRecorder) { & $StepRecorder 'restart-state-commit' }

    # Step 2: clear consumed registry requests -- a crash past this point still resumes correctly.
    Clear-DscRebootRequests -RegistryRoot $RegistryRoot
    if ($null -ne $StepRecorder) { & $StepRecorder 'clear-requests' }

    # Step 3: corroborating-only typed sentinel; restart-state above is the sole authoritative trigger.
    try {
        $sentinelDir = Split-Path -Parent $SentinelPath
        if (-not [string]::IsNullOrEmpty($sentinelDir) -and -not (Test-Path -LiteralPath $sentinelDir)) {
            New-Item -ItemType Directory -Path $sentinelDir -Force | Out-Null
        }
        ([ordered]@{
            schema_version = '1.0'
            run_id         = $RunId
            type           = 'orchestrator_reboot_pending'
            enforcement_id     = $EnforcementId
            config_version = $ConfigVersion
            phase          = 'reboot_pending'
            phase_at       = $initiatedAt
        } | ConvertTo-Json -Compress -Depth 4) | Set-Content -LiteralPath $SentinelPath -Encoding utf8 -Force
    } catch {
        Write-Verbose "Typed reboot sentinel write swallowed: $($_.Exception.Message)"
    }
    if ($null -ne $StepRecorder) { & $StepRecorder 'sentinel-rewrite' }

    # Step 4: "reboot in flight, not a hang" signal for dashboards/bootstrap; the resumed run removes it.
    try {
        $ripDir = Split-Path -Parent $RebootInProgressPath
        if (-not [string]::IsNullOrEmpty($ripDir) -and -not (Test-Path -LiteralPath $ripDir)) {
            New-Item -ItemType Directory -Path $ripDir -Force | Out-Null
        }
        ([ordered]@{ enforcement_id = $EnforcementId; run_id = $RunId; initiated_at = $initiatedAt } |
            ConvertTo-Json -Compress -Depth 4) | Set-Content -LiteralPath $RebootInProgressPath -Encoding utf8 -Force
    } catch {
        Write-Verbose "reboot-in-progress marker write swallowed: $($_.Exception.Message)"
    }
    if ($null -ne $StepRecorder) { & $StepRecorder 'reboot-in-progress' }

    # Step 5: append the reboot_pending run summary (real 5 buckets + reboot columns) BEFORE
    # invoking the rebooter -- telemetry must land even if the process dies mid-reboot. Append-only
    # -- the resumed run's later compliant/remediated row supersedes this one, never overwrites it.
    $pendingTimestamp = $initiatedAt
    $pendingSummaryArgs = $RunSummaryArgs.Clone()
    $pendingSummaryArgs.Path = $RunsLogPath
    $pendingSummaryArgs.Timestamp = $pendingTimestamp
    $pendingSummaryArgs.ConfigVersion = $ConfigVersion
    $pendingSummaryArgs.RunId = $RunId
    $pendingSummaryArgs.SchemaVersion = $script:DscRebootRunsSchemaVersion
    $pendingSummaryArgs.Outcome = 'reboot_pending'
    $pendingSummaryArgs.EnforcementId = $EnforcementId
    $pendingSummaryArgs.RebootCount = $newRebootCount
    Write-RunSummary @pendingSummaryArgs
    if ($null -ne $StepRecorder) { & $StepRecorder 'summary' }

    # Step 6: reboot. Expected path: the OS force-terminates this process during the rebooter's hold
    # -- the caller's `finally` never runs and the run mutex is abandoned by design (next run
    # re-acquires via AbandonedMutexException). Reaching past this call at all -- return OR throw --
    # means the OS did not kill us in time; both are uniformly treated as failure. No
    # exit/return on this line: never voluntarily unwind before the OS kills us.
    $rebooterError = $null
    if ($null -ne $StepRecorder) { & $StepRecorder 'rebooter' }

    # If the default rebooter uses `-ErrorAction SilentlyContinue`, `Restart-Computer` can still emit
    # non-terminating errors (suppressed from the error stream) that won't be caught by `catch`.
    # Those errors still land in `$Error`, so snapshot/count-delta and capture the newest one.
    $preErrorCount = $Error.Count
    try {
        $null = & $Rebooter
    } catch {
        $rebooterError = $_.Exception.Message
    }
    if ($null -eq $rebooterError -and $Error.Count -gt $preErrorCount) {
        $err = $Error[0]
        if ($err -is [System.Management.Automation.ErrorRecord] -and $null -ne $err.Exception) {
            $rebooterError = $err.Exception.Message
        } else {
            $rebooterError = [string]$err
        }
    }

    # Step 7: explicit failure path -- reached only if the rebooter
    # returned/threw instead of terminating us. Never trust `finally`/process-death.
    $nonPendingRecord = [ordered]@{
        schema_version      = $script:DscRestartStateSchemaVersion
        enforcement_id          = $EnforcementId
        config_version      = $ConfigVersion
        reboot_pending      = $false
        pre_reboot_boot_id  = $pendingRecord.pre_reboot_boot_id
        loop_latched        = $false
        reboot_count        = $newRebootCount
        reboot_kind         = $Kind
        reboot_requested_by = $RequestedBy
        pre_reboot_run_id   = $RunId
        initiated_at        = $initiatedAt
        requesters          = @($requesters.ToArray())
    }
    Write-DscRestartStateAtomic -Path $Path -Record $nonPendingRecord

    $priorTimestamp = [datetime]::Parse($pendingTimestamp).ToUniversalTime()
    $correctiveTimestamp = (& $Clock).ToUniversalTime()
    if ($correctiveTimestamp -le $priorTimestamp) {
        # Clock didn't advance -- force +1ms so the gate's arg_max deterministically picks this row.
        $correctiveTimestamp = $priorTimestamp.AddMilliseconds(1)
    }

    $errorObj = [ordered]@{
        tag     = 'reboot_invocation_failed'
        message = if ([string]::IsNullOrEmpty($rebooterError)) { 'Rebooter returned without terminating the process.' } else { $rebooterError }
    }

    # Clone, never mutate the caller's hashtable -- ExitCode/ErrorMessage differ from the pending row.
    $correctiveArgs = $RunSummaryArgs.Clone()
    $correctiveArgs.Path = $RunsLogPath
    $correctiveArgs.Timestamp = $correctiveTimestamp.ToString('o')
    $correctiveArgs.ConfigVersion = $ConfigVersion
    $correctiveArgs.RunId = $RunId
    $correctiveArgs.SchemaVersion = $script:DscRebootRunsSchemaVersion
    $correctiveArgs.Outcome = 'remediation_failed'
    $correctiveArgs.EnforcementId = $EnforcementId
    $correctiveArgs.RebootCount = $newRebootCount
    $correctiveArgs.ExitCode     = 1
    $correctiveArgs.ErrorMessage = ($errorObj | ConvertTo-Json -Compress -Depth 4)
    # Append, never overwrite -- the step-5 reboot_pending row stays in runs.jsonl.
    Write-RunSummary @correctiveArgs

    Write-NativeStderr "ERROR: reboot finalize did not terminate the process (rebooter returned or threw); falling back to explicit failure path.`n"

    & $Exit 1
    return [pscustomobject]@{ Rebooted = $false; ExitCode = 1 }
}


Export-ModuleMember -Function `
    Get-CanonicalBootId, `
    Publish-DscRebootContext, `
    Read-DscRebootRequests, `
    Clear-DscRebootRequests, `
    Test-OrchestratorRebootResume, `
    Set-DscRestartStateConsumed, `
    Invoke-OrchestratorRebootLatch, `
    Remove-DscRestartState, `
    Invoke-OrchestratorRebootFinalize
