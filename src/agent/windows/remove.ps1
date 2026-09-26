<#
.SYNOPSIS
    Removes DSCv3 enforcement from VM.

.DESCRIPTION
    Unregisters scheduled task and deletes runtime data. Logs/state preserved
    unless -Purge specified. PowerShell modules left in place—other components
    may depend on them. Safe to run even if DSCv3 was never fully installed.
#>

[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'The removal entry point provides operator-facing status while preserving its existing command-line behavior.')]
param(
    [Parameter(Mandatory = $false)]
    [switch]$Purge,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$DscRoot = 'C:\ProgramData\DscOrchestrator',

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$TaskName = 'DscOrchestrator-Enforcement',

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$AllUsersModulesPath = 'C:\Program Files\WindowsPowerShell\Modules'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$DscRoot = [System.IO.Path]::GetFullPath($DscRoot)
$securityModulePath = @(
    (Join-Path $PSScriptRoot 'AppModules\Dsc.Security.psm1')
    (Join-Path $PSScriptRoot 'Modules\Dsc.Security.psm1')
) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
    Select-Object -First 1
if (-not $securityModulePath) {
    throw "Dsc.Security.psm1 was not found beside remove.ps1."
}
Import-Module -Name $securityModulePath -DisableNameChecking -ErrorAction Stop
Dsc.Security\Initialize-DscOrchestratorRoot -Path $DscRoot

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "DSCv3 Remove"                             -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

Write-Host ""
Write-Host "Step 1: Removing scheduled task..." -ForegroundColor Cyan

$existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existingTask) {
    try {
        Disable-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Out-Null
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "  Scheduled task removed." -ForegroundColor Green
    }
    catch {
        Write-Host "  WARNING: Could not fully remove task: $_" -ForegroundColor Yellow
    }
}
else {
    Write-Host "  No scheduled task found - skipping." -ForegroundColor Gray
}

Write-Host ""
Write-Host "Step 2: Removing Orchestrator runtime directory..." -ForegroundColor Cyan

foreach ($runtimeChild in @('current', 'staging')) {
    $runtimePath = Join-Path $DscRoot $runtimeChild
    Dsc.Security\Remove-DscOrchestratorPathSafely -Path $runtimePath
    Write-Host "  Removed: $runtimePath" -ForegroundColor Green
}

if ($Purge.IsPresent) {
    $logsRoot = Join-Path $DscRoot 'logs'
    Dsc.Security\Remove-DscOrchestratorPathSafely -Path $logsRoot
    Write-Host "  Purged logs/state: $logsRoot" -ForegroundColor Green
}
else {
    Write-Host "  Preserved logs/state under: $(Join-Path $DscRoot 'logs')" -ForegroundColor Gray
}

Write-Host ""
Write-Host "NOTE: PowerShell modules in '$AllUsersModulesPath' were NOT removed." -ForegroundColor Gray
Write-Host "      Other components may depend on them." -ForegroundColor Gray

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "DSCv3 Remove Complete"                    -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green

exit 0
