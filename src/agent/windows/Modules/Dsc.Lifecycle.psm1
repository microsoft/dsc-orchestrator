# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

<#
.SYNOPSIS
    `dsc config set` lifecycle observability — start/end progress events to
    resources.jsonl in real time.
.DESCRIPTION
    Two-function module:
    - Write-SetLifecycleEvent: appends a single set-start or set-end JSONL row.
    - New-SetLifecycleCallback: builds the stderr-line closure that
      Invoke-DscNative passes -OnStderrLine when streaming `dsc config set`.

    Depends on Dsc.HostContext (Write-NativeStderr).

    Encoding: Write-SetLifecycleEvent uses `Add-Content -Encoding utf8`. Under
    PowerShell 7 (the only runtime this code executes in — Run-Enforcement.ps1
    hard-fails without pwsh 7+ via Resolve-PwshExe) `-Encoding utf8` is BOM-less
    by default, byte-equivalent to the [IO.File]::AppendAllText + UTF8Encoding($false)
    pattern used by the other JSONL writers. If anything ever re-introduces a
    Windows PowerShell 5.1 path into this module, this line would start writing
    a BOM mid-file and corrupt resources.jsonl line discipline — guard the PS7
    floor in Resolve-PwshExe.
.NOTES
    Behavior preserved byte-equivalent from Invoke-Enforcement.ps1 Phase A.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'


function Write-SetLifecycleEvent {
    <#
    .SYNOPSIS
    Emits a single set start or set end record to resources.jsonl.
    .DESCRIPTION
    Real-time per-top-level-resource markers parsed from dsc.exe's `--progress-format json` stderr stream
    during `dsc config set`. Make the set phase observable in JSONL: `event=start` row without
    matching `event=end` within N minutes pinpoints hung resource by name. action='set', event distinguishes
    start/end. The emitted `trigger` field carries the run-level cause-of-fire ('initial' for the first
    run after deploy, 'scheduled' for periodic task ticks) so set-lifecycle rows pair with the matching
    runs.jsonl + resources.jsonl rows from the same run. Set-end completionKind: 'observed' (real duration,
    resource completed), 'synthetic' (process died, duration is "time until death", resource STILL hung --
    backstop to keep resources.jsonl consistent). Result vocabulary on set-end: 'set_complete' (set ran
    without error; compliance TBD by verify), 'set_failed' (set threw/didn't converge), 'unknown' (can't classify),
    $null (synthetic end). in_desired_state is null on set-end except on explicit failure ($false) — compliance
    is verify's job, not set's. Set-start rows carry result='set_started'. All field shaping flows through
    New-ResourceRecord (Dsc.JsonLog) so set lifecycle rows and bulk test/verify rows share one canonical schema.

    Schema 2.0: resource_type is always emitted (null if dsc.exe didn't surface a type for the in-flight
    resource); resource-id is gone entirely (use resource_type + resource_name combo to identify).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('start','end')][string]$Phase,
        [Parameter(Mandatory)][string]$RunTrigger,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$SchemaVersion,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Group,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Role,
        [Parameter(Mandatory)][string]$ConfigVersion,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$ConfigurationHash = $null,
        [Parameter(Mandatory)][string]$ResourceName,
        [Parameter()][AllowNull()][string]$ResourceType = $null,
        # Wrapper type for this row. 'unknown' surfaces unresolved adapters rather than
        # silently labeling them as PS7.
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Adapter = 'unknown',
        [Parameter()][AllowNull()][string]$DurationIso = $null,
        [Parameter()][ValidateSet('observed','synthetic')][string]$CompletionKind = 'observed',
        [Parameter()][AllowNull()][string]$Result = $null,
        # Populated from failure.message on failed set-end. Null otherwise.
        [Parameter()][AllowNull()][string]$ErrorMessage = $null,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$FragmentName = '',
        # When provided, the record is buffered into this list instead of written to $Path, so the
        # loop can discard a stripped pass's set rows and flush only the final set's. $null = stream.
        [Parameter()][AllowNull()][System.Collections.Generic.List[object]]$RecordSink = $null
    )

    # Derive inDesiredState from Phase and Result
    $inDesiredState = if ($Phase -eq 'start') {
        $null
    } elseif ($Phase -eq 'end') {
        # set-end CANNOT prove compliance — that's verify's job. Only confirm
        # in_desired_state=$false for explicit failure or synthetic process death.
        if ($Result -eq 'set_failed') { $false }
        elseif ($CompletionKind -eq 'synthetic') { $false }
        else { $null }
    } else {
        $null
    }

    # Derive hadErrors from Result
    $hadErrors = if ($Result -eq 'set_failed') { $true } else { $false }

    # phase='set' marks these as the within-run set/remediation pass -- orthogonal to
    # 'test' (drift test) and 'verify' (post-remediation verify) emitted by Write-ResourceRecords.
    # Keeps every resources.jsonl row carrying a phase value so local aggregations don't bin
    # set-lifecycle rows as null.
    # Schema 2.0: pass empty string for fields the lifecycle doesn't populate; the constructor
    # normalizes empty -> null. completion_kind only emitted on set-end (start carries '' -> null).
    $resourceTypeArg   = if ($null -ne $ResourceType -and $ResourceType -ne '') { $ResourceType } else { '' }
    $completionKindArg = if ($Phase -eq 'end') { $CompletionKind } else { '' }
    $durationArg       = if ($null -ne $DurationIso -and $DurationIso -ne '') { $DurationIso } else { '' }
    $resultArg         = if ($Phase -eq 'start')                       { 'set_started' }   # set-start verdict
                         elseif ($null -ne $Result -and $Result -ne '') { $Result }
                         else                                           { '' }
    $errorMessageArg   = if ($null -ne $ErrorMessage -and $ErrorMessage -ne '') { $ErrorMessage } else { '' }
    $adapterArg        = if ($null -ne $Adapter -and $Adapter -ne '') { $Adapter } else { 'unknown' }

    $record = New-ResourceRecord `
        -SchemaVersion $SchemaVersion -RunId $RunId `
        -Timestamp ((Get-Date).ToUniversalTime().ToString('o')) `
        -Computer $HostName -Group $Group -Role $Role `
        -ConfigVersion $ConfigVersion -ConfigurationHash $ConfigurationHash -Trigger $RunTrigger -Phase 'set' `
        -FragmentName $FragmentName `
        -Adapter $adapterArg -AdapterInstanceName $ResourceName `
        -ResourceType $resourceTypeArg -ResourceName $ResourceName `
        -InDesiredState $inDesiredState -Reasons @() `
        -Action 'set' -LifecycleEvent $Phase -Result $resultArg `
        -HadErrors $hadErrors -ErrorMessage $errorMessageArg `
        -Duration $durationArg -DurationSource 'per_resource' `
        -CompletionKind $completionKindArg

    # Buffer for later discard/flush, else stream to file (default).
    if ($null -ne $RecordSink) {
        [void]$RecordSink.Add($record)
    } else {
        Write-JsonLine -Path $Path -Record $record
    }
}

function New-SetLifecycleCallback {
    <#
    .SYNOPSIS
    Builds stderr-line callback closure for streaming `dsc config set`.
    .DESCRIPTION
    With `--progress-format json`, dsc.exe emits JSON objects per stderr line. Each top-level
    resource gets pair: completedItems==0 (start) + completedItems>0 (end). Callback tracks start
    times, emits start/end lifecycle events to resources.jsonl with wall-clock duration. Ignores
    trace events + non-Set progress. Returns @{ Callback; State } with per_resource start-time
    map for defensive flush on process exit.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSReviewUnusedParameter', '',
        Justification = 'All parameters are captured by the GetNewClosure() callback below and forwarded to Write-SetLifecycleEvent at lifecycle emit time. PSSA cannot see closure-captured usage.'
    )]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Returns a callback closure; it does not itself change system state.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$SchemaVersion,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Group,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Role,
        [Parameter(Mandatory)][string]$ConfigVersion,
        [Parameter(Mandatory)][string]$RunTrigger,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$ConfigurationHash = $null,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$FragmentName = '',
        # wrapperName -> @{ AdapterType; InnerType } from Get-WrapperInnerTypeMap.
        # Restores the adapter + inner type that dsc.exe progress doesn't surface.
        # Legacy plain-string value (inner type only) still tolerated.
        [Parameter()][AllowNull()][hashtable]$InnerTypeMap = $null,
        # When provided, set start/end records buffer here (per-pass) instead of streaming to $Path, so
        # the loop can discard a stripped pass's rows and flush only the final set's. $null = stream.
        [Parameter()][AllowNull()][System.Collections.Generic.List[object]]$BufferSink = $null
    )

    $state = @{
        InFlight  = @{}   # resourceName -> @{ StartedAt = <utc>; Type = ... }
        EmitCount = 0
        Errored   = (New-Object 'System.Collections.Generic.List[object]')
        # Final-set buffer when streaming is deferred; $null while streaming straight to file.
        Buffer    = $BufferSink
        # Wrappers that produced a set-start tick; never pruned (the abort denominator).
        # OrdinalIgnoreCase to match QuarantineSeen and the strip closure (no casing-mismatch Unreached).
        Started   = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    }

    $callback = {
        param($line)

        # $state captured by GetNewClosure() below — hashtable reference, so mutations
        # here are visible to Invoke-DscSet via the returned @{ Callback; State } bag.
        $st = $state
        if ($null -eq $st) { return }
        if ([string]::IsNullOrWhiteSpace($line)) { return }
        # Strip ANSI color codes that dsc.exe may emit even with JSON format.
        $clean = ($line -replace '\x1b\[[0-9;]*m','').Trim()
        if ($clean.Length -eq 0 -or $clean[0] -ne '{') { return }   # Not a JSON line — skip.

        try {
            $evt = $clean | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Write-NativeStderr "[lifecycle-cb] json parse failed: $($_.Exception.Message). first120=$($clean.Substring(0,[Math]::Min(120,$clean.Length)))`n"
            return
        }

        # Progress events have an 'activity' field. Trace events have 'timestamp'+'level'.
        $hasActivity = $false
        foreach ($p in $evt.PSObject.Properties) {
            if ($p.Name -eq 'activity') { $hasActivity = $true; break }
        }
        if (-not $hasActivity) { return }
        $activity = [string]$evt.activity
        if (-not $activity.StartsWith("Set '")) { return }

        # Use resourceName when present; fall back to parsing it from activity.
        $rn = Get-NestedProperty -Source $evt -Path 'resourceName'
        $name = if ($null -ne $rn) {
            [string]$rn
        } elseif ($activity -match "^Set '(?<n>[^']+)'") {
            $Matches.n
        } else { $null }
        if ([string]::IsNullOrEmpty($name)) { return }

        # Seed from progress event, then let InnerTypeMap override with config-derived
        # adapter + inner so set rows align with the test/verify bulk projection.
        # 'unknown' if dsc.exe doesn't surface a resourceType — never silently default to PS7.
        $adapter = [string](Get-NestedProperty -Source $evt -Path 'resourceType' -Default 'unknown')
        if ([string]::IsNullOrWhiteSpace($adapter)) { $adapter = 'unknown' }
        $type = $adapter
        if ($null -ne $InnerTypeMap -and $InnerTypeMap.ContainsKey($name)) {
            $mapEntry = $InnerTypeMap[$name]
            if ($mapEntry -is [System.Collections.IDictionary]) {
                $mappedAdapter = [string]$mapEntry['AdapterType']
                $mappedInner   = [string]$mapEntry['InnerType']
                if (-not [string]::IsNullOrWhiteSpace($mappedAdapter)) { $adapter = $mappedAdapter }
                if (-not [string]::IsNullOrWhiteSpace($mappedInner))   { $type    = $mappedInner }
            }
            else {
                # Legacy shape: value is the inner type string only.
                $type = [string]$mapEntry
            }
        }

        $hasResult  = $false
        $hasFailure = $false
        foreach ($p in $evt.PSObject.Properties) {
            if ($p.Name -eq 'result')  { $hasResult  = $true }
            if ($p.Name -eq 'failure') { $hasFailure = $true }
        }

        # set-start: first tick naming resource is its start. One tick per state transition. Don't trust completedItems (global).
        if (-not $st.InFlight.ContainsKey($name)) {
            $st.InFlight[$name] = @{
                StartedAt = (Get-Date).ToUniversalTime()
                Type      = $type
                Adapter   = $adapter
            }
            [void]$st.Started.Add($name)   # retained "reached" marker; never pruned
            Write-SetLifecycleEvent -Phase 'start' -RunTrigger $RunTrigger -Path $Path -SchemaVersion $SchemaVersion `
                -RunId $RunId -HostName $HostName -Group $Group -Role $Role `
                -ConfigVersion $ConfigVersion -ConfigurationHash $ConfigurationHash `
                -ResourceName $name -ResourceType $type -Adapter $adapter `
                -FragmentName $FragmentName -RecordSink $st.Buffer
            $st.EmitCount++
        }

        # set-end: completion signaled by EITHER `result` (success) OR `failure` (error).
        # Both per upstream lib/dsc-lib/src/progress.rs::Progress. DscError::Command path
        # emits neither field; the synthetic drain in Invoke-DscSet catches that case.
        if (($hasResult -or $hasFailure) -and $st.InFlight.ContainsKey($name)) {
            $entry = $st.InFlight[$name]
            $dur = if ($null -ne $entry.StartedAt) {
                $elapsed = (Get-Date).ToUniversalTime() - $entry.StartedAt
                [System.Xml.XmlConvert]::ToString($elapsed)
            } else { $null }

            $observedResult  = 'unknown'
            $observedMessage = $null
            try {
                if ($hasFailure) {
                    # failure.message is dsc.exe's best-available error text (often the
                    # manifest's wrapper description; raw stderr only on Command variant).
                    $f = $evt.failure
                    if ($null -ne $f) {
                        $msgRaw = Get-NestedProperty -Source $f -Path 'message'
                        if ($null -ne $msgRaw -and -not [string]::IsNullOrWhiteSpace([string]$msgRaw)) {
                            $observedMessage = [string]$msgRaw
                            if ($observedMessage.Length -gt 8000) { $observedMessage = $observedMessage.Substring(0, 8000) }
                        }
                        $exitCodeRaw = Get-NestedProperty -Source $f -Path 'exitCode'
                        if ($null -ne $exitCodeRaw -and [string]::IsNullOrEmpty($observedMessage)) {
                            $observedMessage = "dsc resource exit code: $exitCodeRaw"
                        }
                    }
                    $observedResult = 'set_failed'
                }
                elseif ($hasResult) {
                    # hadErrors=true inside result still surfaces as failed.
                    $r = $evt.result
                    if ($null -ne $r) {
                        $hasAfter  = $false
                        $hasErrors = $false
                        foreach ($p in $r.PSObject.Properties) {
                            if ($p.Name -eq 'afterState') { $hasAfter = $true }
                            if ($p.Name -eq 'hadErrors' -and $p.Value -eq $true) { $hasErrors = $true }
                        }
                        if ($hasErrors)     { $observedResult = 'set_failed' }
                        elseif ($hasAfter)  { $observedResult = 'set_complete' }
                    }
                }
            } catch { $observedResult = 'unknown' }

            if ($observedResult -eq 'set_failed') {
                $msg = if (-not [string]::IsNullOrWhiteSpace($observedMessage)) {
                    if ($observedMessage.Length -gt 1024) { $observedMessage.Substring(0, 1024) } else { $observedMessage }
                } else { "dsc set failed for $name" }
                $st.Errored.Add(@{ type = $entry.Type; name = $name; message = $msg; completionKind = 'observed' })
            }

            Write-SetLifecycleEvent -Phase 'end' -RunTrigger $RunTrigger -Path $Path -SchemaVersion $SchemaVersion `
                -RunId $RunId -HostName $HostName -Group $Group -Role $Role `
                -ConfigVersion $ConfigVersion -ConfigurationHash $ConfigurationHash `
                -ResourceName $name -ResourceType $entry.Type -Adapter $entry.Adapter `
                -DurationIso $dur -CompletionKind 'observed' -Result $observedResult `
                -ErrorMessage $observedMessage `
                -FragmentName $FragmentName -RecordSink $st.Buffer
            $st.InFlight.Remove($name) | Out-Null
        }
    }.GetNewClosure()

    return @{ Callback = $callback; State = $state }
}

function New-TimingCallback {
    <#
    .SYNOPSIS
    Builds a stderr-line callback that captures per_resource wall-clock duration.
    .DESCRIPTION
    Lighter-weight cousin of New-SetLifecycleCallback: tracks start/end of `--progress-format json`
    progress events for `dsc config <verb>` and records elapsed time per top-level resource into a
    Timings hashtable (resourceName -> ISO 8601 duration string). Does NOT emit any JSONL rows --
    the bulk Write-ResourceRecords writer joins these timings into the resources.jsonl rows it emits.

    Wired into Invoke-DscTestJson and Invoke-DscGetJson so test/verify/get phases capture real
    per_resource timing instead of falling back to `inheritedFromRun` (which is what happens today
    -- dsc.exe 3.2.x does not populate metadata.executionInformation.duration or
    metadata.Microsoft.DSC.duration on per_resource entries during test/get).

    -ActivityVerb selects which progress events to track ('Test', 'Get', 'Set', or 'Export').
    Each progress event activity field starts with `<verb> '<resourceName>'`. Trace events (no
    activity field) are ignored. The first tick observing a name starts the timer; the first tick
    carrying a `result` blob ends it. Ignores non-matching activities so a single callback won't
    cross-contaminate if dsc.exe ever emits mixed-verb progress in one run.

    Returns @{ Callback; Timings; State }. Callback is the closure to pass to Invoke-DscNative
    -OnStderrLine. Timings is the live hashtable -- Write-ResourceRecords reads it after the
    invocation completes. State exposes the InFlight map so synthetic-end logic (if needed) can
    drain orphans the same way Invoke-DscSet does.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSReviewUnusedParameter', '',
        Justification = 'ActivityVerb is captured by GetNewClosure(); PSSA cannot see closure-captured usage.'
    )]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Returns a callback closure; it does not itself change system state.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Test','Get','Set','Export')][string]$ActivityVerb
    )

    $state = @{
        InFlight = @{}   # resourceName -> StartedAt (utc)
        Timings  = @{}   # resourceName -> ISO 8601 duration string
    }

    $prefix = "$ActivityVerb '"

    $callback = {
        param($line)

        $st = $state
        if ($null -eq $st) { return }
        if ([string]::IsNullOrWhiteSpace($line)) { return }
        $clean = ($line -replace '\x1b\[[0-9;]*m','').Trim()
        if ($clean.Length -eq 0 -or $clean[0] -ne '{') { return }

        try {
            $evt = $clean | ConvertFrom-Json -ErrorAction Stop
        } catch { return }

        $hasActivity = $false
        foreach ($p in $evt.PSObject.Properties) {
            if ($p.Name -eq 'activity') { $hasActivity = $true; break }
        }
        if (-not $hasActivity) { return }
        $activity = [string]$evt.activity
        if (-not $activity.StartsWith($prefix)) { return }

        $rn = Get-NestedProperty -Source $evt -Path 'resourceName'
        $name = if ($null -ne $rn) {
            [string]$rn
        } elseif ($activity -match "^$([regex]::Escape($ActivityVerb)) '(?<n>[^']+)'") {
            $Matches.n
        } else { $null }
        if ([string]::IsNullOrEmpty($name)) { return }

        $hasResult = $false
        foreach ($p in $evt.PSObject.Properties) {
            if ($p.Name -eq 'result') { $hasResult = $true; break }
        }

        if (-not $st.InFlight.ContainsKey($name)) {
            $st.InFlight[$name] = (Get-Date).ToUniversalTime()
        }

        if ($hasResult -and $st.InFlight.ContainsKey($name)) {
            $startedAt = $st.InFlight[$name]
            $elapsed = (Get-Date).ToUniversalTime() - $startedAt
            $st.Timings[$name] = [System.Xml.XmlConvert]::ToString($elapsed)
            $st.InFlight.Remove($name) | Out-Null
        }
    }.GetNewClosure()

    return @{ Callback = $callback; Timings = $state.Timings; State = $state }
}

Export-ModuleMember -Function Write-SetLifecycleEvent, New-SetLifecycleCallback, New-TimingCallback
