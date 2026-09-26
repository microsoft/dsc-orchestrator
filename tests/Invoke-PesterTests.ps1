<#
.SYNOPSIS
    CI/local entry point for the DSC Orchestrator Pester v5 unit suite.
.DESCRIPTION
    Discovers and runs every *.Tests.ps1 under tests/, emits a test-result file
    (NUnitXml by default), and sets a non-zero exit code if any test fails.

    The hand-rolled smoke scripts (Invoke-*SmokeTest.ps1) are NOT Pester files and
    are intentionally not discovered here.
.PARAMETER ResultsPath
    Full path of the test-result file to write. Default:
    tests/TestResults/Pester.NUnit.xml
.PARAMETER OutputFormat
    Pester TestResult format. 'NUnitXml' (default) and 'JUnitXml' are supported.
.PARAMETER Verbosity
    Pester console verbosity (default 'Detailed').
.EXAMPLE
    pwsh -NoProfile -File tests/Invoke-PesterTests.ps1
.NOTES
    Requires Pester v5+. Validated against Pester 5.7.1 on PowerShell 7.6.2.
#>
[CmdletBinding()]
param(
    [string]$ResultsPath = (Join-Path $PSScriptRoot 'TestResults\Pester.NUnit.xml'),
    [ValidateSet('NUnitXml', 'NUnit2.5', 'JUnitXml')][string]$OutputFormat = 'NUnitXml',
    [ValidateSet('None', 'Normal', 'Detailed', 'Diagnostic')][string]$Verbosity = 'Detailed'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$pester = Get-Module -ListAvailable -Name Pester |
    Where-Object { $_.Version -ge [version]'5.0.0' } |
    Sort-Object Version -Descending |
    Select-Object -First 1
if (-not $pester) {
    throw "Pester v5+ is required. Install with: Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force"
}
Import-Module Pester -MinimumVersion 5.0.0 -Force

$resultsDir = Split-Path -Parent $ResultsPath
if (-not (Test-Path -LiteralPath $resultsDir)) {
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
}

$config = New-PesterConfiguration
$config.Run.Path = $PSScriptRoot           # discovers *.Tests.ps1 recursively under tests/
$config.Run.Exit = $true                   # non-zero exit on failure -> CI gate
$config.Output.Verbosity = $Verbosity
$config.TestResult.Enabled = $true
$config.TestResult.OutputFormat = $OutputFormat
$config.TestResult.OutputPath = $ResultsPath

Invoke-Pester -Configuration $config
