# Dsc.Prepare.Emit — line-based YAML scalar/line emit + render-token substitution.
#
# Composer is line-based on purpose: powershell-yaml / yq mis-parse unquoted
# whole-scalar `{{ ParameterName }}` tokens as flow mappings. Do not introduce
# a structured YAML serialiser (ConvertTo-Yaml / token-based render) here —
# the line-based contract is load-bearing.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-YamlScalar {
    <#
    .SYNOPSIS
        Renders a scalar parameter value as a line-safe YAML scalar (quoted when needed).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $false)][AllowNull()][object]$Value)

    if ($null -eq $Value) { return 'null' }
    if ($Value -is [System.Management.Automation.PSCustomObject] -or
        $Value -is [System.Collections.IDictionary] -or
        ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string])) {
        throw "DSCv3 parameter rendering supports scalar values only. Complex values must be expressed as strings or split into scalar parameters."
    }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [byte] -or $Value -is [System.Int16]) {
        return $Value.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [decimal] -or $Value -is [double] -or $Value -is [float]) {
        return $Value.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    }

    $str = [string]$Value
    if ($str -match "(`r|`n)") {
        throw "DSCv3 parameter rendering supports single-line scalar values only."
    }
    if ($str -eq 'True')  { return 'true' }
    if ($str -eq 'False') { return 'false' }
    if ($str -match '^\d+$') { return $str }

    $needsQuoting = $false
    if ($str -eq '')                                { $needsQuoting = $true }
    if ($str -match '[:{}\[\],&*?|>!%@`#''"]')      { $needsQuoting = $true }
    if ($str -match '^\s|\s$')                      { $needsQuoting = $true }
    if ($str -match '^(true|false|yes|no|null|~)$') { $needsQuoting = $true }

    if ($needsQuoting) {
        $escaped = $str -replace "'", "''"
        return "'$escaped'"
    }
    return $str
}

function Invoke-DSCv3ParameterRendering {
    <#
    .SYNOPSIS
        Substitutes `{{ ParameterName }}` tokens against the render parameter map.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSReviewUnusedParameter', '',
        Justification = '$ParameterMap is referenced from the regex MatchEvaluator script-block closure passed to Replace(); PSSA cannot follow closure-captured usage.'
    )]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][System.Collections.Generic.Dictionary[string, object]]$ParameterMap
    )

    $supportedTokenPattern = [regex]'\{\{\s*(?<name>[A-Za-z_][A-Za-z0-9_]*)\s*\}\}'
    try {
        return $supportedTokenPattern.Replace($Content, {
            param([System.Text.RegularExpressions.Match]$Match)

            $parameterName = $Match.Groups['name'].Value
            if (-not $ParameterMap.ContainsKey($parameterName)) {
                throw "Missing DSCv3 render parameter '$parameterName'. Add it to dsc-orchestrator.config.json parameters or use ConfigurationName/ConfigurationVersion."
            }

            return ConvertTo-YamlScalar $ParameterMap[$parameterName]
        })
    } catch {
        throw "Failed to render fragment '$Path': $($_.Exception.Message)"
    }
}

Export-ModuleMember -Function ConvertTo-YamlScalar, Invoke-DSCv3ParameterRendering
