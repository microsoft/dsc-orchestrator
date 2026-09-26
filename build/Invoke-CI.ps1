[CmdletBinding()]
param(
    [string] $ResultsDirectory
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$sourceRoot = Join-Path $repoRoot 'src'
$testsRoot = Join-Path $repoRoot 'tests'
$settingsPath = Join-Path (Join-Path $repoRoot '.config') 'PSScriptAnalyzerSettings.psd1'

if ([string]::IsNullOrWhiteSpace($ResultsDirectory)) {
    $runId = [guid]::NewGuid().ToString('N')
    $ResultsDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "dsc-orchestrator-ci-$runId"
}

$ResultsDirectory = [System.IO.Path]::GetFullPath($ResultsDirectory)
New-Item -ItemType Directory -Path $ResultsDirectory -Force | Out-Null
Write-Host "CI reports directory: $ResultsDirectory"

$testResultsPath = Join-Path $ResultsDirectory 'testResults.xml'
$coveragePath = Join-Path $ResultsDirectory 'coverage.xml'

function Set-CIPipelineVariable {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [bool] $Value
    )

    if ($env:TF_BUILD -eq 'True') {
        $valueText = $Value.ToString().ToLowerInvariant()
        Write-Host "##vso[task.setvariable variable=$Name]$valueText"
    }
}

function Assert-CIPesterResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Result
    )

    $failureReasons = @()
    if ($Result.Result -ne 'Passed') {
        $failureReasons += "Result was '$($Result.Result)' (expected 'Passed')"
    }
    if ($Result.FailedCount -gt 0) {
        $failureReasons += "$($Result.FailedCount) failed test(s)"
    }
    if ($Result.FailedBlocksCount -gt 0) {
        $failureReasons += "$($Result.FailedBlocksCount) failed block(s)"
    }
    if ($Result.FailedContainersCount -gt 0) {
        $failureReasons += "$($Result.FailedContainersCount) failed container(s)"
    }

    if ($failureReasons.Count -gt 0) {
        throw "Pester failed: $($failureReasons -join '; ')."
    }
}

Set-CIPipelineVariable -Name 'ciHasTestResults' -Value $false
Set-CIPipelineVariable -Name 'ciHasCoverage' -Value $false

$requiredModules = @(
    @{ Name = 'Pester'; Version = '5.7.1' }
    @{ Name = 'PSScriptAnalyzer'; Version = '1.25.0' }
    @{ Name = 'powershell-yaml'; Version = '0.4.12' }
)

foreach ($module in $requiredModules) {
    $availableVersion = Get-Module -ListAvailable -Name $module.Name |
        Where-Object { $_.Version.ToString() -eq $module.Version } |
        Select-Object -First 1

    if (-not $availableVersion) {
        $installedPackage = $null
        if (Get-Command -Name Get-InstalledModule -ErrorAction SilentlyContinue) {
            $installedPackage = Get-InstalledModule -Name $module.Name `
                -RequiredVersion $module.Version -ErrorAction SilentlyContinue
        }

        if (-not $installedPackage) {
            Write-Host "Installing $($module.Name) $($module.Version) from PSGallery (CurrentUser scope)."
            Install-Module -Name $module.Name -RequiredVersion $module.Version `
                -Repository PSGallery -Scope CurrentUser -Force -ErrorAction Stop
            $installedPackage = Get-InstalledModule -Name $module.Name `
                -RequiredVersion $module.Version -ErrorAction Stop
        }

        $moduleManifest = Join-Path $installedPackage.InstalledLocation "$($module.Name).psd1"
        if (-not (Test-Path -LiteralPath $moduleManifest -PathType Leaf)) {
            throw "Installed module manifest not found: $moduleManifest"
        }

        Import-Module -Name $moduleManifest -ErrorAction Stop
        continue
    }

    Import-Module -Name $module.Name -RequiredVersion $module.Version -ErrorAction Stop
}

if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
    throw "PSScriptAnalyzer settings file not found: $settingsPath"
}

$sourceFiles = @()
if (Test-Path -LiteralPath $sourceRoot -PathType Container) {
    $sourceFiles = @(
        Get-ChildItem -LiteralPath $sourceRoot -Recurse -File |
            Where-Object { $_.Extension -in @('.ps1', '.psm1', '.psd1') }
    )
}
$coverageFiles = @(
    $sourceFiles | Where-Object { $_.Extension -in @('.ps1', '.psm1') }
)

if ($sourceFiles.Count -eq 0) {
    Write-Host "PSScriptAnalyzer: no PowerShell files found under src; skipping."
} else {
    Write-Host "Running PSScriptAnalyzer over src ($($sourceFiles.Count) file(s))."
    $findings = @(
        Invoke-ScriptAnalyzer -Path $sourceRoot -Recurse -Settings $settingsPath |
            Where-Object { $_.Severity -in @('Error', 'Warning') }
    )

    if ($findings.Count -gt 0) {
        $findings |
            Select-Object Severity, RuleName, ScriptName, Line, Column, Message |
            Format-Table -AutoSize -Wrap |
            Out-String -Width 240 |
            Write-Host
        throw "PSScriptAnalyzer found $($findings.Count) Error/Warning diagnostic(s)."
    }

    Write-Host 'PSScriptAnalyzer: clean (0 Error, 0 Warning).'
}

$testFiles = @()
if (Test-Path -LiteralPath $testsRoot -PathType Container) {
    $testFiles = @(
        Get-ChildItem -LiteralPath $testsRoot -Recurse -File -Filter '*.Tests.ps1'
    )
}

if ($testFiles.Count -eq 0) {
    Write-Host 'Pester: no *.Tests.ps1 files found under tests; skipping.'
} else {
    $configuration = New-PesterConfiguration
    $configuration.Run.Path = @($testFiles | ForEach-Object { $_.FullName })
    $configuration.Run.PassThru = $true
    $configuration.TestResult.Enabled = $true
    $configuration.TestResult.OutputFormat = 'NUnitXml'
    $configuration.TestResult.OutputPath = $testResultsPath

    if ($coverageFiles.Count -gt 0) {
        $configuration.CodeCoverage.Enabled = $true
        $configuration.CodeCoverage.Path = @($coverageFiles | ForEach-Object { $_.FullName })
        $configuration.CodeCoverage.OutputFormat = 'JaCoCo'
        $configuration.CodeCoverage.OutputPath = $coveragePath
    }

    Write-Host "Running Pester over tests ($($testFiles.Count) test file(s))."
    $result = Invoke-Pester -Configuration $configuration

    if (-not (Test-Path -LiteralPath $testResultsPath -PathType Leaf)) {
        throw "Pester did not create the NUnit test results file: $testResultsPath"
    }

    Set-CIPipelineVariable -Name 'ciHasTestResults' -Value $true

    if ($coverageFiles.Count -gt 0) {
        if (-not (Test-Path -LiteralPath $coveragePath -PathType Leaf)) {
            throw "Pester did not create the JaCoCo coverage file: $coveragePath"
        }

        Set-CIPipelineVariable -Name 'ciHasCoverage' -Value $true
    } else {
        Write-Host 'Pester code coverage: no executable src PowerShell files found; skipping JaCoCo output.'
    }

    Write-Host ('Pester summary: {0} passed, {1} failed, {2} skipped.' -f `
        $result.PassedCount, $result.FailedCount, $result.SkippedCount)

    Assert-CIPesterResult -Result $result
}
