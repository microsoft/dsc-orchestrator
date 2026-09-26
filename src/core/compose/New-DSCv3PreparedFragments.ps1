<#
.SYNOPSIS
    Renders and validates the fragments listed in dsc-orchestrator.config.json.
.DESCRIPTION
    Reads an Orchestrator configuration, renders its scalar parameters into native
    DSCv3 YAML fragments, validates resources and dependencies, and writes a
    prepared configs/ tree plus an intermediate manifest.json.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$ConfigPath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)

Import-Module (Join-Path $PSScriptRoot '..\shared\Dsc.OrchestratorConfig.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Modules\Dsc.Prepare.psd1') -DisableNameChecking

$config = Read-DscOrchestratorConfig -Path $ConfigPath
$renderParameters = Get-RenderParameterMap `
    -Parameters $config.Parameters `
    -ConfigurationName $config.Name `
    -ConfigurationVersion $config.Version

Write-Verbose "Preparing configuration '$($config.Name)' version $($config.Version)"
Write-Verbose "Fragment count: $($config.Fragments.Count)"
Write-Verbose "Output path: $OutputPath"

$fragments = [System.Collections.Generic.List[object]]::new()
$resourceNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$configNames = @($config.Fragments | ForEach-Object { $_.Name })

foreach ($configFragment in $config.Fragments) {
    $fragmentPath = $configFragment.FullPath
    $configName = $configFragment.Name
    Write-Verbose "Reading fragment '$configName': $fragmentPath"

    $content = Get-Content -LiteralPath $fragmentPath -Raw -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($content)) {
        throw "Fragment '$fragmentPath' is empty."
    }
    if ($content -match "`t") {
        throw "Fragment '$fragmentPath' contains tab characters. YAML indentation must use spaces."
    }

    Assert-NoUnsupportedYamlFeature -Content $content -Path $fragmentPath
    Assert-NoUnresolvedToken -Content $content -Path $fragmentPath -AllowSupportedParameterTokens
    Assert-RenderTokensAreWholeScalars -Content $content -Path $fragmentPath
    $renderedContent = Invoke-DSCv3ParameterRendering `
        -Content $content `
        -Path $fragmentPath `
        -ParameterMap $renderParameters
    Assert-NoUnresolvedToken -Content $renderedContent -Path $fragmentPath

    $lines = @($renderedContent -split "`r?`n")
    $resourcesBlock = Get-TopLevelResourcesBlock -Path $fragmentPath -Lines $lines
    Assert-PerResourceWrapperStructure -Path $fragmentPath -ResourceBlock $resourcesBlock
    $identifiers = Get-ResourceIdentifier `
        -ConfigName $configName `
        -Path $fragmentPath `
        -ResourceBlock $resourcesBlock

    foreach ($identifier in $identifiers) {
        if (-not $resourceNames.Add($identifier.Name)) {
            throw "Duplicate DSCv3 resource name '$($identifier.Name)' found in '$fragmentPath'. Resource names must be unique across selected fragments."
        }
    }

    $rawDependencies = Get-FragmentDependencies -Content $renderedContent -Path $fragmentPath
    $resolvedDependencies = Assert-DependsOnShape `
        -Value $rawDependencies `
        -Path $fragmentPath `
        -FragmentName $configName `
        -AllSelectedNames $configNames

    $fragments.Add([pscustomobject]@{
        Name            = $configName
        RenderedContent = $renderedContent
        ResourceCount   = $identifiers.Count
        DependsOn       = $resolvedDependencies
        Resources       = @($identifiers | ForEach-Object { $_.Name })
    })
}

if ($fragments.Count -eq 0) {
    throw "Orchestrator config '$ConfigPath' did not select any fragments."
}

$dependencyGraph = @{}
$anyDependencies = $false
foreach ($fragment in $fragments) {
    $dependencies = @($fragment.DependsOn)
    $dependencyGraph[$fragment.Name] = $dependencies
    if ($dependencies.Count -gt 0) {
        $anyDependencies = $true
    }
}

if ($anyDependencies) {
    $cycle = Test-DependencyCycle -Graph $dependencyGraph
    if ($null -ne $cycle) {
        throw "Dependency cycle detected in the selected fragments: $cycle"
    }
}

if (-not (Test-Path -LiteralPath $OutputPath -PathType Container)) {
    New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop | Out-Null
}

$configsRoot = Join-Path $OutputPath 'configs'
$expectedFragmentPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($configFragment in $config.Fragments) {
    [void]$expectedFragmentPaths.Add("$($configFragment.Name)/$($configFragment.Name).dsc.yaml")
}
if (Test-Path -LiteralPath $configsRoot -PathType Container) {
    $existingFragmentFiles = @(
        Get-ChildItem -LiteralPath $configsRoot -Filter '*.dsc.yaml' -Recurse -File -ErrorAction Stop
    )
    foreach ($existingFragment in $existingFragmentFiles) {
        $relativeFragmentPath = $existingFragment.FullName.Substring($configsRoot.Length + 1).Replace('\', '/')
        if (-not $expectedFragmentPaths.Contains($relativeFragmentPath)) {
            throw "Prepared output '$configsRoot' contains stale fragment '$relativeFragmentPath'. Use a fresh OutputPath or remove only the generated configs directory."
        }
    }
}
else {
    New-Item -ItemType Directory -Path $configsRoot -Force -ErrorAction Stop | Out-Null
}

$manifestFragments = [System.Collections.Generic.List[object]]::new()
$fragmentHashInputs = [System.Collections.Generic.List[string]]::new()
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
foreach ($fragment in $fragments) {
    $fragmentDirectory = Join-Path $configsRoot $fragment.Name
    New-Item -ItemType Directory -Path $fragmentDirectory -Force -ErrorAction Stop | Out-Null

    $fragmentFile = Join-Path $fragmentDirectory "$($fragment.Name).dsc.yaml"
    [System.IO.File]::WriteAllText($fragmentFile, $fragment.RenderedContent, $utf8NoBom)
    $relativePath = "configs/$($fragment.Name)/$($fragment.Name).dsc.yaml"
    $fragmentHash = (Get-FileHash -LiteralPath $fragmentFile -Algorithm SHA256).Hash.ToLowerInvariant()
    $fragmentHashInputs.Add("$($fragment.Name):$fragmentHash")

    $entry = [ordered]@{
        name          = $fragment.Name
        path          = $relativePath
        resourceCount = $fragment.ResourceCount
        resources     = @($fragment.Resources)
    }
    if ($fragment.DependsOn.Count -gt 0) {
        $entry['dependsOn'] = @($fragment.DependsOn)
    }
    $manifestFragments.Add($entry)
}

$hashProvider = [System.Security.Cryptography.SHA256]::Create()
try {
    $hashInput = $utf8NoBom.GetBytes(($fragmentHashInputs -join "`n"))
    $configurationHash = [System.BitConverter]::ToString($hashProvider.ComputeHash($hashInput)).
        Replace('-', '').ToLowerInvariant()
}
finally {
    $hashProvider.Dispose()
}

$resourceModules = @(
    $config.Modules | ForEach-Object {
        [ordered]@{
            name    = $_.Name
            version = $_.Version
        }
    }
)
$manifest = [ordered]@{
    schemaVersion      = '1.0'
    name               = $config.Name
    version            = $config.Version
    configurationHash  = $configurationHash
    resourceModules    = $resourceModules
    fragments          = $manifestFragments
}
if ($null -ne $config.Group) {
    $manifest['group'] = $config.Group
}
if ($null -ne $config.Role) {
    $manifest['role'] = $config.Role
}
if ($anyDependencies) {
    $manifest['requiresRuntimeCapabilities'] = @('fragmentDependencyGate')
}

$manifestPath = Join-Path $OutputPath 'manifest.json'
$manifestJson = $manifest | ConvertTo-Json -Depth 8
[System.IO.File]::WriteAllText($manifestPath, $manifestJson, $utf8NoBom)

Write-Verbose "Prepared $($fragments.Count) fragment(s), $($resourceNames.Count) resource(s)."
Write-Verbose "Manifest: $manifestPath"

[pscustomobject]@{
    Name              = $config.Name
    Version           = $config.Version
    ConfigurationHash = $configurationHash
    OutputPath        = $OutputPath
    ManifestPath      = $manifestPath
    FragmentCount     = $fragments.Count
    ResourceCount     = $resourceNames.Count
}
