<#
.SYNOPSIS
    Top-level wrapper filtering — selects which wrappers to feed into
    `dsc config set` based on observed drift + transitive dependsOn.
.DESCRIPTION
    Pure line-based YAML manipulation: no schema model, no token parser.
    Mirrors the composer's indent/line-slicing strategy — fragile by design,
    but auditable line-for-line.

    Depends on Dsc.ResultProjection (Get-PowerShellAdapterCompliance).
.NOTES
    Behavior preserved byte-equivalent from Invoke-Enforcement.ps1 Phase A.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'


function Get-DriftedTopLevelResourceNames {
    <#
    .SYNOPSIS
        Returns top-level resource names whose inner resources aren't all compliant.
    .DESCRIPTION
        Used to skip already-compliant wrappers during remediation. Without filter,
        `dsc config set` re-Gets/re-Sets every wrapped resource even when Test proved
        compliant (observed: ~25 min wasted work when 1 of 22 wrappers drifted).
        For PowerShell adapter: walks actualState.result[*].InDesiredState. For
        non-adapter: reads result.inDesiredState. Falls back to "drifted" when ambiguous.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Returns the set of drifted resource names used by the filtering contract.')]
    param([Parameter(Mandatory)][object]$ParsedTest)

    $names = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @($ParsedTest.Results)) {
        $entryName = [string](Get-NestedProperty -Source $entry -Path 'name')
        if ([string]::IsNullOrWhiteSpace($entryName)) { continue }

        $isDrifted = $true  # default: include if we can't prove otherwise
        $compliance = Get-PowerShellAdapterCompliance -Entry $entry
        if ($null -ne $compliance) {
            $isDrifted = -not [bool]$compliance.InDesiredState
        } else {
            # Only override default when result.inDesiredState is actually present;
            # missing/null leaves $isDrifted=$true (Get-NestedProperty conflates missing-vs-null).
            $idsRaw = Get-NestedProperty -Source $entry -Path 'result.inDesiredState'
            if ($null -ne $idsRaw) { $isDrifted = -not [bool]$idsRaw }
        }

        if ($isDrifted) { $names.Add($entryName) }
    }
    return ,$names.ToArray()
}

function Split-YamlFlowListItem {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    $items = New-Object System.Collections.Generic.List[string]
    $itemStart = 0
    $parenthesisDepth = 0
    $quote = [char]0

    for ($i = 0; $i -lt $Text.Length; $i++) {
        $character = $Text[$i]
        if ($quote -ne [char]0) {
            if ($quote -eq [char]34 -and $character -eq [char]92) {
                $i++
                continue
            }
            if ($character -eq $quote) {
                if ($quote -eq [char]39 -and $i + 1 -lt $Text.Length -and $Text[$i + 1] -eq [char]39) {
                    $i++
                    continue
                }
                $quote = [char]0
            }
            continue
        }

        if ($character -eq [char]34 -or $character -eq [char]39) {
            $quote = $character
        }
        elseif ($character -eq [char]40) {
            $parenthesisDepth++
        }
        elseif ($character -eq [char]41 -and $parenthesisDepth -gt 0) {
            $parenthesisDepth--
        }
        elseif ($character -eq [char]44 -and $parenthesisDepth -eq 0) {
            $items.Add($Text.Substring($itemStart, $i - $itemStart))
            $itemStart = $i + 1
        }
    }

    $items.Add($Text.Substring($itemStart))
    return ,$items.ToArray()
}

function Get-WrapperDependsOnNames {
    <#
    .SYNOPSIS
    Extracts wrapper `dependsOn:` references to other top-level wrappers.
    .DESCRIPTION
    Returns list of plain wrapper names the wrapper depends on (bare name or `[resourceId('Type','Name')]` form).
    Used by New-FilteredConfigForResources for transitive expansion (without this, dsc rejects filtered config
    when drifted wrapper depends on excluded compliant wrapper). Detects `dependsOn:` at rootIndent+2 (avoids
    false positives from inner `properties.resources[].dependsOn`). Supports inline flow, block list, single scalar forms.
    Multi-line flow arrays not supported (throws -> caller falls back to full config). Case-insensitive per composer.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Returns the dependency names used to expand the filtered resource set.')]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$WrapperLines,
        [Parameter(Mandatory)][int]$WrapperRootIndent
    )

    $names = New-Object System.Collections.Generic.List[string]
    $childIndent = $WrapperRootIndent + 2
    $keyRegex = ('^\s{{{0}}}dependsOn:\s*(?<value>.*?)\s*(?:#.*)?$' -f $childIndent)

    # Resolve single dependsOn item to wrapper name:
    # bare-name -> bare-name, "bare-name" -> bare-name, '[resourceId('Type','Name')]' -> Name
    $resolveItem = {
        param([string]$Raw)
        $s = $Raw.Trim().Trim("'`"")
        if ($s -match '^\[\s*resourceId\s*\(\s*[''"][^''"]*[''"]\s*,\s*[''"](?<name>[^''"]+)[''"]\s*\)\s*\]$') {
            return [string]$Matches['name']
        }
        return $s
    }

    for ($i = 0; $i -lt $WrapperLines.Count; $i++) {
        if ($WrapperLines[$i] -notmatch $keyRegex) { continue }
        $value = [string]$Matches['value']

        if ($value.StartsWith('[')) {
            if ($value -match '^\[\s*(?<inner>.*?)\s*\]\s*$') {
                $inner = [string]$Matches['inner']
                if ($inner) {
                    foreach ($item in (Split-YamlFlowListItem -Text $inner)) {
                        $clean = & $resolveItem $item
                        if ($clean) { $names.Add($clean) }
                    }
                }
            } else {
                throw "Get-WrapperDependsOnNames: multi-line flow dependsOn arrays are not supported (offending line: '$($WrapperLines[$i])'). Reformat as block list or single-line flow."
            }
        } elseif (-not [string]::IsNullOrWhiteSpace($value)) {
            $clean = & $resolveItem $value
            if ($clean) { $names.Add($clean) }
        } else {
            for ($j = $i + 1; $j -lt $WrapperLines.Count; $j++) {
                $next = $WrapperLines[$j]
                if ([string]::IsNullOrWhiteSpace($next)) { continue }
                if ($next -match '^\s*#') { continue }
                if ($next -match '^(?<lindent>\s*)-\s+(?<item>.+?)\s*(?:#.*)?$') {
                    $listIndent = ([string]$Matches['lindent']).Length
                    if ($listIndent -gt $childIndent) {
                        $clean = & $resolveItem ([string]$Matches['item'])
                        if ($clean) { $names.Add($clean) }
                    } else {
                        break
                    }
                } else {
                    break
                }
            }
        }
    }
    return ,$names.ToArray()
}

function New-FilteredConfigForResources {
    <#
    .SYNOPSIS
    Writes temp DSCv3 config with only named top-level resources + transitive dependsOn wrappers.
    .DESCRIPTION
    Two-pass: 1) build wrapper map (case-insensitive), 2) BFS-expand from drifted set via dependsOn
    (cycle-safe HashSet), 3) emit header+wrappers in original order. Transitive inclusion required
    (dsc.exe validates dependsOn at load: missing wrapper = hard fail). Line-based parsing mirrors
    the prepared-fragment indent logic. Preserves the fragment header lines (e.g. `$schema`) that
    precede `resources:` verbatim. Throws on no resources line, no matches, or dangling
    dependsOn. Returns temp file path; caller cleans.

    -NoDependsOnExpansion skips the Pass-2 forward BFS and emits EXACTLY the named wrappers,
    verbatim. Used by the strip-and-retry recovery telemetry path: the quarantine set passed in
    is already closed under REVERSE dependsOn (culprits + their dependents), so forward-expanding
    it would pull surviving UPSTREAM wrappers (the ones a culprit dependsOn) back in -- producing
    spurious rows and double-counts. The no-expansion config is enumerated for telemetry only and
    is never fed to dsc.exe, so a dangling dependsOn to a survivor is harmless.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Returns the generated temporary config path; writing the disposable invocation input is required by the caller.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Writes a disposable temporary config required by the current enforcement invocation; skipping it would leave the caller without an input file.')]
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string[]]$ResourceNames,
        [Parameter()][switch]$NoDependsOnExpansion
    )

    if ($ResourceNames.Count -eq 0) {
        throw "New-FilteredConfigForResources: ResourceNames must contain at least one entry."
    }

    $lines = [System.IO.File]::ReadAllLines($SourcePath)
    $resourcesLineIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^resources:\s*(?:#.*)?$') {
            $resourcesLineIdx = $i
            break
        }
    }
    if ($resourcesLineIdx -lt 0) {
        throw "Cannot find top-level 'resources:' line in $SourcePath."
    }

    # Collect dash-prefixed lines after resources:; find minimum indent (composer's ChildIndent).
    # Composer writes resources: last, so EOF terminates section.
    $dashEntries = New-Object System.Collections.Generic.List[object]
    for ($i = $resourcesLineIdx + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^(?<indent>\s*)-\s+') {
            $dashEntries.Add([pscustomobject]@{
                Index  = $i
                Indent = ([string]$Matches.indent).Length
            })
        }
    }
    if ($dashEntries.Count -eq 0) {
        throw "No resource items found after 'resources:' in $SourcePath."
    }

    $rootIndent = ($dashEntries | Measure-Object -Property Indent -Minimum).Minimum
    $rootItemIndexes = @($dashEntries | Where-Object { $_.Indent -eq $rootIndent } | ForEach-Object { $_.Index })

    # Same regex pair composer uses: name on dash line or next line @ rootIndent+2.
    $nameOnDashRegex = '^\s*-\s+name:\s*(?<value>.+?)\s*(?:#.*)?$'
    $nameOnNextLineRegex = ('^\s{{{0}}}name:\s*(?<value>.+?)\s*(?:#.*)?$' -f ($rootIndent + 2))

    # Pass 1: build wrapper map. Names are case-insensitive (matches composer).
    $wrappers = New-Object System.Collections.Generic.List[object]
    $wrapperByName = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::OrdinalIgnoreCase)
    for ($n = 0; $n -lt $rootItemIndexes.Count; $n++) {
        $itemStart = $rootItemIndexes[$n]
        $itemEnd = if ($n -lt ($rootItemIndexes.Count - 1)) {
            $rootItemIndexes[$n + 1] - 1
        } else {
            $lines.Count - 1
        }

        $name = $null
        for ($k = $itemStart; $k -le $itemEnd; $k++) {
            if ($lines[$k] -match $nameOnDashRegex -or $lines[$k] -match $nameOnNextLineRegex) {
                $name = ([string]$Matches['value']).Trim().Trim("'`"")
                break
            }
        }
        if ([string]::IsNullOrWhiteSpace($name)) { continue }

        $w = [pscustomobject]@{
            Name  = $name
            Start = $itemStart
            End   = $itemEnd
            Lines = @($lines[$itemStart..$itemEnd])
        }
        $wrappers.Add($w)
        if (-not $wrapperByName.ContainsKey($name)) { $wrapperByName[$name] = $w }
    }

    # Pass 2: BFS expand wanted set via dependsOn (transitive, cycle-safe, case-insensitive).
    # Skipped entirely under -NoDependsOnExpansion: the wanted set is then EXACTLY ResourceNames
    # (verbatim emit), for telemetry enumeration of an already-reverse-closed quarantine set.
    $wantedSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $queue = New-Object 'System.Collections.Generic.Queue[string]'
    foreach ($n in $ResourceNames) {
        if ($wantedSet.Add($n)) { $queue.Enqueue($n) }
    }
    if (-not $NoDependsOnExpansion) {
        while ($queue.Count -gt 0) {
            $cur = $queue.Dequeue()
            if (-not $wrapperByName.ContainsKey($cur)) {
                throw "Filtered config cannot be built: wrapper '$cur' is referenced (drifted or via dependsOn) but not present in $SourcePath."
            }
            $deps = Get-WrapperDependsOnNames -WrapperLines $wrapperByName[$cur].Lines -WrapperRootIndent $rootIndent
            foreach ($d in $deps) {
                if ([string]::IsNullOrWhiteSpace($d)) { continue }
                if ($wantedSet.Add($d)) { $queue.Enqueue($d) }
            }
        }
    }

    # Pass 3: emit header + matching wrappers in original order.
    $output = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -le $resourcesLineIdx; $i++) {
        $output.Add($lines[$i])
    }

    $matched = 0
    foreach ($w in $wrappers) {
        if (-not $wantedSet.Contains($w.Name)) { continue }
        foreach ($line in $w.Lines) { $output.Add($line) }
        $matched++
    }

    if ($matched -eq 0) {
        throw "No top-level resources matched names {$([string]::Join(', ', $ResourceNames))} in $SourcePath."
    }

    $tempPath = [System.IO.Path]::Combine(
        [System.IO.Path]::GetTempPath(),
        ('dsc-set-subset-' + [System.Guid]::NewGuid().ToString('N') + '.yaml'))
    [System.IO.File]::WriteAllText($tempPath, ($output -join "`n"), [System.Text.UTF8Encoding]::new($false))
    return $tempPath
}

function New-StrippedConfigExcludingResources {
    <#
    .SYNOPSIS
    Writes a temp DSCv3 config containing every top-level wrapper EXCEPT the named ones
    and any wrapper that (transitively) dependsOn them.
    .DESCRIPTION
    The inverse of New-FilteredConfigForResources. Used by the strip-and-retry recovery
    layer (Dsc.Recovery.psm1, flag-gated): when dsc.exe aborts a fragment on a single
    attributable resource, this emits a config with that resource and its reverse-dependsOn
    closure removed, so the surviving siblings can be re-Tested/Set.

    Three-pass, mirroring New-FilteredConfigForResources line-slicing exactly (no schema
    model, no YAML re-serialization -> surviving wrappers are copied verbatim, preserving
    value-type rendering):
      1) build the wrapper map (case-insensitive, original order),
      2) build reverse adjacency (who-depends-on-me) from Get-WrapperDependsOnNames and
         BFS the excluded set to its transitive reverse closure (cycle-safe HashSet),
      3) emit header + every wrapper NOT in the closure, in original order.

    Soundness: keep-set = AllWrappers - reverseClosure(Exclude). No kept wrapper can depend
    on an excluded one, so the emitted config never has a dangling dependsOn.

    Throws when the source has no resources line, an excluded name is absent, or the keep-set
    would be empty (the recovery loop reads the empty-keep-set throw as its "nothing left" bail).
    Returns [pscustomobject]@{ Path; ExcludedNames; KeptNames }. Caller cleans the temp file.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Returns excluded/kept resource-name collections in the established recovery contract.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Writes a disposable temporary config required by recovery; skipping it would break the current enforcement pass.')]
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$ExcludeResourceNames
    )

    if ($ExcludeResourceNames.Count -eq 0) {
        throw "New-StrippedConfigExcludingResources: ExcludeResourceNames must contain at least one entry."
    }

    $lines = [System.IO.File]::ReadAllLines($SourcePath)
    $resourcesLineIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^resources:\s*(?:#.*)?$') {
            $resourcesLineIdx = $i
            break
        }
    }
    if ($resourcesLineIdx -lt 0) {
        throw "Cannot find top-level 'resources:' line in $SourcePath."
    }

    $dashEntries = New-Object System.Collections.Generic.List[object]
    for ($i = $resourcesLineIdx + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^(?<indent>\s*)-\s+') {
            $dashEntries.Add([pscustomobject]@{
                Index  = $i
                Indent = ([string]$Matches.indent).Length
            })
        }
    }
    if ($dashEntries.Count -eq 0) {
        throw "No resource items found after 'resources:' in $SourcePath."
    }

    $rootIndent = ($dashEntries | Measure-Object -Property Indent -Minimum).Minimum
    $rootItemIndexes = @($dashEntries | Where-Object { $_.Indent -eq $rootIndent } | ForEach-Object { $_.Index })

    $nameOnDashRegex = '^\s*-\s+name:\s*(?<value>.+?)\s*(?:#.*)?$'
    $nameOnNextLineRegex = ('^\s{{{0}}}name:\s*(?<value>.+?)\s*(?:#.*)?$' -f ($rootIndent + 2))

    # Pass 1: wrapper map (case-insensitive, preserves original order).
    $wrappers = New-Object System.Collections.Generic.List[object]
    $wrapperByName = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::OrdinalIgnoreCase)
    for ($n = 0; $n -lt $rootItemIndexes.Count; $n++) {
        $itemStart = $rootItemIndexes[$n]
        $itemEnd = if ($n -lt ($rootItemIndexes.Count - 1)) {
            $rootItemIndexes[$n + 1] - 1
        } else {
            $lines.Count - 1
        }

        $name = $null
        for ($k = $itemStart; $k -le $itemEnd; $k++) {
            if ($lines[$k] -match $nameOnDashRegex -or $lines[$k] -match $nameOnNextLineRegex) {
                $name = ([string]$Matches['value']).Trim().Trim("'`"")
                break
            }
        }
        if ([string]::IsNullOrWhiteSpace($name)) { continue }

        $w = [pscustomobject]@{
            Name  = $name
            Lines = @($lines[$itemStart..$itemEnd])
        }
        $wrappers.Add($w)
        if (-not $wrapperByName.ContainsKey($name)) { $wrapperByName[$name] = $w }
    }

    foreach ($x in $ExcludeResourceNames) {
        if (-not $wrapperByName.ContainsKey($x)) {
            throw "New-StrippedConfigExcludingResources: excluded wrapper '$x' is not present in $SourcePath."
        }
    }

    # Pass 2: reverse adjacency (dependent -> {wrappers it depends on}), then BFS the
    # excluded set to its transitive reverse closure. A wrapper joins the closure when it
    # depends on anything already in the closure.
    $dependsOnMap = New-Object 'System.Collections.Generic.Dictionary[string,string[]]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($w in $wrappers) {
        $deps = Get-WrapperDependsOnNames -WrapperLines $w.Lines -WrapperRootIndent $rootIndent
        $dependsOnMap[$w.Name] = @($deps | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    $closure = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($x in $ExcludeResourceNames) { [void]$closure.Add($x) }

    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($w in $wrappers) {
            if ($closure.Contains($w.Name)) { continue }
            foreach ($dep in $dependsOnMap[$w.Name]) {
                if ($closure.Contains($dep)) {
                    if ($closure.Add($w.Name)) { $changed = $true }
                    break
                }
            }
        }
    }

    # Pass 3: emit header + every wrapper NOT in the closure, in original order.
    $output = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -le $resourcesLineIdx; $i++) {
        $output.Add($lines[$i])
    }

    $kept = New-Object System.Collections.Generic.List[string]
    foreach ($w in $wrappers) {
        if ($closure.Contains($w.Name)) { continue }
        foreach ($line in $w.Lines) { $output.Add($line) }
        $kept.Add($w.Name)
    }

    if ($kept.Count -eq 0) {
        throw "New-StrippedConfigExcludingResources: stripping {$([string]::Join(', ', $ExcludeResourceNames))} and dependents leaves no resources in $SourcePath."
    }

    $tempPath = [System.IO.Path]::Combine(
        [System.IO.Path]::GetTempPath(),
        ('dsc-recovery-' + [System.Guid]::NewGuid().ToString('N') + '.yaml'))
    [System.IO.File]::WriteAllText($tempPath, ($output -join "`n"), [System.Text.UTF8Encoding]::new($false))

    return [pscustomobject]@{
        Path          = $tempPath
        ExcludedNames = @($closure)
        KeptNames     = @($kept.ToArray())
    }
}

function Get-WrapperInnerTypeMap {
    <#
    .SYNOPSIS
    Returns @{ wrapperName = @{ AdapterType; InnerType } } for adapter wrappers in the fragment.
    .DESCRIPTION
    dsc.exe progress events surface only the wrapper type, not the inner resource type.
    The set lifecycle callback needs both so set-phase rows align with the test/verify
    bulk projection. Wrapper detection is structural: a root resource is a wrapper iff
    it nests a `resources:` list under its properties — no adapter type strings enumerated.
    Line-based parse (same convention as New-FilteredConfigForResources). Schema 1.7+
    guarantees one inner per wrapper. Returns empty on any parse anomaly.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$ConfigFilePath)

    $result = [ordered]@{}
    if (-not (Test-Path -LiteralPath $ConfigFilePath -PathType Leaf)) { return $result }

    try {
        $lines = [System.IO.File]::ReadAllLines($ConfigFilePath)
    } catch {
        return $result
    }

    $resourcesIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^resources:\s*(?:#.*)?$') { $resourcesIdx = $i; break }
    }
    if ($resourcesIdx -lt 0) { return $result }

    $dashEntries = New-Object System.Collections.Generic.List[object]
    for ($i = $resourcesIdx + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^(?<indent>\s*)-\s+') {
            $dashEntries.Add([pscustomobject]@{ Index = $i; Indent = ([string]$Matches.indent).Length })
        }
    }
    if ($dashEntries.Count -eq 0) { return $result }

    $rootIndent = ($dashEntries | Measure-Object -Property Indent -Minimum).Minimum
    $rootItems = @($dashEntries | Where-Object { $_.Indent -eq $rootIndent } | ForEach-Object { $_.Index })

    $childIndent     = $rootIndent + 2
    $innerListIndent = $childIndent + 2
    $innerDashIndent = $innerListIndent + 2
    $innerKeyIndent  = $innerDashIndent + 2

    $typeAtChild       = '^\s{' + $childIndent      + '}type\s*:\s*(?<value>.+?)\s*(?:#.*)?$'
    $nameAtChild       = '^\s{' + $childIndent      + '}name\s*:\s*(?<value>.+?)\s*(?:#.*)?$'
    $nameOnDash        = '^\s*-\s+name\s*:\s*(?<value>.+?)\s*(?:#.*)?$'
    $typeOnDash        = '^\s*-\s+type\s*:\s*(?<value>.+?)\s*(?:#.*)?$'
    $resourcesAtInner  = '^\s{' + $innerListIndent  + '}resources\s*:\s*(?:#.*)?$'
    $innerTypeAtKey    = '^\s{' + $innerKeyIndent   + '}type\s*:\s*(?<value>.+?)\s*(?:#.*)?$'
    $innerTypeOnDash   = '^\s{' + $innerDashIndent  + '}-\s+type\s*:\s*(?<value>.+?)\s*(?:#.*)?$'

    for ($n = 0; $n -lt $rootItems.Count; $n++) {
        $itemStart = $rootItems[$n]
        $itemEnd = if ($n -lt ($rootItems.Count - 1)) { $rootItems[$n + 1] - 1 } else { $lines.Count - 1 }

        $wrapperType = $null; $wrapperName = $null
        for ($k = $itemStart; $k -le $itemEnd; $k++) {
            $line = $lines[$k]
            if ($null -eq $wrapperType -and $line -match $typeAtChild) {
                $wrapperType = ([string]$Matches.value).Trim().Trim("'`"")
            }
            if ($null -eq $wrapperType -and $k -eq $itemStart -and $line -match $typeOnDash) {
                $wrapperType = ([string]$Matches.value).Trim().Trim("'`"")
            }
            if ($null -eq $wrapperName -and $line -match $nameAtChild) {
                $wrapperName = ([string]$Matches.value).Trim().Trim("'`"")
            }
            if ($null -eq $wrapperName -and $k -eq $itemStart -and $line -match $nameOnDash) {
                $wrapperName = ([string]$Matches.value).Trim().Trim("'`"")
            }
        }

        if ([string]::IsNullOrWhiteSpace($wrapperName)) { continue }

        $innerListLine = -1
        for ($k = $itemStart; $k -le $itemEnd; $k++) {
            if ($lines[$k] -match $resourcesAtInner) { $innerListLine = $k; break }
        }
        if ($innerListLine -lt 0) { continue }

        $innerType = $null
        for ($k = $innerListLine + 1; $k -le $itemEnd; $k++) {
            $line = $lines[$k]
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ($line -match '^(\s*)\S' -and ([string]$Matches[1]).Length -lt $innerListIndent) { break }
            if ($line -match $innerTypeOnDash) {
                $innerType = ([string]$Matches.value).Trim().Trim("'`""); break
            }
            if ($line -match $innerTypeAtKey) {
                $innerType = ([string]$Matches.value).Trim().Trim("'`""); break
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($innerType)) {
            $result[$wrapperName] = @{ AdapterType = $wrapperType; InnerType = $innerType }
        }
    }

    return $result
}

Export-ModuleMember -Function Get-DriftedTopLevelResourceNames, Get-WrapperDependsOnNames, New-FilteredConfigForResources, New-StrippedConfigExcludingResources, Get-WrapperInnerTypeMap
