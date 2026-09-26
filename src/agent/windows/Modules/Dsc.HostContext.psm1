<#
.SYNOPSIS
    Process-context primitives for DSCv3 enforcement: identity, config version,
    stderr write.
.DESCRIPTION
    Leaf module — no other Dsc.* module imports. Functions here are touched by
    almost every other module so any new dependency would create a cycle. Keep
    this module cycle-free at all costs.
.NOTES
    Behavior preserved byte-equivalent from Invoke-Enforcement.ps1 Phase A
    (function bodies relocated only; no logic change).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ConfigVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path) {
        return (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop).Trim()
    }
    return 'unknown'
}

function Get-ConfigMetadata {
    <#
    .SYNOPSIS
    Reads portable metadata and the package configuration hash from metadata.json.
    .DESCRIPTION
    The package builder populates group and role when configured and includes the package
    configuration hash. Missing or invalid optional metadata remains JSON null.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Metadata is an uncountable schema term; this name is part of the module contract.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '', Justification='Malformed optional metadata must not fail enforcement; absent context is emitted as JSON null.')]
    param([Parameter(Mandatory)][string]$Path)

    $group = $null
    $role = $null
    $configurationHash = $null
    if (Test-Path -LiteralPath $Path) {
        try {
            $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
            $obj = $raw | ConvertFrom-Json -ErrorAction Stop
            foreach ($p in $obj.PSObject.Properties) {
                switch ($p.Name) {
                    'group' { $group = [string]$p.Value }
                    'role'  { $role  = [string]$p.Value }
                    'configuration_hash' {
                        $candidateHash = [string]$p.Value
                        if ($candidateHash -match '^[0-9a-fA-F]{64}$') {
                            $configurationHash = $candidateHash.ToLowerInvariant()
                        }
                    }
                }
            }
        }
        catch {
            # Intentional empty catch: malformed metadata.json must not fail a run. Fall through with nulls.
        }
    }
    return [pscustomobject]@{
        Group = if ([string]::IsNullOrWhiteSpace($group)) { $null } else { $group }
        Role  = if ([string]::IsNullOrWhiteSpace($role))  { $null } else { $role }
        ConfigurationHash = $configurationHash
    }
}

function Get-DscExeVersion {
    <#
    .SYNOPSIS
    Captures the dsc.exe binary version string for runs.jsonl context.
    .DESCRIPTION
    Schema 2.0 adds `dsc_exe_version` to every runs.jsonl row so downstream queries can
    isolate "this 3.2.x bug" / "this 3.3.x regression" classes of issues across the fleet
    without joining external mapping tables. Best-effort: a parse failure returns 'unknown'
    so the run still proceeds with a well-formed log row.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$DscExePath)

    if (-not (Test-Path -LiteralPath $DscExePath)) { return 'unknown' }
    try {
        $output = & $DscExePath --version 2>$null | Select-Object -First 1
        if ([string]::IsNullOrWhiteSpace($output)) { return 'unknown' }
        return [string]$output.Trim()
    }
    catch {
        return 'unknown'
    }
}

function Get-HostIdentity {
    <#
    .SYNOPSIS
    Returns host identity fields (HostName, FQDN, Domain) for state/log records.
    .DESCRIPTION
    Seam (p3): single chokepoint for test mocks. HostName from $env:COMPUTERNAME; FQDN/Domain
    from IPGlobalProperties. Fallback to NetBIOS+'' if resolution fails. Never throws (metadata only).
    #>
    [CmdletBinding()]
    param()

    $hostName = [string]$env:COMPUTERNAME
    $fqdn     = $hostName
    $domain   = ''
    try {
        $ipProps = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
        if ($null -ne $ipProps) {
            if (-not [string]::IsNullOrWhiteSpace($ipProps.HostName)) {
                $fqdn = $ipProps.HostName
                if (-not [string]::IsNullOrWhiteSpace($ipProps.DomainName)) {
                    $fqdn   = "$($ipProps.HostName).$($ipProps.DomainName)"
                    $domain = $ipProps.DomainName
                }
            }
        }
    }
    catch {
        # Identity resolution must not fail a run - swallow and return defaults.
        $fqdn   = $hostName
        $domain = ''
    }
    return [pscustomobject]@{
        HostName = $hostName
        FQDN     = $fqdn
        Domain   = $domain
    }
}

function Write-NativeStderr {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return }
    [Console]::Error.Write($Text)
}

Export-ModuleMember -Function Get-ConfigVersion, Get-ConfigMetadata, Get-DscExeVersion, Get-HostIdentity, Write-NativeStderr
