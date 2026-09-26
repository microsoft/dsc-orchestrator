#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:RemoveScript = Join-Path $script:RepoRoot 'src\agent\windows\remove.ps1'
    $script:RunnerPath = Join-Path $script:RepoRoot 'tests\fixtures\Dsc.RemoveHarness.Runner.ps1'
    $script:ShellPath = (Get-Process -Id $PID -ErrorAction Stop).Path
    $script:WorkDirs = New-Object System.Collections.Generic.List[string]

    function Invoke-RemoveHarness {
        param(
            [switch]$TaskExists,
            [switch]$UnregisterFails,
            [switch]$WithLockedRuntimeFile
        )

        $work = Join-Path ([System.IO.Path]::GetTempPath()) ('dscv3-remove-' + [guid]::NewGuid().ToString('N'))
        $script:WorkDirs.Add($work)
        $dscRoot = Join-Path $work 'DscOrchestrator'
        $callLog = Join-Path $work 'calls.jsonl'
        $stateFile = Join-Path $work 'task-state.json'
        New-Item -ItemType Directory -Path $dscRoot -Force | Out-Null

        $lockedPath = $null
        $lockStream = $null
        if ($WithLockedRuntimeFile) {
            $current = Join-Path $dscRoot 'current'
            New-Item -ItemType Directory -Path $current -Force | Out-Null
            $lockedPath = Join-Path $current 'locked-runtime.bin'
            [System.IO.File]::WriteAllText($lockedPath, 'locked')
            $lockStream = [System.IO.File]::Open(
                $lockedPath,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
        }

        try {
            $runnerArgs = @(
                '-NoProfile', '-NonInteractive', '-File', $script:RunnerPath,
                '-RemoveScript', $script:RemoveScript,
                '-DscRoot', $dscRoot,
                '-CallLog', $callLog,
                '-StateFile', $stateFile
            )
            if ($TaskExists) { $runnerArgs += '-TaskExists' }
            if ($UnregisterFails) { $runnerArgs += '-UnregisterFails' }

            $stdout = (& $script:ShellPath @runnerArgs 2>&1 | Out-String)
            $exitCode = $LASTEXITCODE
        }
        finally {
            if ($null -ne $lockStream) { $lockStream.Dispose() }
        }

        $calls = @()
        if (Test-Path -LiteralPath $callLog) {
            $calls = @(Get-Content -LiteralPath $callLog | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        }
        [pscustomobject]@{
            ExitCode  = $exitCode
            Stdout    = $stdout
            CallNames = @($calls | ForEach-Object { $_.call })
            TaskState = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
            DscRoot   = $dscRoot
            LockedPath = $lockedPath
        }
    }
}

AfterAll {
    foreach ($dir in $script:WorkDirs) {
        if (Test-Path -LiteralPath $dir) {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'remove.ps1' {
    It 'returns success when the task and runtime folders are already absent' {
        $result = Invoke-RemoveHarness

        $result.ExitCode | Should -Be 0
        $result.CallNames | Should -Not -Contain 'unregister'
    }

    It 'returns a non-zero exit code when a runtime file cannot be deleted' {
        $result = Invoke-RemoveHarness -WithLockedRuntimeFile

        $result.ExitCode | Should -Not -Be 0
        Test-Path -LiteralPath $result.LockedPath | Should -BeTrue
    }

    It 'stops and disables a running task before unregistering it' {
        $result = Invoke-RemoveHarness -TaskExists

        $result.ExitCode | Should -Be 0
        $result.CallNames | Should -Contain 'disable'
        $result.CallNames | Should -Contain 'stop'
        $result.CallNames | Should -Contain 'unregister'
        [array]::IndexOf($result.CallNames, 'stop') |
            Should -BeLessThan ([array]::IndexOf($result.CallNames, 'unregister'))
        $result.TaskState.exists | Should -BeFalse
        $result.TaskState.enabled | Should -BeFalse
    }

    It 'returns a non-zero exit code when task unregistration fails' {
        $result = Invoke-RemoveHarness -TaskExists -UnregisterFails

        $result.ExitCode | Should -Not -Be 0
        $result.TaskState.exists | Should -BeTrue
    }
}
