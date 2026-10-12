# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'The scheduled-task launcher emits concise process status for its task transcript.')]
param(
    [switch]$AuditOnly,
    [string]$DscRoot = 'C:\ProgramData\DscOrchestrator',
    [string]$LogDir = '',
    [string]$RegistryRoot = 'HKLM:\SOFTWARE\DscOrchestrator\Reboot'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'Resolve-PwshExe.ps1')

$enforcementScript = Join-Path $PSScriptRoot 'Invoke-Enforcement.ps1'
if (-not (Test-Path -LiteralPath $enforcementScript)) {
    throw "Enforcement script not found: $enforcementScript"
}


if ([string]::IsNullOrWhiteSpace($LogDir)) {
    $LogDir = Join-Path $DscRoot 'logs'
}
$DscRoot = [System.IO.Path]::GetFullPath($DscRoot)
$LogDir = [System.IO.Path]::GetFullPath($LogDir)

$pwshInfo = Resolve-PwshExe
$pwsh = $pwshInfo.Path
Write-Host "[Run-Enforcement] Resolved pwsh: $pwsh (source=$($pwshInfo.Source), version=$($pwshInfo.Version))"

# Marker is written before task registration because the task fires immediately.
# Delete is best-effort; failure only over-tags one run as initial.
$initialRunMarker = Join-Path $LogDir '.initial-run'
$runTrigger = 'scheduled'
if (Test-Path -LiteralPath $initialRunMarker) {
    $runTrigger = 'initial'
    Remove-Item -LiteralPath $initialRunMarker -Force -ErrorAction SilentlyContinue
}

# pwsh -Command does not propagate script exit codes unless we exit explicitly.
$dscRootEscaped = $DscRoot -replace "'", "''"
$logDirEscaped  = $LogDir -replace "'", "''"
$registryRootEscaped = $RegistryRoot -replace "'", "''"
$enforcementEscaped = $enforcementScript -replace "'", "''"
$auditFlag = if ($AuditOnly) { ' -AuditOnly' } else { '' }
# Resource modules are synced to WinPS AllUsers during bootstrap; adding package modules here creates duplicate module identities for the WinPS adapter.
$innerCommand = "& '$enforcementEscaped'$auditFlag -DscRoot '$dscRootEscaped' -LogDir '$logDirEscaped' -RegistryRoot '$registryRootEscaped' -RunTrigger '$runTrigger'; exit `$LASTEXITCODE"

& $pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $innerCommand
$childExit = $LASTEXITCODE
Write-Host "[Run-Enforcement] pwsh exited with code $childExit"
exit $childExit
