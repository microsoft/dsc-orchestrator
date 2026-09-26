<#
.SYNOPSIS
    Reason synthesis from `dsc config get` envelopes.
.DESCRIPTION
    Reasons synthesis:
    - Get-ReasonsFromProperties  : extracts Reasons[] from a properties bag.
    - Get-PowerShellAdapterInnerReasons : walks a get envelope, returns map
      keyed by '<adapter>|<adapterInstanceName>|<type>|<name>'.

    Failure persistence:
    - Write-LastFailures         : persists last 3 failures to last-failures.json.
.NOTES
    Behavior preserved byte-equivalent from Invoke-Enforcement.ps1 Phase A.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'


function Get-ReasonsFromProperties {
    <#
    .SYNOPSIS
    Extracts Reasons[] from resource properties (DSCv1/v3 class-based convention).
    .DESCRIPTION
    Looks for `Reasons` property with enumerable Code/Phrase objects. Tolerates missing
    fields (empty strings). Phrases truncated to 1024 chars. Property access case-insensitive,
    matches dsc.exe emission (`Reasons`, `Code`, `Phrase`). Returns empty array when absent/malformed.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Returns the set of reason records projected from resource properties.')]
    param([Parameter(Mandatory)][AllowNull()][object]$Properties)

    if ($null -eq $Properties) { return @() }
    $reasonsRaw = Get-NestedProperty -Source $Properties -Path 'Reasons'
    if ($null -eq $reasonsRaw) { return @() }

    $out = @()
    foreach ($r in @($reasonsRaw)) {
        if ($null -eq $r) { continue }
        $code   = [string](Get-NestedProperty -Source $r -Path 'Code')
        $phrase = [string](Get-NestedProperty -Source $r -Path 'Phrase')
        if ($phrase.Length -gt 1024) { $phrase = $phrase.Substring(0, 1024) }
        $out += [pscustomobject]@{ Code = $code; Phrase = $phrase }
    }
    return ,$out
}

function Get-PowerShellAdapterInnerReasons {
    <#
    .SYNOPSIS
    Extracts per-real-resource Reasons from dsc config get envelope.
    .DESCRIPTION
    Class-based PS DSC modules populate [SomeReason[]] in Get() with Code/Phrase pairs.
    dsc test drops this; separate get call harvests it (best-effort). Returns hashtable
    keyed by '<adapter>|<adapterInstanceName>|<type>|<name>'. Resources without Reasons
    absent from map (callers fall back to wrapper-drift synthesis). Empty hashtable when
    ParsedGet null (get failed, non-fatal). Phrases truncated to 1024 chars.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Projects the reason collection from inner adapter resources.')]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$ParsedGet
    )

    $map = @{}
    if ($null -eq $ParsedGet) { return $map }
    $resultsRaw = Get-NestedProperty -Source $ParsedGet -Path 'Results'
    if ($null -eq $resultsRaw) { return $map }

    foreach ($entry in @($resultsRaw)) {
        if ($null -eq $entry) { continue }

        $isAdapter = Test-IsDscAdapterWrapper -Entry $entry

        $innerArray = Get-NestedProperty -Source $entry -Path 'result.actualState.result'
        if ($isAdapter -and $null -ne $innerArray) {

            $adapterType = [string]$entry.type
            $adapterName = [string](Get-NestedProperty -Source $entry -Path 'name')

            foreach ($inner in @($innerArray)) {
                if ($null -eq $inner) { continue }
                $innerType  = [string](Get-NestedProperty -Source $inner -Path 'type')
                $innerName  = [string](Get-NestedProperty -Source $inner -Path 'name')
                $innerProps = Get-NestedProperty -Source $inner -Path 'properties'
                $reasons    = Get-ReasonsFromProperties -Properties $innerProps
                $key = "$adapterType|$adapterName|$innerType|$innerName"
                $map[$key] = $reasons
            }
            continue
        }

        # Non-adapter top-level: native v3 resources rarely follow Reasons convention,
        # but harvest in case future native resources do. Key mirrors non-adapter New-ResourceActionMap.
        $topType    = [string](Get-NestedProperty -Source $entry -Path 'type')
        $topName    = [string](Get-NestedProperty -Source $entry -Path 'name')
        $properties = Get-NestedProperty -Source $entry -Path 'result.actualState'
        $reasons    = Get-ReasonsFromProperties -Properties $properties
        $key = "||$topType|$topName"
        $map[$key] = $reasons
    }

    return $map
}

function Write-LastFailures {
    <#
    .SYNOPSIS
        Persists last 3 enforcement failures to last-failures.json for on-call review.
    .DESCRIPTION
        Atomic write via temp-file + Move-Item. ACL inherits from LogDir.
        Bounded rotation prevents unbounded growth. Empty FailingResources array allowed.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Writes the collection of failures recorded for the latest run.')]
    param(
        [Parameter(Mandatory)][string]$LogDir,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$Timestamp,
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$FailingResources,
        [Parameter(Mandatory)][AllowEmptyString()][string]$StderrTail
    )

    $path = Join-Path $LogDir 'last-failures.json'
    $existing = @()
    if (Test-Path -LiteralPath $path) {
        try {
            $raw = [IO.File]::ReadAllText($path)
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
                $existing = @($parsed)
            }
        } catch {
            # Corrupt/legacy file - start fresh rather than failing the enforcement
            # run on top of the underlying failure we're trying to log.
            $existing = @()
        }
    }

    # Cap stderrTail at 4KB so the file stays small even on chatty failures.
    if ($StderrTail.Length -gt 4096) {
        $StderrTail = $StderrTail.Substring($StderrTail.Length - 4096)
    }

    $newEntry = [ordered]@{
        runId            = $RunId
        timestamp        = $Timestamp
        exitCode         = $ExitCode
        failingResources = @($FailingResources)
        stderrTail       = $StderrTail
    }

    $rotated = @(@($newEntry) + $existing) | Select-Object -First 3
    $json = $rotated | ConvertTo-Json -Depth 6

    $tmp = "$path.tmp"
    [IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $path -Force
}
Export-ModuleMember -Function `
    Get-ReasonsFromProperties, `
    Get-PowerShellAdapterInnerReasons, `
    Write-LastFailures
