# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Dsc.JsonSchema.psm1') -Force

function Read-DscOrchestratorConfig {
    <#
    .SYNOPSIS
        Reads and validates an Orchestrator package configuration.
    .DESCRIPTION
        Resolves fragment paths relative to the configuration file and validates
        its package identity, scalar parameters, and exact resource-module versions.
    .PARAMETER Path
        Path to dsc-orchestrator.config.json.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
        [string]$Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    try {
        $rawConfig = Get-Content -LiteralPath $fullPath -Raw -ErrorAction Stop
        $config = $rawConfig | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Failed to parse Orchestrator config '$fullPath': $($_.Exception.Message)"
    }

    if ($config -isnot [pscustomobject]) {
        throw "Orchestrator config '$fullPath' must contain a JSON object."
    }

    $configSchemaPath = Join-Path $PSScriptRoot '..\contracts\dsc-orchestrator-config.schema.json'
    Assert-OrchestratorJsonSchema `
        -Value $config `
        -SchemaPath $configSchemaPath `
        -Subject "Orchestrator config '$fullPath'"

    foreach ($requiredProperty in 'schemaVersion', 'name', 'version', 'fragments') {
        if ($config.PSObject.Properties.Name -notcontains $requiredProperty) {
            throw "Orchestrator config '$fullPath' is missing required property '$requiredProperty'."
        }
    }

    if ([string]$config.schemaVersion -ne '1.0') {
        throw "Orchestrator config '$fullPath' uses unsupported schemaVersion '$($config.schemaVersion)'; expected '1.0'."
    }

    $name = [string]$config.name
    if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
        throw "Orchestrator config '$fullPath' has invalid name '$name'. Use 1-64 letters, digits, dots, underscores, or hyphens, beginning with a letter or digit."
    }

    $version = [string]$config.version
    if ($version -notmatch '^\d+\.\d+\.\d+$') {
        throw "Orchestrator config '$fullPath' has invalid version '$version'. Use a semantic version in major.minor.patch form."
    }

    $group = $null
    if ($config.PSObject.Properties.Name -contains 'group') {
        $group = [string]$config.group
        if ([string]::IsNullOrWhiteSpace($group)) {
            throw "Orchestrator config '$fullPath' property 'group' must not be empty or whitespace."
        }
    }

    $role = $null
    if ($config.PSObject.Properties.Name -contains 'role') {
        $role = [string]$config.role
        if ([string]::IsNullOrWhiteSpace($role)) {
            throw "Orchestrator config '$fullPath' property 'role' must not be empty or whitespace."
        }
    }

    $parameters = @{}
    if ($config.PSObject.Properties.Name -contains 'parameters') {
        $parameters = $config.parameters
        if ($null -eq $parameters) {
            $parameters = @{}
        }
        elseif ($parameters -isnot [pscustomobject] -and $parameters -isnot [System.Collections.IDictionary]) {
            throw "Orchestrator config '$fullPath' property 'parameters' must be a JSON object."
        }
    }

    $configRoot = Split-Path -Parent $fullPath
    $configRootPrefix = $configRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) +
        [System.IO.Path]::DirectorySeparatorChar
    $fragmentNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $fragments = [System.Collections.Generic.List[object]]::new()
    $fragmentEntries = @($config.fragments)
    if ($fragmentEntries.Count -eq 0) {
        throw "Orchestrator config '$fullPath' must contain at least one fragment."
    }

    foreach ($fragment in $fragmentEntries) {
        if ($null -eq $fragment -or
            $fragment -isnot [pscustomobject] -or
            $fragment.PSObject.Properties.Name -notcontains 'name' -or
            $fragment.PSObject.Properties.Name -notcontains 'path') {
            throw "Every fragment in Orchestrator config '$fullPath' must be an object with 'name' and 'path' properties."
        }

        $fragmentName = [string]$fragment.name
        if ($fragmentName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
            throw "Orchestrator config '$fullPath' has invalid fragment name '$fragmentName'."
        }
        if (-not $fragmentNames.Add($fragmentName)) {
            throw "Orchestrator config '$fullPath' declares fragment '$fragmentName' more than once."
        }

        $relativePath = [string]$fragment.path
        if ([string]::IsNullOrWhiteSpace($relativePath) -or
            [System.IO.Path]::IsPathRooted($relativePath) -or
            ($relativePath -split '[\\/]' | Where-Object { $_ -eq '..' })) {
            throw "Fragment '$fragmentName' in Orchestrator config '$fullPath' must use a relative path without '..' segments."
        }
        if ($relativePath -notmatch '(?i)\.dsc\.yaml$') {
            throw "Fragment '$fragmentName' in Orchestrator config '$fullPath' must reference a .dsc.yaml file."
        }

        $fragmentPath = [System.IO.Path]::GetFullPath((Join-Path $configRoot $relativePath))
        if (-not $fragmentPath.StartsWith($configRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Fragment '$fragmentName' in Orchestrator config '$fullPath' resolves outside the config directory."
        }
        if (-not (Test-Path -LiteralPath $fragmentPath -PathType Leaf)) {
            throw "Fragment '$fragmentName' in Orchestrator config '$fullPath' was not found: $fragmentPath"
        }

        $fragments.Add([pscustomobject]@{
            Name         = $fragmentName
            RelativePath = $relativePath.Replace('\', '/')
            FullPath     = $fragmentPath
        })
    }

    $modules = [System.Collections.Generic.List[object]]::new()
    $moduleNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($config.PSObject.Properties.Name -contains 'modules' -and $null -ne $config.modules) {
        foreach ($module in @($config.modules)) {
            if ($null -eq $module -or
                $module -isnot [pscustomobject] -or
                $module.PSObject.Properties.Name -notcontains 'name' -or
                $module.PSObject.Properties.Name -notcontains 'version') {
                throw "Every module in Orchestrator config '$fullPath' must be an object with 'name' and 'version' properties."
            }

            $moduleName = [string]$module.name
            if ($moduleName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') {
                throw "Orchestrator config '$fullPath' has invalid module name '$moduleName'."
            }
            if ([string]::Equals($moduleName, 'DscOrchestrator.Reboot', [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Module name '$moduleName' is reserved for the Orchestrator reboot helper."
            }
            if (-not $moduleNames.Add($moduleName)) {
                throw "Orchestrator config '$fullPath' declares module '$moduleName' more than once."
            }

            $moduleVersion = [string]$module.version
            if ($moduleVersion -notmatch '^\d+\.\d+\.\d+(?:\.\d+)?$') {
                throw "Orchestrator config '$fullPath' has invalid version '$moduleVersion' for module '$moduleName'. Use major.minor.patch or major.minor.patch.revision form."
            }
            $modules.Add([pscustomobject]@{
                Name    = $moduleName
                Version = $moduleVersion
            })
        }
    }

    [pscustomobject]@{
        Path          = $fullPath
        Root          = $configRoot
        SchemaVersion = '1.0'
        Name          = $name
        Version       = $version
        Group         = $group
        Role          = $role
        Parameters    = $parameters
        Fragments     = $fragments.ToArray()
        Modules       = $modules.ToArray()
    }
}

Export-ModuleMember -Function Read-DscOrchestratorConfig
