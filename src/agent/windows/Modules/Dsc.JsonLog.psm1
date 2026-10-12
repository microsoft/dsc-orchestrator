# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

<#
.SYNOPSIS
    JSONL log sinks (runs.jsonl, resources.jsonl) and rotation.
.DESCRIPTION
    Four exported functions:
    - Write-JsonLine        : low-level BOM-less UTF-8 JSONL append.
    - Rotate-LogFile        : size-triggered rotation with bounded retention.
    - Write-ResourceRecords : per-real-resource records to resources.jsonl
                              (joins ParsedTest envelopes with ActionMap +
                              ParsedGet-derived Reasons).
    - Write-RunSummary      : single run-level row to runs.jsonl.

    Depends on:
    - Dsc.HostContext (Get-HostIdentity)
    - Dsc.ResultProjection (Get-PowerShellAdapterInnerResources)
    - Dsc.Reasons (Get-PowerShellAdapterInnerReasons)

    Tunables (LogRotationBytes, MaxRotatedLogs) are now Rotate-LogFile
    parameters with defaults equal to the Phase A entry-script $script: vars.
.NOTES
    Behavior preserved byte-equivalent from Invoke-Enforcement.ps1 Phase A.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'


function Write-JsonLine {
    <#
    .SYNOPSIS
    Appends one JSON line to .jsonl using BOM-less UTF-8.
    .DESCRIPTION
    PS 5.1 `Add-Content -Encoding UTF8` writes BOM; PS7+ does not. Bypass cmdlet,
    use [IO.File]::AppendAllText with a BOM-less encoder for JSONL compatibility. Depth 10, compressed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Record
    )
    $line = $Record | ConvertTo-Json -Compress -Depth 10
    [System.IO.File]::AppendAllText(
        $Path,
        $line + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function New-ResourceRecord {
    <#
    .SYNOPSIS
    Canonical resources.jsonl record builder -- single source of truth for the schema.
    .DESCRIPTION
    Returns an [ordered] hashtable in canonical field order so Write-ResourceRecords
    (bulk test/verify rows) and Write-SetLifecycleEvent (per-event set start/end rows)
    emit byte-equivalent shapes. Keeps local JSONL consumers from having to branch on
    row type for common fields.

    Field order (schema 3.0):
      schema_version, run_id, TimeGenerated, Computer, group, role,
      config_version, configuration_hash, fragment, trigger, phase, adapter, adapter_instance_name,
      resource_type, resource_name, in_desired_state, reasons,
      action, event, result, had_errors, error_message,
      duration, duration_source, completion_kind

    Schema rigidity: EVERY row of resources.jsonl carries EVERY field above. No
    conditional omission. Absent values are JSON null so the local JSONL stream
    keeps one stable row shape.

    Casing: snake_case everywhere EXCEPT TimeGenerated and Computer, retained for
    compatibility with the existing local JSONL record shape.

    Schema 3.0 uses nullable group/role metadata. The package builder includes
    configured values and the configuration hash in metadata.json.

    Schema 2.0 changes vs 1.5:
      - resource-id REMOVED (type+name combo is the natural identity).
      - Dropped the per-resource ordinal field; resource_name remains the lifecycle correlation key.
      - All field keys snake_cased (except TimeGenerated and Computer).
      - resource_type now always emitted (null when absent) instead of conditionally
        omitted alongside resource-id.
      - duration and completion_kind always emitted (null on rows that don't
        carry them) instead of conditionally omitted.
      - Vocabulary: duration_source values are 'per_resource' / 'inherited_from_run'.
      - Reasons[].code / .phrase keys stay camelCase since dsc.exe emits them that way.

    Phase enum: {test, verify, set}. Action enum: {test, set}. Event enum:
    {complete, start, end}. Validators here are the only place these enums live --
    keep them in lockstep with the schema version represented by this module.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates and returns an in-memory JSONL record; it does not write or mutate external state.')]
    param(
        [Parameter(Mandatory)][string]$SchemaVersion,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$Timestamp,
        [Parameter(Mandatory)][string]$Computer,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Group,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Role,
        [Parameter(Mandatory)][string]$ConfigVersion,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$ConfigurationHash = $null,
        [Parameter(Mandatory)][ValidateSet('initial','scheduled')][string]$Trigger,
        [Parameter(Mandatory)][ValidateSet('test','verify','set')][string]$Phase,
        [AllowNull()][AllowEmptyString()][string]$FragmentName = '',
        [AllowNull()][AllowEmptyString()][string]$Adapter = '',
        [AllowNull()][AllowEmptyString()][string]$AdapterInstanceName = '',
        [AllowNull()][AllowEmptyString()][string]$ResourceType = '',
        [Parameter(Mandatory)][string]$ResourceName,
        [AllowNull()][object]$InDesiredState = $null,
        [AllowEmptyCollection()][object[]]$Reasons = @(),
        [Parameter(Mandatory)][ValidateSet('test','set')][string]$Action,
        [Parameter(Mandatory)][ValidateSet('complete','start','end')][string]$LifecycleEvent,
        [AllowNull()][AllowEmptyString()][string]$Result = '',
        [bool]$HadErrors = $false,
        [AllowNull()][AllowEmptyString()][string]$ErrorMessage = '',
        [AllowNull()][AllowEmptyString()][string]$Duration = '',
        [Parameter(Mandatory)][ValidateSet('per_resource','inherited_from_run')][string]$DurationSource,
        [ValidateSet('','observed','synthetic')][string]$CompletionKind = ''
    )

    # Normalize null to empty-string for string fields, empty-array for dynamic fields.
    # Schema 2.0 rigidity: every field is always emitted. Nullable string fields use
    # "" and nullable dynamic fields use [] where the record contract requires them.
    #
    # Exception: metadata fields (group, role, configuration_hash) stay null when absent.
    # Duration stays null when
    # absent (set-start rows) since "" would not parse as ISO 8601.
    $groupOut            = if ([string]::IsNullOrEmpty($Group))            { $null } else { $Group }
    $roleOut             = if ([string]::IsNullOrEmpty($Role))             { $null } else { $Role }
    $configurationHashOut = if ([string]::IsNullOrEmpty($ConfigurationHash)) { $null } else { $ConfigurationHash }
    $adapterOut          = if ([string]::IsNullOrEmpty($Adapter))             { '' } else { $Adapter }
    $adapterInstanceOut  = if ([string]::IsNullOrEmpty($AdapterInstanceName)) { '' } else { $AdapterInstanceName }
    $resourceTypeOut     = if ([string]::IsNullOrEmpty($ResourceType))        { '' } else { $ResourceType }
    $resultOut           = if ([string]::IsNullOrEmpty($Result))              { '' } else { $Result }
    $errorMessageOut     = if ([string]::IsNullOrEmpty($ErrorMessage))        { '' } else { $ErrorMessage }
    $durationOut         = if ([string]::IsNullOrEmpty($Duration))            { '' } else { $Duration }
    $completionKindOut   = if ([string]::IsNullOrEmpty($CompletionKind))      { '' } else { $CompletionKind }
    $fragmentOut         = if ([string]::IsNullOrEmpty($FragmentName))        { '' } else { $FragmentName }
    $reasonsOut          = if ($null -eq $Reasons -or $Reasons.Count -eq 0)   { ,@() } else { ,$Reasons }

    $rec = [ordered]@{
        'schema_version'        = $SchemaVersion
        'run_id'                = $RunId
        'TimeGenerated'         = $Timestamp
        'Computer'              = $Computer
        'group'                 = $groupOut
        'role'                  = $roleOut
        'config_version'        = $ConfigVersion
        'configuration_hash'   = $configurationHashOut
        'fragment'              = $fragmentOut
        'trigger'               = $Trigger
        'phase'                 = $Phase
        'adapter'               = $adapterOut
        'adapter_instance_name' = $adapterInstanceOut
        'resource_type'         = $resourceTypeOut
        'resource_name'         = $ResourceName
        'in_desired_state'      = $InDesiredState
        'reasons'               = $reasonsOut
        'action'                = $Action
        'event'                 = $LifecycleEvent
        'result'                = $resultOut
        'had_errors'            = $HadErrors
        'error_message'         = $errorMessageOut
        'duration'              = $durationOut
        'duration_source'       = $DurationSource
        'completion_kind'       = $completionKindOut
    }

    return $rec
}

function Write-ResourceRecord {
    <#
    .SYNOPSIS
    Builds + appends a single resources.jsonl row via the canonical constructor.
    .DESCRIPTION
    Convenience wrapper for per-event callers (set lifecycle). Mirrors the
    New-ResourceRecord parameter surface plus -Path. Bulk callers loop over
    inner resources and call New-ResourceRecord + Write-JsonLine directly to
    avoid re-parsing every parameter per iteration.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$SchemaVersion,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$Timestamp,
        [Parameter(Mandatory)][string]$Computer,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Group,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Role,
        [Parameter(Mandatory)][string]$ConfigVersion,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$ConfigurationHash = $null,
        [Parameter(Mandatory)][ValidateSet('initial','scheduled')][string]$Trigger,
        [Parameter(Mandatory)][ValidateSet('test','verify','set')][string]$Phase,
        [AllowNull()][AllowEmptyString()][string]$FragmentName = '',
        [AllowNull()][AllowEmptyString()][string]$Adapter = '',
        [AllowNull()][AllowEmptyString()][string]$AdapterInstanceName = '',
        [AllowNull()][AllowEmptyString()][string]$ResourceType = '',
        [Parameter(Mandatory)][string]$ResourceName,
        [AllowNull()][object]$InDesiredState = $null,
        [AllowEmptyCollection()][object[]]$Reasons = @(),
        [Parameter(Mandatory)][ValidateSet('test','set')][string]$Action,
        [Parameter(Mandatory)][ValidateSet('complete','start','end')][string]$LifecycleEvent,
        [AllowNull()][AllowEmptyString()][string]$Result = '',
        [bool]$HadErrors = $false,
        [AllowNull()][AllowEmptyString()][string]$ErrorMessage = '',
        [AllowNull()][AllowEmptyString()][string]$Duration = '',
        [Parameter(Mandatory)][ValidateSet('per_resource','inherited_from_run')][string]$DurationSource,
        [ValidateSet('','observed','synthetic')][string]$CompletionKind = ''
    )
    $bound = @{} + $PSBoundParameters
    [void]$bound.Remove('Path')
    $record = New-ResourceRecord @bound
    Write-JsonLine -Path $Path -Record $record
}

function Rotate-LogFile {
    <#
    .SYNOPSIS
    Rotates log when it exceeds RotationBytes. Keeps MaxRotated.
    .DESCRIPTION
    Renamed from Invoke-LogRotation for p3 seam contract. PSUseApprovedVerbs suppressed
    ("Rotate" is canonical log-rotation term, referenced by tests+docs).
    Defaults match the Phase A $script: tunables (50MB / 2 rotated).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs','', Justification='Named per p3 seam contract; "Rotate" is the canonical log-rotation verb.')]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter()][long]$RotationBytes = 50MB,
        [Parameter()][int]$MaxRotated = 2
    )

    if (-not (Test-Path -LiteralPath $Path)) { return }
    $size = (Get-Item -LiteralPath $Path).Length
    if ($size -le $RotationBytes) { return }

    if ($PSCmdlet.ShouldProcess($Path, 'Rotate log')) {
        for ($i = $MaxRotated; $i -ge 1; $i--) {
            $older = "${Path}.${i}"
            if ($i -eq $MaxRotated -and (Test-Path -LiteralPath $older)) {
                Remove-Item -LiteralPath $older -Force
            }
            elseif (Test-Path -LiteralPath $older) {
                $newer = "${Path}.$($i + 1)"
                Move-Item -LiteralPath $older -Destination $newer -Force
            }
        }
        Move-Item -LiteralPath $Path -Destination "${Path}.1" -Force
    }
}

function Write-ResourceRecords {
    <#
    .SYNOPSIS
    Seam: appends one resources.jsonl line per real resource from ParsedTest.
    .DESCRIPTION
    Iterates ParsedTest.Results, unwraps adapter envelopes via Get-PowerShellAdapterInnerResources, writes
    BOM-less UTF-8 JSONL via the canonical New-ResourceRecord constructor. Action from ActionMap keyed by
    '<adapter>|<adapterInstanceName>|<type>|<name>'. ParsedGet (optional, schema 1.3+): layers rich Reasons[]
    from `dsc config get`.

    -Timings (optional, schema 1.5): hashtable keyed by top-level resource name (Entry.name) with ISO 8601
    duration strings, captured from `--progress-format json` stderr by New-TimingCallback. When provided,
    per_resource wall-clock duration replaces the JSON-metadata fallback that dsc.exe currently doesn't
    populate (duration_source='per_resource' instead of 'inherited_from_run' for every row).

    Schema 1.5 emits two orthogonal categorization fields:
      - `trigger` (run-level): what fired this run -- 'initial' (first run after deploy) or
        'scheduled' (periodic task tick). Same value across every record in a single run.
      - `phase` (within-run): which pass within the run produced this record -- 'test' (initial
        drift detection) or 'verify' (post-remediation re-test). Distinct values within a run.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Writes one JSONL record per resource; the plural name is the established collection-writer contract.')]
    param(
        [Parameter(Mandatory)][object]$ParsedTest,
        [Parameter(Mandatory)][hashtable]$ActionMap,
        [Parameter(Mandatory)][ValidateSet('test','verify')][string]$Phase,
        [Parameter(Mandatory)][ValidateSet('initial','scheduled')][string]$Trigger,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$SchemaVersion,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$Timestamp,
        [Parameter(Mandatory)][string]$ConfigVersion,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Group,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Role,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$ConfigurationHash = $null,
        [AllowNull()][AllowEmptyString()][string]$FragmentName = '',
        [AllowNull()][object]$ParsedGet = $null,
        [AllowNull()][hashtable]$Timings = $null
    )

    $identity = Get-HostIdentity
    $runDuration = [string](Get-NestedProperty -Source $ParsedTest -Path 'Duration' -Default 'PT0S')

    $reasonsMap = Get-PowerShellAdapterInnerReasons -ParsedGet $ParsedGet

    foreach ($entry in @($ParsedTest.Results)) {
        $topLevelName = [string](Get-NestedProperty -Source $entry -Path 'name')
        $inners = Get-PowerShellAdapterInnerResources -Entry $entry -RunDuration $runDuration `
            -ReasonsMap $reasonsMap -Timings $Timings -TopLevelName $topLevelName
        foreach ($r in $inners) {
            $a  = if ($null -eq $r.Adapter)             { '' } else { [string]$r.Adapter }
            $ai = if ($null -eq $r.AdapterInstanceName) { '' } else { [string]$r.AdapterInstanceName }
            $key = "$a|$ai|$($r.Type)|$($r.Name)"
            $outcome = if ($ActionMap.ContainsKey($key)) {
                $ActionMap[$key]
            } else {
                @{ Action = 'test'; Event = 'complete'; Result = 'unknown' }
            }

            $reasonsForEmit = @()
            if ($null -ne $r.Reasons) {
                foreach ($rsn in @($r.Reasons)) {
                    if ($null -eq $rsn) { continue }
                    $reasonsForEmit += [ordered]@{
                        code   = [string]$rsn.Code
                        phrase = [string]$rsn.Phrase
                    }
                }
            }
            # Fallback: synthesize reason when no Get-derived reasons exist (errors, wrapper-drift,
            # adapters without Reasons[] support).
            if ($reasonsForEmit.Count -eq 0 -and -not [string]::IsNullOrEmpty([string]$r.Reason)) {
                $reasonsForEmit += [ordered]@{
                    code   = 'synthetic'
                    phrase = [string]$r.Reason
                }
            }

            $errMessageOut = [string]$r.ErrorMessage

            $record = New-ResourceRecord `
                -SchemaVersion $SchemaVersion -RunId $RunId -Timestamp $Timestamp `
                -Computer $identity.HostName -Group $Group -Role $Role `
                -ConfigVersion $ConfigVersion -ConfigurationHash $ConfigurationHash -Trigger $Trigger -Phase $Phase `
                -FragmentName $FragmentName `
                -Adapter $a -AdapterInstanceName $ai `
                -ResourceType ([string]$r.Type) -ResourceName ([string]$r.Name) `
                -InDesiredState $r.InDesiredState -Reasons $reasonsForEmit `
                -Action ([string]$outcome.Action) -LifecycleEvent ([string]$outcome.Event) -Result ([string]$outcome.Result) `
                -HadErrors ([bool]$r.HadErrors) -ErrorMessage $errMessageOut `
                -Duration ([string]$r.Duration) -DurationSource ([string]$r.DurationSource)
            Write-JsonLine -Path $Path -Record $record
        }
    }
}

function Write-FinalStateResourceRecords {
    <#
    .SYNOPSIS
    Single post-convergence emit of a fragment's final-state per-resource rows.
    .DESCRIPTION
    Emits the final test projection's `test` rows and, when a set ran, the final verify projection's
    `verify` rows -- today's two-phase emission as one call keyed on the final result, so only the
    final pass's rows reach resources.jsonl. Pass -FinalTestGet / -FinalVerifyGet to populate
    `reasons`. Verify rows emit only when -FinalVerify is non-null (a set ran and verify parsed).
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Writes the final test/verify JSONL record collection for a fragment.')]
    param(
        [Parameter(Mandatory)][object]$FinalTest,
        [Parameter(Mandatory)][AllowNull()][object]$FinalTestGet,
        [Parameter(Mandatory)][string]$TestTimestamp,
        [Parameter(Mandatory)][ValidateSet('initial','scheduled')][string]$Trigger,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$SchemaVersion,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$ConfigVersion,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Group,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Role,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$ConfigurationHash = $null,
        [Parameter()][AllowNull()][hashtable]$TestTimings = $null,
        [Parameter()][AllowNull()][object]$FinalVerify = $null,
        [Parameter()][AllowNull()][object]$FinalVerifyGet = $null,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$VerifyTimestamp = '',
        [Parameter()][AllowNull()][hashtable]$VerifyTimings = $null,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$FragmentName = ''
    )

    $testActionMap = New-ResourceActionMap -InitialTest $FinalTest
    Write-ResourceRecords -ParsedTest $FinalTest -ParsedGet $FinalTestGet -ActionMap $testActionMap -Phase 'test' -Trigger $Trigger `
        -Path $Path -SchemaVersion $SchemaVersion -RunId $RunId `
        -Timestamp $TestTimestamp -ConfigVersion $ConfigVersion `
        -Group $Group -Role $Role -ConfigurationHash $ConfigurationHash -FragmentName $FragmentName `
        -Timings $TestTimings

    if ($null -ne $FinalVerify) {
        $verifyActionMap = New-ResourceActionMap -InitialTest $FinalTest -PostTest $FinalVerify
        Write-ResourceRecords -ParsedTest $FinalVerify -ParsedGet $FinalVerifyGet -ActionMap $verifyActionMap -Phase 'verify' -Trigger $Trigger `
            -Path $Path -SchemaVersion $SchemaVersion -RunId $RunId `
            -Timestamp $VerifyTimestamp -ConfigVersion $ConfigVersion `
            -Group $Group -Role $Role -ConfigurationHash $ConfigurationHash -FragmentName $FragmentName `
            -Timings $VerifyTimings
    }
}

function Write-RunSummary {
    <#
    .SYNOPSIS
    Appends one run-level summary row to runs.jsonl (schema 3.0).
    .DESCRIPTION
    Schema 3.0 is snake_case on the wire (schema_version / run_id / group /
    role / config_version / configuration_hash / dsc_exe_version / mode / trigger / outcome /
    total_resources / compliant_resources / non_compliant_count / failed_count /
    skipped_count / unevaluated_count / had_errors / test_duration / set_duration /
    verify_duration / total_duration / exit_code / error / non_compliant_resources /
    erroring_resources) with two PascalCase exceptions: TimeGenerated and Computer,
    retained for compatibility with existing local JSONL readers.

    Schema rigidity: every row of runs.jsonl emits every field listed above.
    Absent values are JSON null to keep a stable record shape.

    Schema 3.0 uses portable group/role metadata and records the package configuration hash.

    Schema 2.3 change vs 2.2:
      - Added: enforcement_id (string) — orchestrator-minted id, always populated every run;
      groups multiple rows only when a reboot chains runs into one enforcement effort.
      - Added: reboot_count (int) — orchestrator-owned reboot loop counter, always populated (0
      when the run has not rebooted). `outcome` (reboot_pending/reboot_loop_detected) already
      carries reboot state; reboot_kind/reboot_requested_by stay on-disk in restart-state.json /
      the registry contract only -- not included in run-summary rows.
    Schema 2.2 change vs 2.1:
      - Added: failed_count (int) — resources that ERRORED (threw/terminated at test or set).
      It joins the reconciliation peers; the invariant holds:
      total_resources == compliant_resources + non_compliant_count + failed_count + skipped_count + unevaluated_count.
    Schema 2.1 changes vs 2.0:
      - Added: skipped_count (int) — dependency-gated resources, never evaluated by design.
      - Added: unevaluated_count (int) — resources that could not be evaluated (crash/collateral).

    `trigger` (run-level cause-of-fire) records what initiated this run: 'initial'
    (first run after deploy) or 'scheduled' (periodic task tick).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Timestamp,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ConfigVersion,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$ConfigurationHash = $null,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RunId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SchemaVersion,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Group,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Role,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$DscExeVersion,
        [Parameter(Mandatory)][ValidateSet('enforce','audit')][string]$Mode,
        [Parameter(Mandatory)][ValidateSet('initial','scheduled')][string]$Trigger,
        [Parameter(Mandatory)][ValidateSet('compliant','drift_observed','drift_persisted','remediated','remediation_failed','resource_resolution_failed','skipped','error','aborted','reboot_pending','reboot_loop_detected')][string]$Outcome,
        # Per-real-resource counts (unwrapped from adapter envelopes).
        [Parameter(Mandatory)][int]$TotalResources,
        [Parameter(Mandatory)][int]$CompliantResources,
        [Parameter(Mandatory)][int]$NonCompliantCount,
        [Parameter(Mandatory)][bool]$HadErrors,
        # Schema 2.0: four pass-specific durations + total replace the single
        # last-pass 'Duration' field from 1.5. Each is ISO 8601 duration string.
        # Pass 'PT0S' for passes that didn't run (e.g. SetDuration='PT0S' on a
        # compliant run). All four are Mandatory so every call site populates them
        # consistently -- schema consistency for local JSONL consumers.
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$TestDuration,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$SetDuration,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$VerifyDuration,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$TotalDuration,
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$ErrorMessage,
        # Single object array `[{name,type}]`.
        [Parameter(Mandatory=$false)][AllowEmptyCollection()][object[]]$NonCompliantResources = @(),
        # Crash-class failures (resource threw inside adapter wrapper), distinct
        # from drift. Populated via stderr extraction on failures only.
        [Parameter(Mandatory=$false)][AllowEmptyCollection()][object[]]$ErroringResources = @(),
        # 5-bucket reconciliation peers (defaulted so early call sites need no changes).
        [int]$SkippedCount    = 0,
        [int]$UnevaluatedCount = 0,
        [int]$FailedCount     = 0,
        # Schema 2.3: orchestrator-owned reboot loop counter; the caller always supplies a value,
        # this default only covers call sites/tests that omit it.
        [int]$RebootCount = 0,
        # Schema 2.3: enforcement-effort id, always populated by the caller (every run mints/carries
        # one; it groups multiple rows only when a reboot chains runs). Empty default only covers
        # call sites/tests that omit it.
        [string]$EnforcementId = ''
    )
    $identity = Get-HostIdentity
    # Belt-and-suspenders cap (Get-RealResourceSummary already caps at 10).
    $cappedNonCompliant = @($NonCompliantResources | Select-Object -First 10)

    # Normalize null to empty-string for string fields and empty-array for dynamic fields,
    # matching the stable local JSONL record contract.
    #
    # Exception: metadata fields (group, role, configuration_hash, dsc_exe_version) stay null when
    # absent since they carry topological info. Durations stay null when the pass didn't
    # run ("" would not parse as ISO 8601).
    $groupOut            = if ([string]::IsNullOrEmpty($Group))            { $null } else { $Group }
    $roleOut             = if ([string]::IsNullOrEmpty($Role))             { $null } else { $Role }
    $configurationHashOut = if ([string]::IsNullOrEmpty($ConfigurationHash)) { $null } else { $ConfigurationHash }
    $dscExeVersionOut    = if ([string]::IsNullOrEmpty($DscExeVersion))    { $null } else { $DscExeVersion }
    $testDurationOut     = if ([string]::IsNullOrEmpty($TestDuration))     { $null } else { $TestDuration }
    $setDurationOut      = if ([string]::IsNullOrEmpty($SetDuration))      { $null } else { $SetDuration }
    $verifyDurationOut   = if ([string]::IsNullOrEmpty($VerifyDuration))   { $null } else { $VerifyDuration }
    $totalDurationOut    = if ([string]::IsNullOrEmpty($TotalDuration))    { $null } else { $TotalDuration }
    $enforcementIdOut    = if ([string]::IsNullOrEmpty($EnforcementId))   { $null } else { $EnforcementId }
    $errorMessageOut     = if ([string]::IsNullOrEmpty($ErrorMessage))     { '' } else { $ErrorMessage }
    $nonCompliantOut     = if ($null -eq $NonCompliantResources -or $NonCompliantResources.Count -eq 0) { ,@() } else { ,$cappedNonCompliant }
    $erroringOut         = if ($null -eq $ErroringResources -or $ErroringResources.Count -eq 0)         { ,@() } else { ,@($ErroringResources) }

    $record = [ordered]@{
        'schema_version'          = $SchemaVersion
        'run_id'                  = $RunId
        'TimeGenerated'           = $Timestamp
        'Computer'                = $identity.HostName
        'group'                   = $groupOut
        'role'                    = $roleOut
        'config_version'          = $ConfigVersion
        'configuration_hash'     = $configurationHashOut
        'dsc_exe_version'         = $dscExeVersionOut
        'mode'                    = $Mode
        'trigger'                 = $Trigger
        'outcome'                 = $Outcome
        'total_resources'         = $TotalResources
        'compliant_resources'     = $CompliantResources
        'non_compliant_count'     = $NonCompliantCount
        'failed_count'            = $FailedCount
        'skipped_count'           = $SkippedCount
        'unevaluated_count'       = $UnevaluatedCount
        'had_errors'              = $HadErrors
        'test_duration'           = $testDurationOut
        'set_duration'            = $setDurationOut
        'verify_duration'         = $verifyDurationOut
        'total_duration'          = $totalDurationOut
        'exit_code'               = $ExitCode
        'error'                   = $errorMessageOut
        'non_compliant_resources' = $nonCompliantOut
        'erroring_resources'      = $erroringOut
        'reboot_count'            = $RebootCount
        'enforcement_id'          = $enforcementIdOut
    }
    Write-JsonLine -Path $Path -Record $record
}

function Write-FragmentUnevaluatedRows {
    <#
    .SYNOPSIS
    Emits one per-declared-resource resources.jsonl row when a TEST-phase fragment fails before
    dsc.exe can produce parseable per-resource results. The row result is the attributed culprit's
    ABORT PHASE: a test-abort culprit had no verdict -> result='failed'; a set/verify-abort culprit
    was evaluated as drifted -> result='non_compliant'; collateral / unattributable crash -> 'unevaluated'.
    .DESCRIPTION
    Enumerates the fragment's declared resources (Get-DeclaredResources) and writes one row each
    via Write-ResourceRecord, so failed fragments stop contributing zero resources to telemetry.
    When dsc.exe's last progress activity names the failing resource (-FailingResourceName), exactly
    the matching row is the attributed culprit; the remaining rows get result='unevaluated',
    had_errors=$false and an empty error_message. The single-name path is inherently a test-phase
    abort, so its attributed culprit is result='failed'. When the failing name is empty or matches no
    declared resource, all rows are flagged had_errors=$true (the original safety net) but stay
    result='unevaluated' -- an unattributable crash is not a per-resource break. error_message is a
    compact JSON object. Falls back to a single 'unknown' result='unevaluated' row when
    enumeration throws or yields nothing.

    -CulpritMap (optional) supports MULTIPLE genuinely-failing resources in one fragment, each with
    its OWN real dsc error excerpt AND abort phase (the strip-and-retry quarantine path). It is a
    hashtable of wrapperName -> @{ Excerpt = <string>; Phase = <'test'|'set'|'verify'> } (a bare
    string value is tolerated and treated as a test-phase excerpt). When supplied and non-empty it
    takes precedence over -FailingResourceName/-Excerpt: every declared row whose Name/AdapterInstance
    is a key is an attributed culprit (had_errors=$true + its own excerpt) classified by phase
    (test -> 'failed', set/verify -> 'non_compliant'); every other row (dependsOn collateral, stripped
    but never named by dsc) gets result='unevaluated', had_errors=$false and an empty error_message.
    Returns [pscustomobject]@{ EmittedCount = <int>; FailedCount = <int>; NonCompliantCount = <int>; UnevaluatedCount = <int>; Fallback = <bool> }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Writes one unevaluated row per declared resource.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'FailingResourceType', Justification='Accepted for caller parity with -FailingResourceName; the two call sites forward $signal.ResourceType alongside the name from the failure signal. Reserved for type-aware culprit attribution.')]
    param(
        [Parameter(Mandatory)][string]$FragmentName,
        [Parameter(Mandatory)][string]$FragmentPath,
        [Parameter(Mandatory)][ValidateSet('parse_fail','resource_resolution','yaml_enum_failed')][string]$Cause,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Excerpt,
        [Parameter(Mandatory)][int]$NativeExitCode,
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][string]$ResourcesLogPath,
        [Parameter()][AllowEmptyString()][string]$FailingResourceName = '',
        [Parameter()][AllowEmptyString()][string]$FailingResourceType = '',
        [Parameter()][AllowNull()][hashtable]$CulpritMap = $null
    )

    foreach ($k in 'SchemaVersion','RunId','Timestamp','Computer','Group','Role','ConfigVersion','Trigger') {
        if (-not $Context.ContainsKey($k)) {
            throw "Write-FragmentUnevaluatedRows: Context missing required key '$k'."
        }
    }
    $configurationHash = if ($Context.ContainsKey('ConfigurationHash')) { $Context['ConfigurationHash'] } else { $null }

    # Cap excerpt before serializing so we never truncate the JSON mid-value (breaks parse_json()).
    $buildErrorMessage = {
        param([string]$RowCause, [string]$RowFragment, [string]$RowExcerpt, [int]$RowExitCode)
        $msg = [ordered]@{
            tag              = 'fragment_unevaluated'
            cause            = $RowCause
            fragment         = $RowFragment
            excerpt          = $RowExcerpt
            native_exit_code = $RowExitCode
        }
        if ($msg.excerpt.Length -gt 1500) { $msg.excerpt = $msg.excerpt.Substring(0, 1500) + '...[truncated]' }
        try {
            $json = $msg | ConvertTo-Json -Compress -Depth 4
        } catch {
            $json = '{"tag":"fragment_unevaluated","cause":"' + $RowCause + '","fragment":"' + $RowFragment + '","note":"excerpt_serialization_failed"}'
        }
        # Belt-and-suspenders; excerpt cap should keep us well under this.
        if ($json.Length -gt 2000) { $json = $json.Substring(0, 2000) }
        return $json
    }

    $declared = @()
    $fallback = $false
    try {
        $declared = @(Get-DeclaredResources -Path $FragmentPath)
    } catch {
        $fallback = $true
    }
    if (-not $fallback -and $declared.Count -eq 0) { $fallback = $true }

    $emitted = 0
    $failedCount = 0
    $nonCompliantCount = 0
    $unevaluatedCount = 0
    if ($fallback) {
        # Literal 'unknown' type/name, NOT the fragment name (73c6926a contaminated grouping panels).
        Write-ResourceRecord -Path $ResourcesLogPath `
            -SchemaVersion $Context.SchemaVersion -RunId $Context.RunId -Timestamp $Context.Timestamp `
            -Computer $Context.Computer -Group $Context.Group -Role $Context.Role `
            -ConfigVersion $Context.ConfigVersion -ConfigurationHash $configurationHash -Trigger $Context.Trigger -Phase 'test' `
            -FragmentName $FragmentName `
            -ResourceType 'unknown' -ResourceName 'unknown' -InDesiredState $null `
            -Action 'test' -LifecycleEvent 'complete' -Result 'unevaluated' -HadErrors $true `
            -ErrorMessage (& $buildErrorMessage 'yaml_enum_failed' $FragmentName $Excerpt $NativeExitCode) -Duration '' -DurationSource 'inherited_from_run'
        # Enumeration failed -> we never reached any resource: unattributable, stays unevaluated.
        $emitted = 1
        $unevaluatedCount = 1
    } else {
        # Multi-culprit map mode: each named culprit carries its own real dsc excerpt + abort phase;
        # everything else (dependsOn collateral) is had_errors=false/empty. Takes precedence over the
        # single -FailingResourceName path when supplied.
        $culpritLookup = $null
        if ($null -ne $CulpritMap -and $CulpritMap.Count -gt 0) {
            # Value is @{ Excerpt; Phase }; a bare string is tolerated as a test-phase excerpt.
            $culpritLookup = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($key in $CulpritMap.Keys) {
                $val = $CulpritMap[$key]
                $ex = ''
                $ph = 'test'
                if ($val -is [string]) {
                    $ex = [string]$val
                } elseif ($val -is [System.Collections.IDictionary]) {
                    if ($val.Contains('Excerpt')) { $ex = [string]$val['Excerpt'] }
                    if ($val.Contains('Phase') -and -not [string]::IsNullOrEmpty([string]$val['Phase'])) { $ph = [string]$val['Phase'] }
                } else {
                    $exP = $val.PSObject.Properties['Excerpt']; if ($null -ne $exP) { $ex = [string]$exP.Value }
                    $phP = $val.PSObject.Properties['Phase'];   if ($null -ne $phP -and -not [string]::IsNullOrEmpty([string]$phP.Value)) { $ph = [string]$phP.Value }
                }
                $culpritLookup[[string]$key] = @{ Excerpt = $ex; Phase = $ph }
            }
        }

        if ($null -ne $culpritLookup) {
            foreach ($d in $declared) {
                $adapter   = if ([string]::IsNullOrEmpty([string]$d.Adapter))         { '' } else { [string]$d.Adapter }
                $adapterI  = if ([string]::IsNullOrEmpty([string]$d.AdapterInstance)) { '' } else { [string]$d.AdapterInstance }
                $resName   = if ([string]::IsNullOrEmpty([string]$d.Name))            { 'unknown' } else { [string]$d.Name }
                $matchKey  = $null
                if ($culpritLookup.ContainsKey($resName)) { $matchKey = $resName }
                elseif (-not [string]::IsNullOrEmpty($adapterI) -and $culpritLookup.ContainsKey($adapterI)) { $matchKey = $adapterI }
                $isCulprit = ($null -ne $matchKey)
                # Bucket = abort phase: test-abort culprit had NO verdict -> failed; set/verify-abort
                # culprit WAS evaluated as drifted -> non_compliant; collateral never reached -> unevaluated.
                $culpritPhase = if ($isCulprit) { [string]$culpritLookup[$matchKey].Phase } else { '' }
                $isTestAbort  = $isCulprit -and ($culpritPhase -eq 'test')
                $rowResult    = if (-not $isCulprit) { 'unevaluated' } elseif ($isTestAbort) { 'failed' } else { 'non_compliant' }
                # A set/verify-abort culprit carries the drift verdict it obtained at test; test-abort/collateral have none.
                $rowInDesired = if ($isCulprit -and -not $isTestAbort) { $false } else { $null }
                $rowError  = if ($isCulprit) { & $buildErrorMessage $Cause $FragmentName ([string]$culpritLookup[$matchKey].Excerpt) $NativeExitCode } else { '' }
                Write-ResourceRecord -Path $ResourcesLogPath `
                    -SchemaVersion $Context.SchemaVersion -RunId $Context.RunId -Timestamp $Context.Timestamp `
                    -Computer $Context.Computer -Group $Context.Group -Role $Context.Role `
                    -ConfigVersion $Context.ConfigVersion -ConfigurationHash $configurationHash -Trigger $Context.Trigger -Phase 'test' `
                    -FragmentName $FragmentName `
                    -Adapter $adapter -AdapterInstanceName $adapterI `
                    -ResourceType ([string]$d.Type) -ResourceName $resName -InDesiredState $rowInDesired `
                    -Action 'test' -LifecycleEvent 'complete' -Result $rowResult -HadErrors ([bool]$isCulprit) `
                    -ErrorMessage $rowError -Duration '' -DurationSource 'inherited_from_run'
                if (-not $isCulprit) { $unevaluatedCount++ } elseif ($isTestAbort) { $failedCount++ } else { $nonCompliantCount++ }
                $emitted++
            }
            return [pscustomobject]@{ EmittedCount = $emitted; FailedCount = $failedCount; NonCompliantCount = $nonCompliantCount; UnevaluatedCount = $unevaluatedCount; Fallback = $fallback }
        }

        $errorMessage = & $buildErrorMessage $Cause $FragmentName $Excerpt $NativeExitCode

        # Match dsc.exe's last progress activity name against declared rows. AdapterInstance is the
        # top-level wrapper name (= failing name for these one-resource-per-wrapper fragments).
        $hasFailingName = -not [string]::IsNullOrEmpty($FailingResourceName)
        $anyMatch = $false
        if ($hasFailingName) {
            foreach ($d in $declared) {
                if (([string]$d.Name -eq $FailingResourceName) -or ([string]$d.AdapterInstance -eq $FailingResourceName)) {
                    $anyMatch = $true; break
                }
            }
        }
        # Attribute to one culprit only when we have a name that actually matches a declared row;
        # otherwise fall back to flagging every row so the error JSON is never silently dropped.
        $attribute = $hasFailingName -and $anyMatch

        foreach ($d in $declared) {
            $adapter   = if ([string]::IsNullOrEmpty([string]$d.Adapter))         { '' } else { [string]$d.Adapter }
            $adapterI  = if ([string]::IsNullOrEmpty([string]$d.AdapterInstance)) { '' } else { [string]$d.AdapterInstance }
            $resName   = if ([string]::IsNullOrEmpty([string]$d.Name))            { 'unknown' } else { [string]$d.Name }
            $isCulprit = (-not $attribute) -or ($resName -eq $FailingResourceName) -or ($adapterI -eq $FailingResourceName)
            # Only an ATTRIBUTED culprit is 'failed'; the no-attribution safety net flags had_errors
            # but stays 'unevaluated' (unattributable crash, not a per-resource break).
            $isAttributedCulprit = $attribute -and (($resName -eq $FailingResourceName) -or ($adapterI -eq $FailingResourceName))
            $rowResult = if ($isAttributedCulprit) { 'failed' } else { 'unevaluated' }
            $rowError  = if ($isCulprit) { $errorMessage } else { '' }
            Write-ResourceRecord -Path $ResourcesLogPath `
                -SchemaVersion $Context.SchemaVersion -RunId $Context.RunId -Timestamp $Context.Timestamp `
                -Computer $Context.Computer -Group $Context.Group -Role $Context.Role `
                -ConfigVersion $Context.ConfigVersion -ConfigurationHash $configurationHash -Trigger $Context.Trigger -Phase 'test' `
                -FragmentName $FragmentName `
                -Adapter $adapter -AdapterInstanceName $adapterI `
                -ResourceType ([string]$d.Type) -ResourceName $resName -InDesiredState $null `
                -Action 'test' -LifecycleEvent 'complete' -Result $rowResult -HadErrors ([bool]$isCulprit) `
                -ErrorMessage $rowError -Duration '' -DurationSource 'inherited_from_run'
            if ($isAttributedCulprit) { $failedCount++ } else { $unevaluatedCount++ }
            $emitted++
        }
    }

    return [pscustomobject]@{ EmittedCount = $emitted; FailedCount = $failedCount; NonCompliantCount = $nonCompliantCount; UnevaluatedCount = $unevaluatedCount; Fallback = $fallback }
}

function Write-FragmentSkippedRows {
    <#
    .SYNOPSIS
    Emits one 'skipped' resources.jsonl row per declared resource for a dependency-gated fragment.
    .DESCRIPTION
    Mirror of Write-FragmentUnevaluatedRows for the dependency-skip path. Enumerates the fragment's
    declared resources (Get-DeclaredResources) and writes one row each with result='skipped',
    had_errors=$false, in_desired_state=$null, fragment set. error_message is a compact JSON
    {tag, fragment, blockedBy, reason} (plus optional blockedByDetail:[{name,status}] when supplied)
    matching the unevaluated shape for local JSONL consumers.
    Falls back to a single 'unknown' row when enumeration throws or yields nothing.
    Returns [pscustomobject]@{ EmittedCount = <int>; Fallback = <bool> }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Writes one skipped row per declared resource.')]
    param(
        [Parameter(Mandatory)][string]$FragmentName,
        [Parameter(Mandatory)][string]$FragmentPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$BlockedBy,
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][string]$ResourcesLogPath,
        [Parameter()][AllowEmptyCollection()][object[]]$BlockedByDetail = @()
    )

    foreach ($k in 'SchemaVersion','RunId','Timestamp','Computer','Group','Role','ConfigVersion','Trigger') {
        if (-not $Context.ContainsKey($k)) {
            throw "Write-FragmentSkippedRows: Context missing required key '$k'."
        }
    }
    $configurationHash = if ($Context.ContainsKey('ConfigurationHash')) { $Context['ConfigurationHash'] } else { $null }

    # Serialize the skip reason as compact JSON for local JSONL consumers. blockedByDetail
    # is a NEW field (existing blockedBy consumers are unaffected). Never substring serialized JSON — that
    # produces invalid JSON; instead fall through progressively smaller, still-valid payloads (marked
    # 'truncated') until one fits the budget.
    $budget = 2000
    $buildSkipMsg = {
        param([string[]]$Names, [object[]]$Detail, [bool]$Truncated)
        $o = [ordered]@{ tag = 'fragment_skipped'; fragment = $FragmentName; blockedBy = @($Names); reason = 'dependency_gate' }
        if (@($Detail).Count -gt 0) {
            $o['blockedByDetail'] = @($Detail | ForEach-Object { [ordered]@{ name = [string]$_.name; status = [string]$_.status } })
        }
        if ($Truncated) { $o['truncated'] = $true }
        $o | ConvertTo-Json -Compress -Depth 5
    }
    $errorMessage = try {
        $names  = @($BlockedBy)
        $detail = @($BlockedByDetail)
        $variants = @(
            (& $buildSkipMsg $names $detail $false),
            (& $buildSkipMsg @($names | Select-Object -First 25) @($detail | Select-Object -First 25) $true),
            (& $buildSkipMsg @($names | Select-Object -First 5) @() $true),
            (& $buildSkipMsg @() @() $true)
        )
        $picked = $variants | Where-Object { $_.Length -le $budget } | Select-Object -First 1
        if ($null -ne $picked) { $picked } else { '{"tag":"fragment_skipped","reason":"dependency_gate","truncated":true}' }
    } catch {
        '{"tag":"fragment_skipped","reason":"dependency_gate"}'
    }

    $declared = @()
    $fallback = $false
    try {
        $declared = @(Get-DeclaredResources -Path $FragmentPath)
    } catch {
        $fallback = $true
    }
    if (-not $fallback -and $declared.Count -eq 0) { $fallback = $true }

    $emitted = 0
    if ($fallback) {
        Write-ResourceRecord -Path $ResourcesLogPath `
            -SchemaVersion $Context.SchemaVersion -RunId $Context.RunId -Timestamp $Context.Timestamp `
            -Computer $Context.Computer -Group $Context.Group -Role $Context.Role `
            -ConfigVersion $Context.ConfigVersion -ConfigurationHash $configurationHash -Trigger $Context.Trigger -Phase 'test' `
            -FragmentName $FragmentName `
            -ResourceType 'unknown' -ResourceName 'unknown' -InDesiredState $null `
            -Action 'test' -LifecycleEvent 'complete' -Result 'skipped' -HadErrors $false `
            -ErrorMessage $errorMessage -Duration '' -DurationSource 'inherited_from_run'
        $emitted = 1
    } else {
        foreach ($d in $declared) {
            $adapter  = if ([string]::IsNullOrEmpty([string]$d.Adapter))         { '' } else { [string]$d.Adapter }
            $adapterI = if ([string]::IsNullOrEmpty([string]$d.AdapterInstance)) { '' } else { [string]$d.AdapterInstance }
            $resName  = if ([string]::IsNullOrEmpty([string]$d.Name))            { 'unknown' } else { [string]$d.Name }
            Write-ResourceRecord -Path $ResourcesLogPath `
                -SchemaVersion $Context.SchemaVersion -RunId $Context.RunId -Timestamp $Context.Timestamp `
                -Computer $Context.Computer -Group $Context.Group -Role $Context.Role `
                -ConfigVersion $Context.ConfigVersion -ConfigurationHash $configurationHash -Trigger $Context.Trigger -Phase 'test' `
                -FragmentName $FragmentName `
                -Adapter $adapter -AdapterInstanceName $adapterI `
                -ResourceType ([string]$d.Type) -ResourceName $resName -InDesiredState $null `
                -Action 'test' -LifecycleEvent 'complete' -Result 'skipped' -HadErrors $false `
                -ErrorMessage $errorMessage -Duration '' -DurationSource 'inherited_from_run'
            $emitted++
        }
    }

    return [pscustomobject]@{ EmittedCount = $emitted; Fallback = $fallback }
}

function Write-FragmentRebootUnreachedRows {
    <#
    .SYNOPSIS
    Emits one 'unevaluated' resources.jsonl row per declared resource for a fragment left unrun
    by an actual-reboot early loop break (actual-reboot path only).
    .DESCRIPTION
    Sibling of Write-FragmentSkippedRows for the reboot case: a committed Immediate reboot request
    breaks the fragment loop, so every later fragment was never evaluated this run -- not skipped
    by a dependency gate. error_message is a compact JSON {tag, fragment, reason} so
    JSONL readers can parse it. Falls back to a single 'unknown' row when enumeration throws or yields
    nothing. Returns [pscustomobject]@{ EmittedCount = <int>; Fallback = <bool> }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Writes one unevaluated row per resource left unrun by a reboot.')]
    param(
        [Parameter(Mandatory)][string]$FragmentName,
        [Parameter(Mandatory)][string]$FragmentPath,
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][string]$ResourcesLogPath
    )

    foreach ($k in 'SchemaVersion','RunId','Timestamp','Computer','Group','Role','ConfigVersion','Trigger') {
        if (-not $Context.ContainsKey($k)) {
            throw "Write-FragmentRebootUnreachedRows: Context missing required key '$k'."
        }
    }
    $configurationHash = if ($Context.ContainsKey('ConfigurationHash')) { $Context['ConfigurationHash'] } else { $null }

    $errorMessage = try {
        $msgObj = [ordered]@{
            tag      = 'fragment_reboot_unreached'
            fragment = $FragmentName
            reason   = 'reboot_pending_unreached'
        }
        $j = $msgObj | ConvertTo-Json -Compress -Depth 4
        if ($j.Length -gt 2000) { $j = $j.Substring(0, 2000) }
        $j
    } catch {
        '{"tag":"fragment_reboot_unreached","fragment":"' + $FragmentName + '","reason":"reboot_pending_unreached"}'
    }

    $declared = @()
    $fallback = $false
    try {
        $declared = @(Get-DeclaredResources -Path $FragmentPath)
    } catch {
        $fallback = $true
    }
    if (-not $fallback -and $declared.Count -eq 0) { $fallback = $true }

    $emitted = 0
    if ($fallback) {
        Write-ResourceRecord -Path $ResourcesLogPath `
            -SchemaVersion $Context.SchemaVersion -RunId $Context.RunId -Timestamp $Context.Timestamp `
            -Computer $Context.Computer -Group $Context.Group -Role $Context.Role `
            -ConfigVersion $Context.ConfigVersion -ConfigurationHash $configurationHash -Trigger $Context.Trigger -Phase 'test' `
            -FragmentName $FragmentName `
            -ResourceType 'unknown' -ResourceName 'unknown' -InDesiredState $null `
            -Action 'test' -LifecycleEvent 'complete' -Result 'unevaluated' -HadErrors $false `
            -ErrorMessage $errorMessage -Duration '' -DurationSource 'inherited_from_run'
        $emitted = 1
    } else {
        foreach ($d in $declared) {
            $adapter  = if ([string]::IsNullOrEmpty([string]$d.Adapter))         { '' } else { [string]$d.Adapter }
            $adapterI = if ([string]::IsNullOrEmpty([string]$d.AdapterInstance)) { '' } else { [string]$d.AdapterInstance }
            $resName  = if ([string]::IsNullOrEmpty([string]$d.Name))            { 'unknown' } else { [string]$d.Name }
            Write-ResourceRecord -Path $ResourcesLogPath `
                -SchemaVersion $Context.SchemaVersion -RunId $Context.RunId -Timestamp $Context.Timestamp `
                -Computer $Context.Computer -Group $Context.Group -Role $Context.Role `
                -ConfigVersion $Context.ConfigVersion -ConfigurationHash $configurationHash -Trigger $Context.Trigger -Phase 'test' `
                -FragmentName $FragmentName `
                -Adapter $adapter -AdapterInstanceName $adapterI `
                -ResourceType ([string]$d.Type) -ResourceName $resName -InDesiredState $null `
                -Action 'test' -LifecycleEvent 'complete' -Result 'unevaluated' -HadErrors $false `
                -ErrorMessage $errorMessage -Duration '' -DurationSource 'inherited_from_run'
            $emitted++
        }
    }

    return [pscustomobject]@{ EmittedCount = $emitted; Fallback = $fallback }
}

Export-ModuleMember -Function Write-JsonLine, Rotate-LogFile, Write-ResourceRecords, Write-FinalStateResourceRecords, Write-RunSummary, New-ResourceRecord, Write-ResourceRecord, Write-FragmentUnevaluatedRows, Write-FragmentSkippedRows, Write-FragmentRebootUnreachedRows
