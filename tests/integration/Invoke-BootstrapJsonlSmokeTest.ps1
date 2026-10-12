# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$vmAppRoot = Join-Path $repoRoot 'src\agent\windows'
. (Join-Path $vmAppRoot 'Write-BootstrapJsonLine.ps1')

$requiredKeys = @(
    'TimeGenerated', 'Computer', 'config_version', 'stage', 'status', 'message',
    'pwsh_source', 'pwsh_path', 'pwsh_version', 'error_type', 'error_message'
)
$payloadKeys = @('config_version', 'stage', 'status', 'message', 'pwsh_source', 'pwsh_path', 'pwsh_version', 'error_type', 'error_message')

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

$tmpDir = Join-Path $PSScriptRoot ('.smoke-{0}' -f ([guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
$jsonl = Join-Path $tmpDir 'bootstrap.jsonl'

try {
    Write-Host "Emitting bootstrap.jsonl scenarios..." -ForegroundColor Cyan

    Write-BootstrapJsonLine -Path $jsonl -Stage 'preflight' -Status 'ok' `
        -Message 'Resolved PowerShell 7' `
        -ConfigVersion '1.0.99' `
        -PwshSource 'bundled' -PwshPath 'C:\ProgramData\DscOrchestrator\current\pwsh\pwsh.exe' -PwshVersion '7.4.6'
    Write-BootstrapJsonLine -Path $jsonl -Stage 'success' -Status 'ok' `
        -Message 'Bootstrap complete for version 1.4.2' `
        -PwshSource 'bundled' -PwshPath 'C:\ProgramData\DscOrchestrator\current\pwsh\pwsh.exe' -PwshVersion '7.4.6'

    Write-BootstrapJsonLine -Path $jsonl -Stage 'fatal' -Status 'error' `
        -Message 'Bootstrap failed for version 1.4.2' `
        -ErrorType 'IOException' -ErrorMessage 'SHA256 mismatch; refusing to unzip'

    Write-BootstrapJsonLine -Path $jsonl -Stage 'fatal' -Status 'error' `
        -Message 'Bootstrap failed for version 1.4.2' `
        -ErrorType 'RuntimeException' -ErrorMessage 'Resolve-PwshExe: no PowerShell 7 found.'

    Write-BootstrapJsonLine -Path $jsonl -Stage 'fatal' -Status 'error' `
        -Message 'Bootstrap failed for version 1.4.2' `
        -PwshSource 'msi' -PwshPath 'C:\Program Files\PowerShell\7\pwsh.exe' -PwshVersion '7.4.6' `
        -ErrorType 'COMException' -ErrorMessage 'Scheduled task registration failed (0x80070005)'

    Write-Host ""
    Write-Host "Validating output..." -ForegroundColor Cyan

    Assert-True (Test-Path -LiteralPath $jsonl) "bootstrap.jsonl created"

    $bytes = [System.IO.File]::ReadAllBytes($jsonl)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    Assert-True (-not $hasBom) "file has no UTF-8 BOM"

    $lines = [System.IO.File]::ReadAllLines($jsonl)
    Assert-True ($lines.Count -eq 5) "exactly 5 rows emitted (got $($lines.Count))"

    $rowNum = 0
    foreach ($line in $lines) {
        $rowNum++
        Assert-True (-not $line.Contains("`n")) "row $rowNum is single-line"

        $obj = $null
        try { $obj = $line | ConvertFrom-Json } catch { $obj = $null }
        Assert-True ($null -ne $obj) "row $rowNum is valid JSON"
        if ($null -eq $obj) { continue }

        $keys = @($obj.PSObject.Properties.Name)
        foreach ($req in $requiredKeys) {
            Assert-True ($keys -contains $req) "row $rowNum has field '$req'"
        }
        foreach ($pk in $payloadKeys) {
            Assert-True ($pk -cmatch '^[a-z0-9_]+$') "row $rowNum payload key '$pk' is snake_case"
        }
        $td = [datetime]::MinValue
        Assert-True ([datetime]::TryParse([string]$obj.TimeGenerated, [ref]$td)) "row $rowNum TimeGenerated parses as datetime"
    }

    $firstRow = $lines[0] | ConvertFrom-Json
    Assert-True ($firstRow.config_version -eq '1.0.99') "config_version flows through to the row ('$($firstRow.config_version)')"
}
finally {
    Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host "SMOKE TEST FAILED: $($failures.Count) assertion(s)." -ForegroundColor Red
    exit 1
}
Write-Host "SMOKE TEST PASSED." -ForegroundColor Green
exit 0
