# Dsc.Runtime.Dependencies — per-fragment status tracking and dependency gate logic.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-FragmentStatusTracker {
    <#
    .SYNOPSIS
        Creates a new fragment status tracker.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates only an in-memory tracker object for the current enforcement run.')]
    param()

    $tracker = @{}
    return ,[pscustomobject]@{
        States = $tracker
        PSTypeName = 'FragmentStatusTracker'
    }
}

function Initialize-FragmentStatus {
    <#
    .SYNOPSIS
        Initializes status for a single fragment.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Tracker,
        [Parameter(Mandatory = $true)][string]$FragmentName
    )

    $Tracker.States[$FragmentName] = [pscustomobject]@{
        Evaluated                = $false
        HadErrors                = $false
        HadQuarantine            = $false
        HadDriftBeforeSet        = $false
        SetAttempted             = $false
        VerifySucceeded          = $false
        FinalNonCompliantCount   = 0
        ModeBlockedRemediation   = $false
        TerminalStatus           = $null
    }
}

$script:FragmentTerminalStates = @('compliant', 'failed', 'non_compliant', 'unevaluated', 'skipped')

function Set-FragmentTerminalStatus {
    <#
    .SYNOPSIS
        Records a fragment's terminal status for dependency-block telemetry.
    .DESCRIPTION
        Telemetry only — the gate decision stays with Test-FragmentSucceeded. Value must be one of
        compliant, failed, non_compliant, unevaluated, skipped.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Updates only the in-memory per-run fragment tracker.')]
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Status,
        [Parameter(Mandatory = $true)][string]$Value
    )

    if ($script:FragmentTerminalStates -notcontains $Value) {
        throw "Invalid fragment terminal status '$Value'. Expected one of: $($script:FragmentTerminalStates -join ', ')."
    }
    $Status.TerminalStatus = $Value
}

function Resolve-FragmentTerminalStatus {
    <#
    .SYNOPSIS
        Returns a fragment's terminal status: the explicit value if set, otherwise derived from flags.
    .DESCRIPTION
        The flag-derived fallback mirrors Test-FragmentSucceeded's disqualifiers so a non-succeeded
        dependency always resolves to a failing status (failed/non_compliant/unevaluated).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Status
    )

    if (-not [string]::IsNullOrEmpty([string]$Status.TerminalStatus)) {
        return [string]$Status.TerminalStatus
    }
    if (Test-FragmentSucceeded -Status $Status) { return 'compliant' }
    if ($Status.HadErrors -or $Status.HadQuarantine) { return 'failed' }
    if ($Status.FinalNonCompliantCount -gt 0 -or $Status.HadDriftBeforeSet -or $Status.ModeBlockedRemediation) { return 'non_compliant' }
    if (-not $Status.Evaluated) { return 'unevaluated' }
    return 'failed'
}

function Get-BlockedByDetail {
    <#
    .SYNOPSIS
        Returns the non-succeeded dependencies with each one's terminal status.
    .DESCRIPTION
        Enriches Get-BlockedByList for block telemetry: each entry is { name; status } so a skip row
        identifies both the blocking dependency and the terminal status that caused the block.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Tracker,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$DependsOn
    )

    $blocked = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($dep in $DependsOn) {
        $depStatus = Get-FragmentStatus -Tracker $Tracker -FragmentName $dep
        if (-not (Test-FragmentSucceeded -Status $depStatus)) {
            $blocked.Add([pscustomobject]@{
                name   = $dep
                status = Resolve-FragmentTerminalStatus -Status $depStatus
            })
        }
    }
    return ,$blocked.ToArray()
}

function Get-FragmentStatus {
    <#
    .SYNOPSIS
        Retrieves status for a fragment.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Tracker,
        [Parameter(Mandatory = $true)][string]$FragmentName
    )

    if (-not $Tracker.States.ContainsKey($FragmentName)) {
        throw "Fragment '$FragmentName' has no status (logic error)."
    }
    return $Tracker.States[$FragmentName]
}

function Test-FragmentSucceeded {
    <#
    .SYNOPSIS
        Returns $true if the fragment met all strict success criteria.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Status
    )

    return ($Status.Evaluated -and
            -not $Status.HadErrors -and
            -not $Status.HadQuarantine -and
            -not $Status.HadDriftBeforeSet -and
            $Status.FinalNonCompliantCount -eq 0 -and
            -not $Status.ModeBlockedRemediation)
}

function Get-BlockedByList {
    <#
    .SYNOPSIS
        Returns the list of dependencies that did not succeed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Tracker,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$DependsOn
    )

    $blocked = [System.Collections.Generic.List[string]]::new()
    foreach ($dep in $DependsOn) {
        $depStatus = Get-FragmentStatus -Tracker $Tracker -FragmentName $dep
        if (-not (Test-FragmentSucceeded -Status $depStatus)) {
            $blocked.Add($dep)
        }
    }
    return ,$blocked.ToArray()
}

function Test-ShouldSkipDueToDependency {
    <#
    .SYNOPSIS
        Returns $true if the fragment should be skipped (enforce mode only).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Tracker,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$DependsOn,
        [Parameter(Mandatory = $true)][bool]$AuditOnly
    )

    if ($AuditOnly) { return $false }
    if ($null -eq $DependsOn -or $DependsOn.Count -eq 0) { return $false }

    foreach ($dep in $DependsOn) {
        $depStatus = Get-FragmentStatus -Tracker $Tracker -FragmentName $dep
        if (-not (Test-FragmentSucceeded -Status $depStatus)) {
            return $true
        }
    }
    return $false
}

Export-ModuleMember -Function New-FragmentStatusTracker, Initialize-FragmentStatus, Get-FragmentStatus, Test-FragmentSucceeded, Get-BlockedByList, Get-BlockedByDetail, Set-FragmentTerminalStatus, Resolve-FragmentTerminalStatus, Test-ShouldSkipDueToDependency
