# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

<#
.SYNOPSIS
    Projects per-real-resource compliance/diff/duration/reason from raw dsc.exe
    test/get/set JSON envelopes.
.DESCRIPTION
    Pure projection — no side effects, no IO. Operates on parsed PSCustomObject
    trees from `dsc config (test|get|set) --output-format json`.

    This module owns:
    - The envelope walkers (Get-PowerShellAdapter*, Get-ResourceCompliance,
      Get-RealResourceSummary, New-ResourceActionMap).
    - The reason-text synthesis helpers (New-ResourceReason,
      Join-ResourceReasonPhrases) used by the walkers — co-located here to keep
      Dsc.Reasons free of ResultProjection imports (the apparent
      Reasons<->ResultProjection cycle from the Phase A inventory was broken
      in this direction).
    - A tiny Get-NestedProperty helper used to collapse the repeated
      "PSObject.Properties.Name -contains 'X' -and $null -ne $X.Y -and ..."
      walks. Applied opportunistically; sites with non-trivial extraction logic
      were left intact.
.NOTES
    Behavior preserved byte-equivalent from Invoke-Enforcement.ps1 Phase A.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-IsDscAdapterWrapper {
    <#
    .SYNOPSIS
    Returns $true when a dsc.exe result entry is an adapter wrapper.
    .DESCRIPTION
    Structural, adapter-agnostic: an entry is a wrapper iff result.actualState.result
    is a non-empty collection whose every element carries non-empty .type and .name
    (the nested resources the adapter hosts). Leaf resources have no such array.
    Detecting shape rather than name means any future adapter using this envelope
    unwraps with zero code changes. $null entry returns $false.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Entry
    )

    if ($null -eq $Entry) { return $false }

    $innerArray = Get-NestedProperty -Source $Entry -Path 'result.actualState.result'
    if ($null -eq $innerArray) { return $false }

    $inners = @($innerArray)
    if ($inners.Count -eq 0) { return $false }

    foreach ($inner in $inners) {
        if ($null -eq $inner) { return $false }
        $innerType = [string](Get-NestedProperty -Source $inner -Path 'type')
        $innerName = [string](Get-NestedProperty -Source $inner -Path 'name')
        if ([string]::IsNullOrWhiteSpace($innerType) -or [string]::IsNullOrWhiteSpace($innerName)) {
            return $false
        }
    }

    return $true
}

function Get-NestedProperty {
    <#
    .SYNOPSIS
    Walks a dotted property path through a PSObject tree, returning $null (or -Default) on any miss.
    .DESCRIPTION
    Replaces the repeated pattern:
        $X.PSObject.Properties.Name -contains 'a' -and $null -ne $X.a -and
        $X.a.PSObject.Properties.Name -contains 'b' -and $null -ne $X.a.b
    with:
        $null -ne (Get-NestedProperty -Source $X -Path 'a.b')
    Returns the leaf value (or $null) — caller decides how to coerce.
    Pass -Default to substitute a fallback when the path resolves to $null
    (treats "missing" and "exists but null" identically — every existing call site
    that combined `-contains 'X' -and $null -ne $X` already conflated those cases).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Source,
        [Parameter(Mandatory)][string]$Path,
        [Parameter()][AllowNull()][object]$Default = $null
    )
    if ($null -eq $Source) { return $Default }
    $current = $Source
    foreach ($segment in $Path.Split('.')) {
        if ($null -eq $current) { return $Default }
        $prop = $current.PSObject.Properties[$segment]
        if ($null -eq $prop) { return $Default }
        $current = $prop.Value
    }
    if ($null -eq $current) { return $Default }
    return $current
}

function ConvertFrom-DscTestJson {
    <#
    .SYNOPSIS
    Parses `dsc config test --output-format json` output into normalized object.
    .DESCRIPTION
    Returns $null on parse failure (caller treats as exit-1). Returned object exposes:
    Results (array), HadErrors (bool), Duration (ISO-8601 string).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Json)

    if ([string]::IsNullOrWhiteSpace($Json)) { return $null }
    try {
        $parsed = $Json | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-Warning "Failed to parse dsc JSON output: $($_.Exception.Message)"
        return $null
    }

    $hadErrors = [bool](Get-NestedProperty -Source $parsed -Path 'hadErrors')

    $duration = 'PT0S'
    $dscDuration = Get-NestedProperty -Source $parsed -Path 'metadata.Microsoft.DSC.duration'
    if (-not [string]::IsNullOrWhiteSpace([string]$dscDuration)) {
        $duration = [string]$dscDuration
    }

    $results = @()
    $resultsRaw = Get-NestedProperty -Source $parsed -Path 'results'
    if ($null -ne $resultsRaw) { $results = @($resultsRaw) }

    return [pscustomobject]@{
        Results   = $results
        HadErrors = $hadErrors
        Duration  = $duration
    }
}

function Get-PowerShellAdapterCompliance {
    <#
    .SYNOPSIS
        Projects compliance from a PowerShell adapter envelope.
    .DESCRIPTION
        DSC 3.0 reports an adapter wrapper as structurally drifted because
        desiredState contains the requested resources while actualState
        contains adapter results. The service-owned resources inside
        actualState.result[*].properties.InDesiredState are the meaningful
        convergence signal. This reads only that boolean and never records raw
        desired/actual state values.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Entry)

    if (-not (Test-IsDscAdapterWrapper -Entry $Entry)) {
        return $null
    }

    $innerArray = Get-NestedProperty -Source $Entry -Path 'result.actualState.result'
    if ($null -eq $innerArray) { return $null }

    $innerStates = @()
    foreach ($inner in @($innerArray)) {
        if ($null -eq $inner) { continue }
        $properties = Get-NestedProperty -Source $inner -Path 'properties'
        if ($null -eq $properties) { continue }
        # kept verbose: distinguishes "InDesiredState property missing" (skip — no vote)
        # from "present but $null" (current code coerces to $false — counts as a drifted
        # vote). Get-NestedProperty conflates the two, which would change innerStates.Count
        # and the downstream "if Count -eq 0 -> return null" branch.
        $idsProp = $properties.PSObject.Properties['InDesiredState']
        if ($null -ne $idsProp) {
            $innerStates += [bool]$idsProp.Value
        }
    }

    if ($innerStates.Count -eq 0) {
        return $null
    }

    $allInnerResourcesCompliant = -not ($innerStates -contains $false)
    return [pscustomobject]@{
        InDesiredState       = $allInnerResourcesCompliant
        ChangedPropertyNames = if ($allInnerResourcesCompliant) { @() } else { @('resources') }
    }
}

function New-ResourceReason {
    <#
    .SYNOPSIS
    Builds short human-readable "reason" string for resources.jsonl.
    .DESCRIPTION
    Decision order: hadErrors+ErrorMessage > inDesiredState=true (empty) > ChangedPropertyNames >
    WrapperDiff (disclaimer) > generic fallback. Output capped at 1024 chars.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds and returns an in-memory reason string without changing external state.')]
    param(
        [Parameter(Mandatory)][bool]$InDesiredState,
        [Parameter(Mandatory)][bool]$HadErrors,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ErrorMessage,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ChangedPropertyNames,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$WrapperDiff
    )

    $reason = ''
    if ($HadErrors) {
        if (-not [string]::IsNullOrWhiteSpace($ErrorMessage)) {
            $reason = $ErrorMessage
        }
    }
    elseif ($InDesiredState) {
        $reason = ''
    }
    elseif ($ChangedPropertyNames -and $ChangedPropertyNames.Count -gt 0) {
        $reason = 'Drift in: ' + ($ChangedPropertyNames -join ', ')
    }
    elseif ($WrapperDiff -and $WrapperDiff.Count -gt 0) {
        $reason = 'Adapter wrapper drift: ' + ($WrapperDiff -join ', ') + ' (resource type does not surface per-property diff)'
    }
    else {
        $reason = 'Resource reported not in desired state (no per-property diff available)'
    }

    if ($reason.Length -gt 1024) { $reason = $reason.Substring(0, 1024) }
    return $reason
}

function Join-ResourceReasonPhrases {
    <#
    .SYNOPSIS
    Joins reason phrases into single string, capped at 1024 chars (whole-phrase boundaries).
    .DESCRIPTION
    Populates per-record `reason` string when get envelope has Reasons[]. Full structured collection
    in `reasons` field; this string is a compact JSONL summary. Appends phrases until budget exhausted,
    adds ` | … (+N more)` overflow. Returns empty string when input is empty/null.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Joins a collection of reason phrases, matching the established projection contract.')]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Phrases,
        [int]$MaxLength = 1024,
        [string]$Separator = ' | '
    )

    if (-not $Phrases -or $Phrases.Count -eq 0) { return '' }

    $sb = [System.Text.StringBuilder]::new()
    $included = 0
    foreach ($p in $Phrases) {
        if ([string]::IsNullOrEmpty($p)) { continue }
        $candidate = if ($sb.Length -eq 0) { $p } else { $Separator + $p }
        if ($sb.Length + $candidate.Length -gt $MaxLength) { break }
        [void]$sb.Append($candidate)
        $included++
    }

    $remaining = $Phrases.Count - $included
    if ($remaining -gt 0) {
        $overflow = "$Separator… (+$remaining more)"
        if ($sb.Length + $overflow.Length -le $MaxLength) {
            [void]$sb.Append($overflow)
        }
    }

    return $sb.ToString()
}

function Resolve-ResourceDuration {
    <#
    .SYNOPSIS
    Resolves per_resource duration from streaming wall-clock first, DSC metadata next, RunDuration last.
    .DESCRIPTION
    Order of precedence:
      1. -Timings hashtable + -TopLevelName lookup -- wall-clock from `--progress-format json` stderr
         (captured by New-TimingCallback). Source = 'per_resource'. This is the only path that yields real
         per_resource timing for dsc.exe 3.2.x, which does NOT populate metadata.executionInformation.duration
         or metadata.Microsoft.DSC.duration on per_resource entries during `dsc config test/get`.
      2. metadata.executionInformation.duration (DSC 3.2+ surface; not currently populated in practice).
      3. metadata.Microsoft.DSC.duration (older surface; also not populated per_resource in practice).
      4. RunDuration fallback (durationSource='inherited_from_run'). When this fires for every row, it
         signals the streaming callback wasn't wired in -- check Invoke-DscTestJson plumbing.
    -AdapterMetadata gives wrapper fallback on path 2/3 (1 inner per call).
    Returns @{ Duration; Source }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Metadata,
        [Parameter(Mandatory)][string]$RunDuration,
        [Parameter()][AllowNull()][object]$AdapterMetadata = $null,
        [Parameter()][AllowNull()][hashtable]$Timings = $null,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$TopLevelName = $null
    )

    if ($null -ne $Timings -and -not [string]::IsNullOrEmpty($TopLevelName) -and $Timings.ContainsKey($TopLevelName)) {
        $wallClock = [string]$Timings[$TopLevelName]
        if (-not [string]::IsNullOrWhiteSpace($wallClock)) {
            return @{ Duration = $wallClock; Source = 'per_resource' }
        }
    }

    foreach ($source in @($Metadata, $AdapterMetadata)) {
        if ($null -eq $source) { continue }

        $execDuration = Get-NestedProperty -Source $source -Path 'executionInformation.duration'
        if (-not [string]::IsNullOrWhiteSpace([string]$execDuration)) {
            return @{ Duration = [string]$execDuration; Source = 'per_resource' }
        }

        $dscDuration = Get-NestedProperty -Source $source -Path 'Microsoft.DSC.duration'
        if (-not [string]::IsNullOrWhiteSpace([string]$dscDuration)) {
            return @{ Duration = [string]$dscDuration; Source = 'per_resource' }
        }
    }

    return @{ Duration = $RunDuration; Source = 'inherited_from_run' }
}

function Get-PowerShellAdapterInnerResources {
    <#
    .SYNOPSIS
    Projects inner real-resource records from parsed dsc entry (test/get/set).
    .DESCRIPTION
    Adapter wrapper: walks Entry.result.actualState.result[], emits one projection/inner with adapter
    type+instance for grouping. Non-adapter: single-element array, adapter=$null. Field fallback:
    changedPropertyNames from properties.ChangedProperties ?? changedProperties ?? differingProperties ?? @();
    duration from Timings (wall-clock) ?? executionInformation ?? Microsoft.DSC ?? RunDuration; hadErrors
    from inner ?? wrapper. Inverse of Get-PowerShellAdapterCompliance (this projects N rows; that collapses
    to 1 boolean). Reasons from optional ReasonsMap (keyed by resource, populated from parallel `dsc get`).
    Property names only (not values). Phrases from module author's Get() method (human text).

    -Timings + -TopLevelName: forwarded to Resolve-ResourceDuration so per_resource wall-clock timing
    captured by New-TimingCallback wins over the (currently-unpopulated) DSC metadata paths.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Projects a collection of inner resources from one adapter envelope.')]
    param(
        [Parameter(Mandatory)][object]$Entry,
        [Parameter(Mandatory)][string]$RunDuration,
        [hashtable]$ReasonsMap = @{},
        [AllowNull()][hashtable]$Timings = $null,
        [AllowNull()][AllowEmptyString()][string]$TopLevelName = $null
    )

    $isAdapter = Test-IsDscAdapterWrapper -Entry $Entry

    $innerArray = Get-NestedProperty -Source $Entry -Path 'result.actualState.result'
    if ($isAdapter -and $null -ne $innerArray) {

        $adapterType = [string]$Entry.type
        $adapterName = [string](Get-NestedProperty -Source $Entry -Path 'name')

        $wrapperHadErrors = [bool](Get-NestedProperty -Source $Entry -Path 'result.hadErrors')

        # Wrapper-level differingProperties (e.g. ["resources","metadata"]) is the
        # only diff signal class-based PowerShell DSC modules surface — their
        # inner Test() return is just a bool. We carry it into the per_resource
        # Reason string so dashboards have *something* beyond "not in desired
        # state" when the inner result lacks a per-property diff. Filter the
        # noisy 'metadata' synthetic that DSC always reports as differing.
        $wrapperDiff = @()
        $wrapperDiffRaw = Get-NestedProperty -Source $Entry -Path 'result.differingProperties'
        if ($null -ne $wrapperDiffRaw) {
            $wrapperDiff = @($wrapperDiffRaw |
                ForEach-Object { [string]$_ } |
                Where-Object { $_ -and $_ -ne 'metadata' })
        }

        $records = @()
        foreach ($inner in @($innerArray)) {
            if ($null -eq $inner) { continue }

            $innerType = [string](Get-NestedProperty -Source $inner -Path 'type')
            $innerName = [string](Get-NestedProperty -Source $inner -Path 'name')

            $inDesired = $true
            $changed   = @()
            $properties = Get-NestedProperty -Source $inner -Path 'properties'
            # kept verbose: same "missing vs. present-but-null" distinction as
            # Get-PowerShellAdapterCompliance — preserves the $true default when the
            # property is absent, treats present-but-null as $false (drifted).
            if ($null -ne $properties) {
                $idsProp = $properties.PSObject.Properties['InDesiredState']
                if ($null -ne $idsProp) {
                    $inDesired = [bool]$idsProp.Value
                }
            }

            $changedRaw = Get-NestedProperty -Source $properties -Path 'ChangedProperties'
            $cpRaw      = Get-NestedProperty -Source $inner -Path 'changedProperties'
            $dpRaw      = Get-NestedProperty -Source $inner -Path 'differingProperties'
            if ($null -ne $changedRaw) {
                $changed = @($changedRaw | ForEach-Object { [string]$_ })
            }
            elseif ($null -ne $cpRaw) {
                $changed = @($cpRaw | ForEach-Object { [string]$_ })
            }
            elseif ($null -ne $dpRaw) {
                $changed = @($dpRaw | ForEach-Object { [string]$_ })
            }

            $hadErr = $wrapperHadErrors
            $innerErrRaw = Get-NestedProperty -Source $inner -Path 'hadErrors'
            if ($null -ne $innerErrRaw) { $hadErr = [bool]$innerErrRaw }

            $msg = ''
            $msgRaw = Get-NestedProperty -Source $inner -Path 'message'
            if ($null -ne $msgRaw) {
                $msg = [string]$msgRaw
                if ($msg.Length -gt 1024) { $msg = $msg.Substring(0, 1024) }
            }

            $innerMetadata          = Get-NestedProperty -Source $inner -Path 'metadata'
            $entryMetadataForUnwrap = Get-NestedProperty -Source $Entry -Path 'metadata'
            $resolved = Resolve-ResourceDuration -Metadata $innerMetadata -RunDuration $RunDuration `
                -AdapterMetadata $entryMetadataForUnwrap -Timings $Timings -TopLevelName $TopLevelName
            $duration = $resolved.Duration
            $durationSource = $resolved.Source

            $reason = New-ResourceReason -InDesiredState $inDesired -HadErrors $hadErr `
                -ErrorMessage $msg -ChangedPropertyNames $changed -WrapperDiff $wrapperDiff

            $key = "$adapterType|$adapterName|$innerType|$innerName"
            $reasonsArray = @()
            if ($ReasonsMap.ContainsKey($key)) {
                $reasonsArray = @($ReasonsMap[$key])
            }
            if ($reasonsArray.Count -gt 0) {
                $phrases = @($reasonsArray | ForEach-Object { [string]$_.Phrase } | Where-Object { $_ })
                if ($phrases.Count -gt 0) {
                    $joined = Join-ResourceReasonPhrases -Phrases $phrases
                    if ($joined) { $reason = $joined }
                }
            }

            # Fall back to reasons[].phrase when dsc didn't emit a message — but only on
            # non-compliant rows, so we don't surface positive-state phrases as "errors".
            if ([string]::IsNullOrEmpty($msg) -and $reasonsArray.Count -gt 0 -and (-not $inDesired -or $hadErr)) {
                $phrases = @($reasonsArray | ForEach-Object {
                    if ($null -ne $_ -and $_.PSObject.Properties.Name -contains 'Phrase') {
                        [string]$_.Phrase
                    }
                } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                if ($phrases.Count -gt 0) {
                    $msg = ($phrases -join '; ')
                    if ($msg.Length -gt 1024) { $msg = $msg.Substring(0, 1024) }
                }
            }

            $records += [pscustomobject]@{
                Adapter              = $adapterType
                AdapterInstanceName  = $adapterName
                Type                 = $innerType
                Name                 = $innerName
                InDesiredState       = $inDesired
                ChangedPropertyNames = $changed
                Reason               = $reason
                Reasons              = $reasonsArray
                HadErrors            = $hadErr
                ErrorMessage         = $msg
                Duration             = $duration
                DurationSource       = $durationSource
            }
        }

        return ,$records
    }

    # Non-adapter top-level: emit one record from the existing flat-shape
    # projection that Get-ResourceCompliance already handles.
    $compliance = Get-ResourceCompliance -Entry $Entry

    $hadErr = [bool](Get-NestedProperty -Source $Entry -Path 'result.hadErrors')
    $msg = ''
    $msgRaw = Get-NestedProperty -Source $Entry -Path 'result.message'
    if ($null -ne $msgRaw) {
        $msg = [string]$msgRaw
        if ($msg.Length -gt 1024) { $msg = $msg.Substring(0, 1024) }
    }

    $entryMetadata = Get-NestedProperty -Source $Entry -Path 'metadata'
    $resolved = Resolve-ResourceDuration -Metadata $entryMetadata -RunDuration $RunDuration `
        -Timings $Timings -TopLevelName $TopLevelName
    $duration = $resolved.Duration
    $durationSource = $resolved.Source

    $reason = New-ResourceReason -InDesiredState $compliance.InDesiredState -HadErrors $hadErr `
        -ErrorMessage $msg -ChangedPropertyNames $compliance.ChangedPropertyNames -WrapperDiff @()

    $key = "||$($compliance.Type)|$($compliance.Name)"
    $reasonsArray = @()
    if ($ReasonsMap.ContainsKey($key)) {
        $reasonsArray = @($ReasonsMap[$key])
    }
    if ($reasonsArray.Count -gt 0) {
        $phrases = @($reasonsArray | ForEach-Object { [string]$_.Phrase } | Where-Object { $_ })
        if ($phrases.Count -gt 0) {
            $joined = Join-ResourceReasonPhrases -Phrases $phrases
            if ($joined) { $reason = $joined }
        }
    }

    # Same fallback as adapter path — only on non-compliant rows.
    if ([string]::IsNullOrEmpty($msg) -and $reasonsArray.Count -gt 0 -and (-not $compliance.InDesiredState -or $hadErr)) {
        $phrases = @($reasonsArray | ForEach-Object {
            if ($null -ne $_ -and $_.PSObject.Properties.Name -contains 'Phrase') {
                [string]$_.Phrase
            }
        } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($phrases.Count -gt 0) {
            $msg = ($phrases -join '; ')
            if ($msg.Length -gt 1024) { $msg = $msg.Substring(0, 1024) }
        }
    }

    $finalInDesired = [bool]$compliance.InDesiredState

    return ,@([pscustomobject]@{
        Adapter              = $null
        AdapterInstanceName  = $null
        Type                 = $compliance.Type
        Name                 = $compliance.Name
        InDesiredState       = $finalInDesired
        ChangedPropertyNames = $compliance.ChangedPropertyNames
        Reason               = $reason
        Reasons              = $reasonsArray
        HadErrors            = $hadErr
        ErrorMessage         = $msg
        Duration             = $duration
        DurationSource       = $durationSource
    })
}

function New-ResourceActionMap {
    <#
    .SYNOPSIS
    Joins test+verify by key (adapter|adapterInstanceName|type|name) for action/event/result tuples.
    .DESCRIPTION
    Schema 1.8 splits overloaded `action` into action(test|set), event(complete|start|end),
    result(compliant|non_compliant|remediated|set_complete|set_failed). Result is the check
    VERDICT (had_errors is orthogonal, carried per-row); this map never emits 'failed' (that is
    the no-verdict quarantine path). This map covers Event='complete';
    start/end emitted separately by Write-SetLifecycleEvent. Returns hashtable keyed by composite key.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds and returns an in-memory action map without changing external state.')]
    param(
        [Parameter(Mandatory)][object]$InitialTest,
        [Parameter()][AllowNull()][object]$PostTest = $null
    )

    $key = {
        param($r)
        $a  = if ($null -eq $r.Adapter)             { '' } else { [string]$r.Adapter }
        $ai = if ($null -eq $r.AdapterInstanceName) { '' } else { [string]$r.AdapterInstanceName }
        "$a|$ai|$($r.Type)|$($r.Name)"
    }

    $initialDuration = [string](Get-NestedProperty -Source $InitialTest -Path 'Duration' -Default 'PT0S')

    # Initial pass — every entry is a test observation.
    $map = @{}
    foreach ($entry in @($InitialTest.Results)) {
        foreach ($r in (Get-PowerShellAdapterInnerResources -Entry $entry -RunDuration $initialDuration)) {
            $k = & $key $r
            # Result is the check VERDICT; had_errors is recorded orthogonally on the row.
            $result = if ($r.InDesiredState) { 'compliant' } else { 'non_compliant' }
            $map[$k] = @{ Action = 'test'; Event = 'complete'; Result = $result }
        }
    }

    if ($null -ne $PostTest) {
        $postDuration = [string](Get-NestedProperty -Source $PostTest -Path 'Duration' -Default 'PT0S')

        foreach ($entry in @($PostTest.Results)) {
            foreach ($r in (Get-PowerShellAdapterInnerResources -Entry $entry -RunDuration $postDuration)) {
                $k = & $key $r
                $priorResult = if ($map.ContainsKey($k)) { [string]$map[$k].Result } else { 'compliant' }

        if ($priorResult -eq 'compliant') {
            # No set ran for this resource — verify just confirms.
            $map[$k] = @{ Action = 'test'; Event = 'complete'; Result = 'compliant' }
        }
                elseif ($r.InDesiredState) {
                    # Verify verdict drives result; had_errors recorded orthogonally on the row.
                    $map[$k] = @{ Action = 'set'; Event = 'complete'; Result = 'set_complete' }
                }
                else {
                    $map[$k] = @{ Action = 'set'; Event = 'complete'; Result = 'set_failed' }
                }
            }
        }
    }

    return $map
}

function Get-RealResourceSummary {
    <#
    .SYNOPSIS
        Computes run-summary fields: per-real-resource counts (TotalCountReal /
        Compliant / NonCompliant) and a top-10 NonCompliantResources object array
        (`[{name, type}]`) ready for the runs.jsonl wire format.
    .DESCRIPTION
        Unwraps adapter envelopes so run log reflects per-real-resource compliance
        (not wrapper counts). Survivors are classified by the check VERDICT alone:
        InDesiredState -> Compliant, else NonCompliant. had_errors is orthogonal and
        recorded per-row, never moving a resource's bucket (a set-errored survivor whose
        verify still drifted is just NonCompliant). Returns pscustomobject with counts +
        object array.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$ParsedTest)

    $items = New-Object 'System.Collections.Generic.List[pscustomobject]'
    $total = 0
    $compliant = 0
    $nonCompliant = 0

    $runDuration = [string](Get-NestedProperty -Source $ParsedTest -Path 'Duration' -Default 'PT0S')

    foreach ($entry in @($ParsedTest.Results)) {
        foreach ($r in (Get-PowerShellAdapterInnerResources -Entry $entry -RunDuration $runDuration)) {
            $total++
            if ($r.InDesiredState) {
                $compliant++
            } else {
                $nonCompliant++
                if ($items.Count -lt 10) {
                    $items.Add([pscustomobject]@{
                        name = [string]$r.Name
                        type = [string]$r.Type
                    })
                }
            }
        }
    }

    return [pscustomobject]@{
        NonCompliantResources = $items.ToArray()
        TotalCountReal        = $total
        Compliant             = $compliant
        NonCompliant          = $nonCompliant
    }
}

function Get-FragmentBucketCounts {
    <#
    .SYNOPSIS
        Reconciles a survivor summary + the quarantine three-way split into the final five buckets.
    .DESCRIPTION
        Survivors are compliant/non_compliant by verdict (never failed). The quarantine split adds its
        own counts by abort phase: a test-abort culprit had NO verdict -> failed; a set/verify-abort
        culprit WAS evaluated as drifted -> non_compliant; dependsOn collateral / unattributable crash
        -> unevaluated. So NonCompliant == survivor + quarantine non_compliant, Failed == quarantine
        failed, Unevaluated == quarantine collateral, total == survivors + quarantine. This is an
        assignment, not a fold, so the test- and verify-path callers can both invoke it without
        double-counting.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Returns a structured set of reconciliation bucket counts.')]
    param(
        [Parameter(Mandatory)][object]$SurvivorSummary,
        [Parameter(Mandatory)][int]$QuarantineFailedCount,
        [Parameter(Mandatory)][int]$QuarantineNonCompliantCount,
        [Parameter(Mandatory)][int]$QuarantineUnevaluatedCount
    )
    [pscustomobject]@{
        Total            = $SurvivorSummary.TotalCountReal + $QuarantineFailedCount + $QuarantineNonCompliantCount + $QuarantineUnevaluatedCount
        Compliant        = $SurvivorSummary.Compliant
        NonCompliant     = $SurvivorSummary.NonCompliant + $QuarantineNonCompliantCount
        Failed           = $QuarantineFailedCount
        Unevaluated      = $QuarantineUnevaluatedCount
        NonCompliantList = @($SurvivorSummary.NonCompliantResources)
    }
}

function Test-ParsedTestHadResourceErrors {
    <#
    .SYNOPSIS
    Returns $true if any resource entry in a parsed dsc test result reported an error.
    .DESCRIPTION
    Guards the fragment-level success gate: an adapter envelope can carry result.hadErrors=$true while
    its inner results omit InDesiredState, so Get-PowerShellAdapterCompliance abstains and
    Get-ResourceCompliance defaults the entry to compliant. Without this check a fragment whose only
    signal is a per-resource error (dsc exit 0, top-level hadErrors=$false) would be scored a clean
    success and would not block its dependents. Reads only the boolean; never inspects state values.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'The predicate checks all resource errors in the parsed test result.')]
    param([Parameter(Mandatory)][object]$ParsedTest)

    foreach ($entry in @($ParsedTest.Results)) {
        if ($null -eq $entry) { continue }
        # Wrapper/leaf envelope error.
        if ([bool](Get-NestedProperty -Source $entry -Path 'result.hadErrors')) { return $true }
        # Adapter inner-resource errors: the wrapper can report hadErrors=$false while an inner
        # resource failed (the projection reads inner hadErrors for the same reason).
        $inner = Get-NestedProperty -Source $entry -Path 'result.actualState.result'
        if ($null -ne $inner) {
            foreach ($i in @($inner)) {
                if ($null -eq $i) { continue }
                if ([bool](Get-NestedProperty -Source $i -Path 'hadErrors')) { return $true }
            }
        }
    }
    return $false
}

function Get-ResourceCompliance {
    <#
    .SYNOPSIS
    Extracts per_resource compliance from parsed dsc test entry.
    .DESCRIPTION
    Prefers result.differingProperties (DSC 1.4+), falls back to result.changedProperties.
    For any adapter wrapper (detected structurally), reads inner actualState.result[*].properties.InDesiredState
    because DSC 3.0 reports wrapper envelope as drifted even when all adapted resources compliant.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Entry)

    $inDesiredState = $true
    $changedPropertyNames = @()

    $adapterCompliance = Get-PowerShellAdapterCompliance -Entry $Entry
    if ($null -ne $adapterCompliance) {
        $inDesiredState = $adapterCompliance.InDesiredState
        $changedPropertyNames = @($adapterCompliance.ChangedPropertyNames)
    }
    else {
        $r = Get-NestedProperty -Source $Entry -Path 'result'
        if ($null -ne $r) {
            $diff = Get-NestedProperty -Source $r -Path 'differingProperties'
            if ($null -eq $diff) {
                $diff = Get-NestedProperty -Source $r -Path 'changedProperties'
            }
            if ($null -ne $diff) { $changedPropertyNames = @($diff | ForEach-Object { [string]$_ }) }

            $idsRaw = Get-NestedProperty -Source $r -Path 'inDesiredState'
            if ($null -ne $idsRaw) {
                $inDesiredState = [bool]$idsRaw
            }
            elseif ($changedPropertyNames.Count -gt 0) {
                $inDesiredState = $false
            }
        }
    }

    $name = [string](Get-NestedProperty -Source $Entry -Path 'name')
    $type = [string](Get-NestedProperty -Source $Entry -Path 'type')

    return [pscustomobject]@{
        Type                 = $type
        Name                 = $name
        InDesiredState       = $inDesiredState
        ChangedPropertyNames = $changedPropertyNames
    }
}

Export-ModuleMember -Function `
    Get-NestedProperty, `
    Test-IsDscAdapterWrapper, `
    ConvertFrom-DscTestJson, `
    Get-PowerShellAdapterCompliance, `
    New-ResourceReason, `
    Join-ResourceReasonPhrases, `
    Resolve-ResourceDuration, `
    Get-PowerShellAdapterInnerResources, `
    New-ResourceActionMap, `
    Get-RealResourceSummary, `
    Get-FragmentBucketCounts, `
    Test-ParsedTestHadResourceErrors, `
    Get-ResourceCompliance
