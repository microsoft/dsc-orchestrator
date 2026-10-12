# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

#Requires -Modules Pester

# Covers the runtime-swap quiesce path: Stop-DscEnforcementProcess (kill the enforcement tree so the
# task-stop invariant holds) and Wait-ForRuntimeFilesUnlocked (confirm the runtime is unlocked, fail
# clean on timeout). Imported via the aggregate manifest so a missing FunctionsToExport entry fails
# here rather than silently at runtime.

BeforeAll {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ModuleRoot = Join-Path $script:RepoRoot 'src\agent\windows\Modules'
    Import-Module (Join-Path $script:ModuleRoot 'Dsc.Bootstrap.psd1') -Force -DisableNameChecking

    $script:DscRoot = 'C:\ProgramData\DscOrchestrator'

    function New-FakeProc {
        param([int]$Id, [string]$Name, [string]$ExecutablePath = $null, [string]$CommandLine = $null)
        [pscustomobject]@{ ProcessId = $Id; Name = $Name; ExecutablePath = $ExecutablePath; CommandLine = $CommandLine }
    }
}

Describe 'Stop-DscEnforcementProcess' {

    BeforeEach {
        $script:stopped = New-Object System.Collections.Generic.List[int]
        $script:recorder = { param($ProcessId) $script:stopped.Add([int]$ProcessId) }
        $script:providerCalls = 0
    }

    It 'stops dsc.exe (image path under DscRoot) and the enforcement PowerShell hosts, then returns once they exit' {
        $root = $script:DscRoot
        $provider = {
            $script:providerCalls++
            if ($script:providerCalls -eq 1) {
                @(
                    New-FakeProc -Id 101 -Name 'dsc.exe' -ExecutablePath "$root\current\dsc.exe" -CommandLine "`"$root\current\dsc.exe`" config set"
                    New-FakeProc -Id 102 -Name 'pwsh.exe' -ExecutablePath 'C:\Program Files\PowerShell\7\pwsh.exe' -CommandLine "pwsh -Command `"& '$root\current\Invoke-Enforcement.ps1' -DscRoot '$root'`""
                    New-FakeProc -Id 103 -Name 'powershell.exe' -ExecutablePath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -CommandLine "powershell -File `"$root\current\Run-Enforcement.ps1`" -DscRoot `"$root`""
                )
            }
            else { @() }
        }

        Stop-DscEnforcementProcess -DscRoot $root -TimeoutSeconds 5 -ProcessProvider $provider -StopProcess $script:recorder

        ($script:stopped -join ',') | Should -Be '101,102,103'
    }

    It 'never targets the current process, even if it matches by path' {
        $root = $script:DscRoot
        $provider = {
            @(
                New-FakeProc -Id $PID -Name 'pwsh.exe' -ExecutablePath "$root\current\dsc.exe" -CommandLine 'self'
                New-FakeProc -Id 201 -Name 'dsc.exe' -ExecutablePath "$root\current\dsc.exe" -CommandLine 'target'
            )
        }

        # 201 never disappears from the provider, so this throws; assert self was still excluded.
        { Stop-DscEnforcementProcess -DscRoot $root -TimeoutSeconds 1 -ProcessProvider $provider -StopProcess $script:recorder } |
            Should -Throw '*still running after*'
        $script:stopped | Should -Not -Contain $PID
        $script:stopped | Should -Contain 201
    }

    It 'never targets the bootstrap process, even when it references an enforcement script' {
        $root = $script:DscRoot
        $provider = {
            @( New-FakeProc -Id 301 -Name 'powershell.exe' -CommandLine "powershell -Command `"...GetEntry('bootstrap.ps1'); & 'C:\ProgramData\DscOrchestrator\current\Invoke-Enforcement.ps1' -Update`"" )
        }

        Stop-DscEnforcementProcess -DscRoot $root -TimeoutSeconds 2 -ProcessProvider $provider -StopProcess $script:recorder
        $script:stopped.Count | Should -Be 0
    }

    It 'is a no-op when nothing matches' {
        $provider = { @( New-FakeProc -Id 401 -Name 'notepad.exe' -ExecutablePath 'C:\Windows\notepad.exe' -CommandLine 'notepad' ) }
        Stop-DscEnforcementProcess -DscRoot $script:DscRoot -TimeoutSeconds 2 -ProcessProvider $provider -StopProcess $script:recorder
        $script:stopped.Count | Should -Be 0
    }

    It 'throws if targeted processes never exit' {
        $root = $script:DscRoot
        $provider = { @( New-FakeProc -Id 101 -Name 'dsc.exe' -ExecutablePath "$root\current\dsc.exe" -CommandLine 'x' ) }
        { Stop-DscEnforcementProcess -DscRoot $root -TimeoutSeconds 2 -ProcessProvider $provider -StopProcess $script:recorder } |
            Should -Throw '*still running after*'
    }
}

Describe 'Wait-ForRuntimeFilesUnlocked' {

    BeforeEach {
        $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("dscv3-wait-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:tmp -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:tmp) {
            Remove-Item -LiteralPath $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns when no file is locked' {
        Set-Content -LiteralPath (Join-Path $script:tmp 'a.txt') -Value 'x'
        New-Item -ItemType Directory -Path (Join-Path $script:tmp 'sub') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:tmp 'sub\b.dll') -Value 'y'
        { Wait-ForRuntimeFilesUnlocked -Path $script:tmp -TimeoutSeconds 2 } | Should -Not -Throw
    }

    It 'returns immediately when the directory does not exist' {
        { Wait-ForRuntimeFilesUnlocked -Path (Join-Path $script:tmp 'missing') -TimeoutSeconds 2 } | Should -Not -Throw
    }

    It 'throws on timeout when a file stays locked' {
        $locked = Join-Path $script:tmp 'locked.bin'
        Set-Content -LiteralPath $locked -Value 'z'
        $fs = [System.IO.File]::Open($locked, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        try {
            { Wait-ForRuntimeFilesUnlocked -Path $script:tmp -TimeoutSeconds 1 } | Should -Throw '*still locked after*'
        }
        finally {
            $fs.Dispose()
        }
    }

    It 'throws a clear error when file enumeration fails instead of treating the runtime as unlocked' {
        Set-Content -LiteralPath (Join-Path $script:tmp 'a.txt') -Value 'x'
        $throwingProvider = { throw 'access denied enumerating subtree' }
        { Wait-ForRuntimeFilesUnlocked -Path $script:tmp -TimeoutSeconds 2 -FileProvider $throwingProvider } |
            Should -Throw '*Failed to enumerate runtime files*'
    }

    # Source pin: the ordering inside Replace-CurrentContent is not observable from a passing run.
    It 'is called by Replace-CurrentContent before it removes current (v1.6.5 pin)' {
        $source = Get-Content -LiteralPath (Join-Path $script:ModuleRoot 'Dsc.Bootstrap.Staging.psm1') -Raw
        $waitIndex   = $source.IndexOf('Wait-ForRuntimeFilesUnlocked -Path $Destination')
        $removeIndex = $source.IndexOf('Remove-CurrentPath -Path $Destination')
        $waitIndex   | Should -BeGreaterThan -1
        $removeIndex | Should -BeGreaterThan $waitIndex
    }
}
