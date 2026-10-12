# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$PreparedFragmentsPath,

    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$ModulesPath,

    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$DscExePath,

    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$PwshRuntimePath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory,

    [Parameter()]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$AgentPath = (Join-Path $PSScriptRoot '..\..\agent\windows'),

    [Parameter()]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$SharedModulesPath = (Join-Path $PSScriptRoot '..\shared'),

    [Parameter()]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$ToolsManifestPath = (Join-Path $PSScriptRoot 'tools-manifest.json'),

    [Parameter()]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$SignerAllowListPath = (Join-Path $PSScriptRoot 'tools-signer-allowlist.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\shared\Dsc.JsonSchema.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Modules\Dsc.PackageMetadata.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Modules\Dsc.PackageResourceModules.psm1') -Force

function Get-JsonFile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Failed to read JSON file '$Path': $($_.Exception.Message)"
    }
}

function Test-AllowedAuthenticodeSigner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$AllowListPath
    )

    $signature = Get-AuthenticodeSignature -FilePath $Path
    if ($signature.Status -ne 'Valid') {
        throw "Authenticode verification failed for '$Path'. Status=$($signature.Status); Message=$($signature.StatusMessage)"
    }
    if ($null -eq $signature.SignerCertificate) {
        throw "Authenticode verification failed for '$Path': signer certificate is missing."
    }

    $allowList = Get-JsonFile -Path $AllowListPath
    foreach ($allowed in @($allowList.allowedSigners)) {
        $subjectMatches = $signature.SignerCertificate.Subject -match $allowed.subjectRegex
        $issuerMatches = [string]::IsNullOrWhiteSpace($allowed.issuerRegex) -or
            ($signature.SignerCertificate.Issuer -match $allowed.issuerRegex)
        if ($subjectMatches -and $issuerMatches) {
            return
        }
    }

    throw "Authenticode signer '$($signature.SignerCertificate.Subject)' issued by '$($signature.SignerCertificate.Issuer)' is not in '$AllowListPath'."
}

function Initialize-PowerShellYaml {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ModulesPath)

    if (Get-Module -Name powershell-yaml) {
        return
    }
    if (Get-Module -Name powershell-yaml -ListAvailable | Select-Object -First 1) {
        Import-Module powershell-yaml -Force -ErrorAction Stop
        return
    }

    $candidate = Join-Path $ModulesPath 'powershell-yaml'
    if (Test-Path -LiteralPath $candidate -PathType Container) {
        $separator = [System.IO.Path]::PathSeparator
        if (($env:PSModulePath -split [regex]::Escape([string]$separator)) -notcontains $ModulesPath) {
            $env:PSModulePath = "$ModulesPath$separator$env:PSModulePath"
        }
        Import-Module powershell-yaml -Force -ErrorAction Stop
        return
    }

    throw "The powershell-yaml build dependency is missing. Install it from PSGallery or add it to '$ModulesPath'."
}

function Invoke-DSCv3ConfigSchemaValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DscExePath,
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$ModulesPath
    )

    Initialize-PowerShellYaml -ModulesPath $ModulesPath
    $schemaOutput = & $DscExePath schema --type configuration --output-format json 2>&1
    $schemaExitCode = $LASTEXITCODE
    if ($schemaExitCode -ne 0) {
        throw "dsc.exe schema --type configuration failed (exit $schemaExitCode): $($schemaOutput -join [Environment]::NewLine)"
    }
    $schemaText = $schemaOutput -join ''
    if ([string]::IsNullOrWhiteSpace($schemaText)) {
        throw 'dsc.exe schema --type configuration returned empty output.'
    }

    try {
        $configObject = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop |
            ConvertFrom-Yaml -ErrorAction Stop
    }
    catch {
        throw "Config '$ConfigPath' is not valid YAML: $($_.Exception.Message)"
    }

    $configJson = $configObject | ConvertTo-Json -Depth 100
    try {
        $null = Test-Json -Json $configJson -Schema $schemaText -ErrorAction Stop
    }
    catch {
        throw "DSC config '$ConfigPath' failed JSON Schema validation against the schema emitted by pinned dsc.exe ($DscExePath): $($_.Exception.Message)"
    }
}

$PreparedFragmentsPath = [System.IO.Path]::GetFullPath($PreparedFragmentsPath)
$ModulesPath = [System.IO.Path]::GetFullPath($ModulesPath)
$DscExePath = [System.IO.Path]::GetFullPath($DscExePath)
$PwshRuntimePath = [System.IO.Path]::GetFullPath($PwshRuntimePath)
$AgentPath = [System.IO.Path]::GetFullPath($AgentPath)
$SharedModulesPath = [System.IO.Path]::GetFullPath($SharedModulesPath)
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)

$manifestSourcePath = Join-Path $PreparedFragmentsPath 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestSourcePath -PathType Leaf)) {
    throw "Prepared fragments directory '$PreparedFragmentsPath' is missing manifest.json."
}
$preparedManifest = Get-JsonFile -Path $manifestSourcePath
foreach ($requiredProperty in 'schemaVersion', 'name', 'version', 'configurationHash', 'resourceModules', 'fragments') {
    if ($preparedManifest.PSObject.Properties.Name -notcontains $requiredProperty) {
        throw "Prepared manifest '$manifestSourcePath' is missing required property '$requiredProperty'."
    }
}
if ([string]$preparedManifest.schemaVersion -ne '1.0') {
    throw "Prepared manifest '$manifestSourcePath' uses unsupported schemaVersion '$($preparedManifest.schemaVersion)'."
}
if ([string]$preparedManifest.name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
    throw "Prepared manifest '$manifestSourcePath' contains an invalid package name."
}
if ([string]$preparedManifest.version -notmatch '^\d+\.\d+\.\d+$') {
    throw "Prepared manifest '$manifestSourcePath' contains an invalid package version."
}
if ([string]$preparedManifest.configurationHash -notmatch '^[0-9a-fA-F]{64}$') {
    throw "Prepared manifest '$manifestSourcePath' contains an invalid SHA-256 configurationHash."
}

$fragmentFiles = @(
    Get-ChildItem -LiteralPath $PreparedFragmentsPath -Filter '*.dsc.yaml' -Recurse -File -ErrorAction Stop
)
$manifestFragments = @($preparedManifest.fragments)
if ($fragmentFiles.Count -eq 0 -or $manifestFragments.Count -eq 0) {
    throw "Prepared fragments directory '$PreparedFragmentsPath' must contain at least one fragment and manifest entry."
}
$diskFragmentNames = @(
    $fragmentFiles | ForEach-Object { Split-Path -Leaf (Split-Path -Parent $_.FullName) }
)
$manifestFragmentNames = @($manifestFragments | ForEach-Object { [string]$_.name })
if ($diskFragmentNames.Count -ne $manifestFragmentNames.Count -or
    @($diskFragmentNames | Where-Object { $manifestFragmentNames -notcontains $_ }).Count -gt 0 -or
    @($manifestFragmentNames | Where-Object { $diskFragmentNames -notcontains $_ }).Count -gt 0) {
    throw "Prepared manifest '$manifestSourcePath' does not match the fragments on disk."
}

$configuredResourceModules = @($preparedManifest.resourceModules)
$resolvedResourceModules = @(
    Resolve-DSCv3ResourceModules `
        -ModulesPath $ModulesPath `
        -ResourceModules $configuredResourceModules
)
$declaredModuleNames = @($resolvedResourceModules | ForEach-Object { [string]$_.Name })

foreach ($fragment in $fragmentFiles) {
    Test-DSCv3ModuleAlignment -ConfigPath $fragment.FullName -ModuleNames $declaredModuleNames
}

$pwshExePath = Join-Path $PwshRuntimePath 'pwsh.exe'
if (-not (Test-Path -LiteralPath $pwshExePath -PathType Leaf)) {
    throw "PowerShell runtime directory '$PwshRuntimePath' does not contain pwsh.exe."
}
if ([System.IO.Path]::GetExtension($DscExePath) -ne '.exe') {
    throw "DscExePath must point to an .exe file: $DscExePath"
}

$toolsManifest = Get-JsonFile -Path $ToolsManifestPath
if ($null -eq $toolsManifest.tools.dsc -or $null -eq $toolsManifest.tools.pwsh) {
    throw "Tools manifest '$ToolsManifestPath' must define dsc and pwsh entries."
}
Test-AllowedAuthenticodeSigner -Path $DscExePath -AllowListPath $SignerAllowListPath
Test-AllowedAuthenticodeSigner -Path $pwshExePath -AllowListPath $SignerAllowListPath

foreach ($requiredScript in @(
        'bootstrap.ps1',
        'Install-VmApplicationPackage.ps1',
        'Invoke-Enforcement.ps1',
        'Run-Enforcement.ps1',
        'remove.ps1',
        'Resolve-PwshExe.ps1',
        'Write-BootstrapJsonLine.ps1'
    )) {
    $scriptPath = Join-Path $AgentPath $requiredScript
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw "Required agent entry point was not found: $scriptPath"
    }
}

$agentModulesPath = Join-Path $AgentPath 'Modules'
$requiredAgentModuleFiles = @('Dsc.RebootRequest.psm1', 'DscOrchestrator.Reboot.psd1')
foreach ($moduleFile in $requiredAgentModuleFiles) {
    $modulePath = Join-Path $agentModulesPath $moduleFile
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        throw "Required agent module file was not found: $modulePath"
    }
}
$sharedYamlModule = Join-Path $SharedModulesPath 'Dsc.YamlLines.psm1'
if (-not (Test-Path -LiteralPath $sharedYamlModule -PathType Leaf)) {
    throw "Shared YAML helper was not found: $sharedYamlModule"
}

$schemaFailures = [System.Collections.Generic.List[string]]::new()
foreach ($fragment in $fragmentFiles) {
    try {
        Invoke-DSCv3ConfigSchemaValidation `
            -DscExePath $DscExePath `
            -ConfigPath $fragment.FullName `
            -ModulesPath $ModulesPath
    }
    catch {
        $schemaFailures.Add("$($fragment.Name): $($_.Exception.Message)")
    }
}
if ($schemaFailures.Count -gt 0) {
    $messages = [System.Collections.Generic.List[string]]::new()
    if ($schemaFailures.Count -gt 0) {
        $messages.Add("DSCv3 schema validation failures ($($schemaFailures.Count)):")
        foreach ($failure in $schemaFailures) {
            $messages.Add("  - $failure")
        }
    }
    throw ($messages -join [Environment]::NewLine)
}

if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force -ErrorAction Stop | Out-Null
}
$stagingPath = Join-Path $OutputDirectory ('.dsc-orchestrator-staging-' + [guid]::NewGuid().ToString('N'))
$packageFileName = "dsc-orchestrator-$($preparedManifest.name)-$($preparedManifest.version).zip"
$packagePath = Join-Path $OutputDirectory $packageFileName
$temporaryPackagePath = Join-Path $OutputDirectory ('.' + $packageFileName + '.' + [guid]::NewGuid().ToString('N') + '.tmp.zip')
New-Item -ItemType Directory -Path $stagingPath -Force -ErrorAction Stop | Out-Null

try {
    $dscRuntimePath = Split-Path -Parent $DscExePath
    Copy-Item -Path (Join-Path $dscRuntimePath '*') -Destination $stagingPath -Recurse -Force -ErrorAction Stop
    Copy-Item -LiteralPath $DscExePath -Destination (Join-Path $stagingPath 'dsc.exe') -Force -ErrorAction Stop

    $pwshStagingPath = Join-Path $stagingPath 'pwsh'
    New-Item -ItemType Directory -Path $pwshStagingPath -Force -ErrorAction Stop | Out-Null
    Copy-Item -Path (Join-Path $PwshRuntimePath '*') -Destination $pwshStagingPath -Recurse -Force -ErrorAction Stop

    Copy-Item -LiteralPath (Join-Path $PreparedFragmentsPath 'configs') -Destination $stagingPath -Recurse -Force -ErrorAction Stop

    $modulesDestination = Join-Path $stagingPath 'modules'
    New-Item -ItemType Directory -Path $modulesDestination -Force -ErrorAction Stop | Out-Null
    $packageResourceModules = @(
        Copy-DSCv3ResourceModulesToPackage `
            -ResolvedModules $resolvedResourceModules `
            -DestinationPath $modulesDestination
    )

    $rebootSupportModulePath = Join-Path $modulesDestination 'DscOrchestrator.Reboot'
    New-Item -ItemType Directory -Path $rebootSupportModulePath -Force -ErrorAction Stop | Out-Null
    foreach ($moduleFile in $requiredAgentModuleFiles) {
        Copy-Item `
            -LiteralPath (Join-Path $agentModulesPath $moduleFile) `
            -Destination $rebootSupportModulePath `
            -Force `
            -ErrorAction Stop
    }

    foreach ($requiredScript in @(
            'bootstrap.ps1',
            'Install-VmApplicationPackage.ps1',
            'Invoke-Enforcement.ps1',
            'Run-Enforcement.ps1',
            'remove.ps1',
            'Resolve-PwshExe.ps1',
            'Write-BootstrapJsonLine.ps1'
        )) {
        Copy-Item `
            -LiteralPath (Join-Path $AgentPath $requiredScript) `
            -Destination $stagingPath `
            -Force `
            -ErrorAction Stop
    }

    $appModulesPath = Join-Path $stagingPath 'AppModules'
    New-Item -ItemType Directory -Path $appModulesPath -Force -ErrorAction Stop | Out-Null
    Copy-Item -Path (Join-Path $agentModulesPath '*') -Destination $appModulesPath -Recurse -Force -ErrorAction Stop
    $sharedAppModulesPath = Join-Path $appModulesPath 'Shared'
    New-Item -ItemType Directory -Path $sharedAppModulesPath -Force -ErrorAction Stop | Out-Null
    Copy-Item -LiteralPath $sharedYamlModule -Destination $sharedAppModulesPath -Force -ErrorAction Stop

    foreach ($moduleFile in Get-ChildItem -LiteralPath $appModulesPath -Filter '*.psm1' -Recurse -File -ErrorAction Stop) {
        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $moduleFile.FullName,
            [ref]$tokens,
            [ref]$parseErrors)
        if ($parseErrors) {
            throw "Agent module '$($moduleFile.Name)' has PowerShell parse errors: $($parseErrors[0].Message)"
        }
    }
    foreach ($moduleManifest in Get-ChildItem -LiteralPath $appModulesPath -Filter '*.psd1' -Recurse -File -ErrorAction Stop) {
        try {
            $null = Test-ModuleManifest -Path $moduleManifest.FullName -ErrorAction Stop
        }
        catch {
            throw "Agent module manifest '$($moduleManifest.Name)' failed Test-ModuleManifest: $($_.Exception.Message)"
        }
    }

    $configurationHash = [string]$preparedManifest.configurationHash
    $packageManifest = [ordered]@{
        schemaVersion     = '1.0'
        name              = [string]$preparedManifest.name
        version           = [string]$preparedManifest.version
        configurationHash = $configurationHash
        target            = [ordered]@{
            os           = 'windows'
            architecture = 'x64'
        }
        runtime           = [ordered]@{
            dscVersion       = [string]$toolsManifest.tools.dsc.version
            powerShellVersion = [string]$toolsManifest.tools.pwsh.version
        }
        resourceModules   = @($packageResourceModules)
        agentModules      = @(
            [ordered]@{
                name    = 'DscOrchestrator.Reboot'
                version = '1.0.0'
            }
        )
        fragments         = @($preparedManifest.fragments)
    }
    if ($preparedManifest.PSObject.Properties.Name -contains 'requiresRuntimeCapabilities') {
        $packageManifest['requiresRuntimeCapabilities'] = @($preparedManifest.requiresRuntimeCapabilities)
    }

    Assert-OrchestratorJsonSchema `
        -Value $packageManifest `
        -SchemaPath (Join-Path $PSScriptRoot '..\contracts\package-manifest.schema.json') `
        -Subject "Package manifest for '$($packageManifest.name)' version '$($packageManifest.version)'"

    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    $manifestJson = $packageManifest | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText((Join-Path $stagingPath 'manifest.json'), $manifestJson, $utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $stagingPath 'version.txt'), $packageManifest.version, $utf8NoBom)

    $metadata = ConvertTo-DscPackageMetadata -PackageManifest $packageManifest -PreparedManifest $preparedManifest
    [System.IO.File]::WriteAllText(
        (Join-Path $stagingPath 'metadata.json'),
        ($metadata | ConvertTo-Json -Depth 5),
        $utf8NoBom
    )

    $null = Compress-Archive -Path (Join-Path $stagingPath '*') -DestinationPath $temporaryPackagePath -Force
    Move-Item -LiteralPath $temporaryPackagePath -Destination $packagePath -Force -ErrorAction Stop
    $packageFile = Get-Item -LiteralPath $packagePath -ErrorAction Stop

    [pscustomobject]@{
        Name              = $packageManifest.name
        Version           = $packageManifest.version
        ConfigurationHash = $configurationHash
        PackagePath       = $packagePath
        PackageSizeBytes  = $packageFile.Length
        TargetOS          = $packageManifest.target.os
        Architecture      = $packageManifest.target.architecture
        DscVersion        = $packageManifest.runtime.dscVersion
        PowerShellVersion = $packageManifest.runtime.powerShellVersion
    }
}
catch {
    Write-Error "Failed to build DSC Orchestrator package: $($_.Exception.Message)"
    throw
}
finally {
    if (Test-Path -LiteralPath $stagingPath) {
        Remove-Item -LiteralPath $stagingPath -Recurse -Force -ErrorAction Stop
    }
    if (Test-Path -LiteralPath $temporaryPackagePath) {
        Remove-Item -LiteralPath $temporaryPackagePath -Force -ErrorAction Stop
    }
}
