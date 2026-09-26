[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$packageScript = Join-Path $repoRoot 'src\core\package\New-DSCv3Package.ps1'
$vmAppModulesSrc = Join-Path $repoRoot 'src\agent\windows\Modules'
$sharedYamlModule = Join-Path $repoRoot 'src\core\shared\Dsc.YamlLines.psm1'

$failures = New-Object System.Collections.Generic.List[string]
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if ($Condition) {
        Write-Host "  [pass] $Message" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] $Message" -ForegroundColor Red
        $failures.Add($Message)
    }
}

$scriptText = Get-Content -LiteralPath $packageScript -Raw
Assert-True ($scriptText -cmatch 'Join-Path\s+\$stagingPath\s+''AppModules''') "packager stages VM-app helper modules under AppModules"
Assert-True ($scriptText -cnotmatch 'Join-Path\s+\$stagingPath\s+''Modules''') "packager no longer validates staging Modules path"
Assert-True ($scriptText -notmatch '\$resolvedModulesRoot|\$psd\.BaseName\s+-ne\s+\$psd\.Directory\.Name') "manifest basename skip heuristic removed"

$tmpDir = Join-Path $PSScriptRoot ('.module-staging-{0}' -f ([guid]::NewGuid().ToString('N')))
$stagingPath = Join-Path $tmpDir 'staging'
$downloadedModules = Join-Path $stagingPath 'modules'
$appModules = Join-Path $stagingPath 'AppModules'
$localizedData = Join-Path $downloadedModules 'ComputerManagementDsc\DSCResources\DSC_Computer\en-US\DSC_Computer.strings.psd1'

try {
    New-Item -ItemType Directory -Path (Split-Path -Parent $localizedData) -Force | Out-Null
    Set-Content -LiteralPath $localizedData -Value "@{ LocalizedString = 'not a module manifest' }" -Encoding UTF8

    New-Item -ItemType Directory -Path $appModules -Force | Out-Null
    Copy-Item -Path (Join-Path $vmAppModulesSrc '*') -Destination $appModules -Recurse -Force

    $sharedModules = Join-Path $appModules 'Shared'
    New-Item -ItemType Directory -Path $sharedModules -Force | Out-Null
    Copy-Item -LiteralPath $sharedYamlModule -Destination $sharedModules -Force

    $validated = New-Object System.Collections.Generic.List[string]
    foreach ($psd in Get-ChildItem -Path $appModules -Filter '*.psd1' -Recurse -ErrorAction Stop) {
        $null = Test-ModuleManifest -Path $psd.FullName -ErrorAction Stop
        $validated.Add($psd.FullName) | Out-Null
    }

    Assert-True ($validated.Count -ge 2) "VM-app helper manifests were validated"
    Assert-True (-not [string]::Join('|', $validated).Contains('ComputerManagementDsc')) "downloaded DSC module tree was not scanned as VM-app helpers"
    Assert-True (Test-Path -LiteralPath $localizedData -PathType Leaf) "DSC localization fixture exists beside AppModules"

    $localizationWouldFail = $false
    try {
        $null = Test-ModuleManifest -Path $localizedData -ErrorAction Stop
    } catch {
        $localizationWouldFail = $true
    }
    Assert-True $localizationWouldFail "DSC localization fixture is not a module manifest"
}
finally {
    Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host "MODULE STAGING SMOKE TEST FAILED: $($failures.Count) assertion(s)." -ForegroundColor Red
    exit 1
}
Write-Host "MODULE STAGING SMOKE TEST PASSED." -ForegroundColor Green
exit 0
