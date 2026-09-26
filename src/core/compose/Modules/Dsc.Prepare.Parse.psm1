# Dsc.Prepare.Parse — merged-config JSON parsing into the render parameter map.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RenderParameterMap {
    <#
    .SYNOPSIS
        Returns a case-insensitive parameter map for an Orchestrator configuration.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Parameters,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$ConfigurationName,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$ConfigurationVersion
    )

    $parameterMap = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($null -ne $Parameters) {
        if ($Parameters -is [System.Collections.IDictionary]) {
            foreach ($key in $Parameters.Keys) {
                $parameterMap[[string]$key] = $Parameters[$key]
            }
        }
        elseif ($Parameters -is [pscustomobject]) {
            foreach ($property in $Parameters.PSObject.Properties) {
                $parameterMap[$property.Name] = $property.Value
            }
        }
        else {
            throw "Orchestrator config parameters must be a JSON object; found '$($Parameters.GetType().FullName)'."
        }
    }
    $parameterMap['ConfigurationName'] = $ConfigurationName
    $parameterMap['ConfigurationVersion'] = $ConfigurationVersion

    return ,$parameterMap
}

Export-ModuleMember -Function Get-RenderParameterMap
