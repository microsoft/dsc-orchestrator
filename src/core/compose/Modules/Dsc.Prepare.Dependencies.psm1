# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

# Dsc.Prepare.Dependencies — cross-fragment dependency extraction, validation, and ordering.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FragmentDependencies {
    <#
    .SYNOPSIS
        Extracts metadata.platform.dependsOn from a rendered fragment.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Returns the declared dependency collection for one fragment.')]
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if ($Content -notmatch '(?m)^(?:metadata|["'']metadata["''])\s*:') {
        return $null
    }

    try {
        $obj = $Content | powershell-yaml\ConvertFrom-Yaml -ErrorAction Stop
    } catch {
        throw "Fragment '$Path' could not be parsed as YAML (post-render): $($_.Exception.Message)"
    }

    if ($obj -isnot [System.Collections.IDictionary] -or -not $obj.Contains('metadata')) { return $null }
    $metadata = $obj['metadata']
    if ($metadata -isnot [System.Collections.IDictionary] -or -not $metadata.Contains('platform')) { return $null }
    $platform = $metadata['platform']
    if ($platform -isnot [System.Collections.IDictionary] -or -not $platform.Contains('dependsOn')) { return $null }
    return ,$platform['dependsOn']
}

function Assert-DependsOnShape {
    <#
    .SYNOPSIS
        Validates metadata.platform.dependsOn array structure and entries.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$FragmentName,
        [Parameter(Mandatory = $true)][string[]]$AllSelectedNames
    )

    if ($null -eq $Value) { return ,@() }

    if ($Value -isnot [System.Collections.IEnumerable] -or $Value -is [string]) {
        throw "Fragment '$Path' has metadata.platform.dependsOn that is not an array. Use an array of fragment names, e.g. ['Fragment1','Fragment2'], or ['*']."
    }

    $deps = @($Value)
    if ($deps.Count -eq 0) {
        throw "Fragment '$Path' has metadata.platform.dependsOn as an empty array. Either declare dependencies or omit the key."
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $canonical = [System.Collections.Generic.List[string]]::new()

    foreach ($d in $deps) {
        if ($null -eq $d -or [string]::IsNullOrWhiteSpace([string]$d)) {
            throw "Fragment '$Path' has metadata.platform.dependsOn with an empty or null entry. Every entry must be a non-empty string."
        }
        $depName = ([string]$d).Trim()
        if ([string]::IsNullOrWhiteSpace($depName)) {
            throw "Fragment '$Path' has metadata.platform.dependsOn with a whitespace-only entry."
        }

        if ($depName -eq '*') {
            if ($deps.Count -ne 1) {
                throw "Fragment '$Path' has metadata.platform.dependsOn=['*'] with additional entries. '*' must be the sole entry."
            }
            foreach ($other in $AllSelectedNames) {
                if ([string]::Compare($other, $FragmentName, $true) -ne 0) {
                    $canonical.Add($other)
                }
            }
            return ,$canonical.ToArray()
        }

        $matched = $null
        foreach ($sel in $AllSelectedNames) {
            if ([string]::Compare($sel, $depName, $true) -eq 0) {
                $matched = $sel
                break
            }
        }
        if ($null -eq $matched) {
            throw "Fragment '$Path' dependsOn '$depName' which is not selected in dsc-orchestrator.config.json."
        }
        if ([string]::Compare($matched, $FragmentName, $true) -eq 0) {
            throw "Fragment '$Path' dependsOn itself ('$matched'). Self-dependency is not allowed."
        }
        if ($seen.Add($matched)) {
            $canonical.Add($matched)
        }
    }

    return ,$canonical.ToArray()
}

function Test-DependencyCycle {
    <#
    .SYNOPSIS
        Detects cycles in a dependency graph. Returns $null if acyclic, or a cycle path string if found.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Graph
    )

    $visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $recStack = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $path = [System.Collections.Generic.List[string]]::new()

    function Find-Cycle {
        param([string]$node)
        if ($recStack.Contains($node)) {
            $cycleStart = $path.IndexOf($node)
            $cyclePath = @($path[$cycleStart..($path.Count-1)])
            $cyclePath += $node
            return ($cyclePath -join ' → ')
        }
        if ($visited.Contains($node)) { return $null }

        [void]$visited.Add($node)
        [void]$recStack.Add($node)
        [void]$path.Add($node)

        $deps = $Graph[$node]
        if ($null -ne $deps) {
            foreach ($dep in $deps) {
                $cycle = Find-Cycle -node $dep
                if ($null -ne $cycle) { return $cycle }
            }
        }

        [void]$recStack.Remove($node)
        [void]$path.RemoveAt($path.Count - 1)
        return $null
    }

    foreach ($node in $Graph.Keys) {
        $cycle = Find-Cycle -node $node
        if ($null -ne $cycle) { return $cycle }
    }
    return $null
}

Export-ModuleMember -Function Get-FragmentDependencies, Assert-DependsOnShape, Test-DependencyCycle
