# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

<#
.SYNOPSIS
    Shared fixtures for the Dsc.ConfigFilter Pester suite.
.DESCRIPTION
    Builds small DSCv3 configs that mirror the real composed-fragment shape
    (top-level Microsoft.DSC/PowerShell wrappers, each nesting a single inner
    resource, with optional wrapper-level dependsOn). Also provides an
    independent re-parser used to assert the strip soundness invariant
    (no surviving wrapper dependsOn a removed wrapper).

    Dot-sourced from Dsc.ConfigFilter.Tests.ps1.
#>

Set-StrictMode -Version Latest

function New-DscConfigText {
    <#
    .SYNOPSIS
        Renders a DSCv3 config string from an ordered list of wrapper specs.
    .PARAMETER Wrappers
        Ordered array of hashtables: @{ Name = '<wrapper>'; DependsOn = @('<dep>', ...) }.
        DependsOn is optional. Dependencies are emitted as a block-list of the
        real resourceId() form the composer uses, e.g.
        "[resourceId('Microsoft.DSC/PowerShell', 'WrapperA')]".
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][object[]]$Wrappers)

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('$schema: https://aka.ms/dsc/schemas/v3/bundled/config/document.json')
    [void]$sb.AppendLine('resources:')
    foreach ($w in $Wrappers) {
        [void]$sb.AppendLine(('  - name: {0}' -f $w.Name))
        [void]$sb.AppendLine('    type: Microsoft.DSC/PowerShell')
        $deps = @()
        if ($w.ContainsKey('DependsOn') -and $null -ne $w.DependsOn) { $deps = @($w.DependsOn) }
        if ($deps.Count -gt 0) {
            [void]$sb.AppendLine('    dependsOn:')
            foreach ($d in $deps) {
                [void]$sb.AppendLine(("      - `"[resourceId('Microsoft.DSC/PowerShell', '{0}')]`"" -f $d))
            }
        }
        [void]$sb.AppendLine('    properties:')
        [void]$sb.AppendLine('      resources:')
        [void]$sb.AppendLine(('        - name: {0}-inner' -f $w.Name))
        [void]$sb.AppendLine('          type: PSDscResources/Script')
        [void]$sb.AppendLine('          properties:')
        [void]$sb.AppendLine('            Ensure: Present')
    }
    return $sb.ToString()
}

function New-DscConfigFile {
    <#
    .SYNOPSIS
        Writes a rendered config (see New-DscConfigText) to disk, UTF-8 no BOM.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object[]]$Wrappers
    )
    $text = New-DscConfigText -Wrappers $Wrappers
    [System.IO.File]::WriteAllText($Path, $text, [System.Text.UTF8Encoding]::new($false))
    return $Path
}

function Get-EmittedWrapperGraph {
    <#
    .SYNOPSIS
        Independent oracle: re-parses an emitted config into Name -> dependsOn[].
    .DESCRIPTION
        Re-slices the config with the same root-indent logic the module uses and
        leans on the (exported) Get-WrapperDependsOnNames to read each wrapper's
        dependsOn references. Used by the strip soundness assertion: every dep of
        a surviving wrapper must itself be a surviving wrapper (no dangling
        dependsOn into a removed wrapper).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][string]$Path)

    $lines = [System.IO.File]::ReadAllLines($Path)
    $resIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^resources:\s*(?:#.*)?$') { $resIdx = $i; break }
    }
    if ($resIdx -lt 0) { throw "Get-EmittedWrapperGraph: no 'resources:' line in $Path." }

    $dash = New-Object System.Collections.Generic.List[object]
    for ($i = $resIdx + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^(?<ind>\s*)-\s+') {
            $dash.Add([pscustomobject]@{ Index = $i; Indent = ([string]$Matches.ind).Length })
        }
    }
    if ($dash.Count -eq 0) { throw "Get-EmittedWrapperGraph: no resource items in $Path." }

    $root = ($dash | Measure-Object -Property Indent -Minimum).Minimum
    $rootIdx = @($dash | Where-Object { $_.Indent -eq $root } | ForEach-Object { $_.Index })
    $nameOnDash = '^\s*-\s+name:\s*(?<v>.+?)\s*(?:#.*)?$'
    $nameOnNext = ('^\s{{{0}}}name:\s*(?<v>.+?)\s*(?:#.*)?$' -f ($root + 2))

    $graph = [ordered]@{}
    for ($n = 0; $n -lt $rootIdx.Count; $n++) {
        $start = $rootIdx[$n]
        $end = if ($n -lt ($rootIdx.Count - 1)) { $rootIdx[$n + 1] - 1 } else { $lines.Count - 1 }
        $wlines = @($lines[$start..$end])

        $name = $null
        foreach ($l in $wlines) {
            if ($l -match $nameOnDash -or $l -match $nameOnNext) {
                $name = ([string]$Matches.v).Trim().Trim("'`"")
                break
            }
        }
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        # Assign first, THEN wrap: a function returning ',$emptyArray' does not
        # unroll cleanly when wrapped inline with @(), leaving a nested empty array.
        $deps = Get-WrapperDependsOnNames -WrapperLines $wlines -WrapperRootIndent $root
        $graph[$name] = @($deps | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    }
    return $graph
}

function Assert-NoDanglingDependsOn {
    <#
    .SYNOPSIS
        Soundness check: every dependsOn in the emitted config points at a
        wrapper that is also present in the emitted config. Throws on violation.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $graph = Get-EmittedWrapperGraph -Path $Path
    $present = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($k in $graph.Keys) { [void]$present.Add([string]$k) }

    foreach ($k in $graph.Keys) {
        foreach ($dep in $graph[$k]) {
            if (-not $present.Contains([string]$dep)) {
                throw "Dangling dependsOn: surviving wrapper '$k' depends on removed wrapper '$dep' in $Path."
            }
        }
    }
}
