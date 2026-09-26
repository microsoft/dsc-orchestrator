Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-DscPackageMetadata {
    <#
    .SYNOPSIS
        Creates metadata.json content for the built package.
    .DESCRIPTION
        Carries the package identity and configuration hash, plus optional group and role metadata.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Metadata is an uncountable schema term.') ]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$PackageManifest,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$PreparedManifest
    )

    $metadata = [ordered]@{
        configuration_name    = [string]$PackageManifest['name']
        configuration_version = [string]$PackageManifest['version']
        configuration_hash    = [string]$PackageManifest['configurationHash']
    }

    foreach ($propertyName in 'group', 'role') {
        $property = $PreparedManifest.PSObject.Properties[$propertyName]
        if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            $metadata[$propertyName] = [string]$property.Value
        }
    }

    $metadata['package_built_at'] = (Get-Date).ToUniversalTime().ToString('o')
    return $metadata
}

Export-ModuleMember -Function ConvertTo-DscPackageMetadata
