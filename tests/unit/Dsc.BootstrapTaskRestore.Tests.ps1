# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

#Requires -Modules Pester

# Bootstrap disable-window contract: Step 5 disables the named enforcement task and only a
# completed Step 9 puts it back, so a catchable failure in between used to leave the host silently
# unenforced. Behavioural: the real bootstrap.ps1 runs end to end against a fake package on a temp
# DSC root, in a child pwsh where the scheduled-task cmdlets are shadowed by recording globals
# (fixtures\Dsc.BootstrapHarness.Runner.ps1) -- bootstrap.ps1 has no injection seam and cannot
# register a real task in CI.

# Evaluated at discovery so -Skip sees it. Creating an Administrators-owned folder requires elevation; runs on elevated CI.
$script:IsAdmin = [System.Security.Principal.WindowsPrincipal]::new(
    [System.Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
BeforeAll {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:VmAppRoot = Join-Path $script:RepoRoot 'src\agent\windows'
    $script:RunnerPath = Join-Path $script:RepoRoot 'tests\fixtures\Dsc.BootstrapHarness.Runner.ps1'
    $script:PwshPath    = (Get-Command pwsh -CommandType Application -ErrorAction Stop).Source
    $script:WorkDirs    = New-Object System.Collections.Generic.List[string]
    # Creating an Administrators-owned folder requires elevation; runs on elevated CI.
    $script:IsAdmin = [System.Security.Principal.WindowsPrincipal]::new(
        [System.Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)

    function New-BootstrapFakePackage {
        param(
            [Parameter(Mandatory = $true)][string]$Path,
            [string]$ManifestVersion = '1.0.0'
        )

        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        foreach ($file in @('bootstrap.ps1', 'Resolve-PwshExe.ps1', 'Write-BootstrapJsonLine.ps1',
                            'Run-Enforcement.ps1', 'Invoke-Enforcement.ps1', 'remove.ps1')) {
            Copy-Item -LiteralPath (Join-Path $script:VmAppRoot $file) -Destination $Path -Force
        }
        # The package ships the bootstrap helpers as AppModules\; bootstrap.ps1 imports that path.
        Copy-Item -LiteralPath (Join-Path $script:VmAppRoot 'Modules') -Destination (Join-Path $Path 'AppModules') -Recurse -Force

        Set-Content -LiteralPath (Join-Path $Path 'dsc.exe') -Value 'fake-dsc' -Force
        [ordered]@{ version = $ManifestVersion } |
            ConvertTo-Json -Compress |
            Set-Content -LiteralPath (Join-Path $Path 'manifest.json') -Force
        New-Item -ItemType Directory -Path (Join-Path $Path 'configs') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Path 'configs\harness.dsc.yaml') -Value "resources: []" -Force
    }

    function Invoke-BootstrapHarness {
        param(
            [ValidateSet('none', 'swap', 'register', 'start')][string]$FailAt = 'none',
            [switch]$TaskExists,
            [switch]$TaskInitiallyDisabled,
            [switch]$EnableFails,
            [switch]$WithExistingRuntime,
            [switch]$WithStalePreviousRuntime,
            [switch]$DscRootTrailingSeparator,
            [string]$ManifestVersion = '1.0.0'
        )

        $work = Join-Path ([System.IO.Path]::GetTempPath()) ("dscv3-bootstrap-" + [guid]::NewGuid().ToString('N'))
        $script:WorkDirs.Add($work)
        $package = Join-Path $work 'package'
        $dscRoot = Join-Path $work 'DscOrchestrator'
        $runnerDscRoot = if ($DscRootTrailingSeparator) { $dscRoot + '\' } else { $dscRoot }
        $callLog = Join-Path $work 'calls.jsonl'
        $errFile = Join-Path $work 'error.txt'
        $stateFile = Join-Path $work 'task-state.json'
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        New-BootstrapFakePackage -Path $package -ManifestVersion $ManifestVersion

        $runnerArgs = @(
            '-NoProfile', '-NonInteractive', '-File', $script:RunnerPath,
            '-PackageRoot', $package,
            '-DscRoot', $runnerDscRoot,
            '-CallLog', $callLog,
            '-ErrorFile', $errFile,
            '-StateFile', $stateFile,
            '-FailAt', $FailAt
        )
        if ($TaskExists)            { $runnerArgs += '-TaskExists' }
        if ($TaskInitiallyDisabled) { $runnerArgs += '-TaskInitiallyDisabled' }
        if ($EnableFails)           { $runnerArgs += '-EnableFails' }
        if ($WithExistingRuntime)   { $runnerArgs += '-WithExistingRuntime' }
        if ($WithStalePreviousRuntime) { $runnerArgs += '-WithStalePreviousRuntime' }

        $stdout = (& $script:PwshPath @runnerArgs 2>&1 | Out-String)
        $exitCode = $LASTEXITCODE

        $calls = @()
        if (Test-Path -LiteralPath $callLog) {
            $calls = @(Get-Content -LiteralPath $callLog | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        }
        $bootstrapJsonl = Join-Path $dscRoot 'logs\bootstrap.jsonl'
        $rows = @()
        if (Test-Path -LiteralPath $bootstrapJsonl) {
            $rows = @(Get-Content -LiteralPath $bootstrapJsonl | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        }

        [pscustomobject]@{
            ExitCode     = $exitCode
            Stdout       = $stdout
            Error        = if (Test-Path -LiteralPath $errFile) { Get-Content -LiteralPath $errFile -Raw } else { '' }
            Calls        = $calls
            CallNames    = @($calls | ForEach-Object { $_.call })
            Rows         = $rows
            TaskState    = if (Test-Path -LiteralPath $stateFile) {
                Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
            } else {
                throw "Bootstrap harness runner exited ($exitCode) before writing its task state. Runner output: $stdout"
            }
            DscRoot      = $dscRoot
            PackageRoot  = $package
        }
    }
}

AfterAll {
    foreach ($dir in $script:WorkDirs) {
        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'bootstrap.ps1 enforcement-task restoration' {

    Context 'update flow, failure after the Step 5 disable' {

        It 'rejects a PackageRoot manifest version that differs from -Version' -Skip:(-not $script:IsAdmin) {
            $result = Invoke-BootstrapHarness -ManifestVersion '2.0.0'

            $result.ExitCode | Should -Be 3
            $result.Error | Should -BeLike '*manifest version*does not match requested version*'
            $result.CallNames | Should -Not -Contain 'register'
            Test-Path -LiteralPath (Join-Path $result.DscRoot 'current') | Should -BeFalse
        }

        It 'restores the task when the registration itself fails (Step 9, last statement in the window)' -Skip:(-not $script:IsAdmin) {
            # Tightest boundary on the registration-complete flag: set it any earlier and this regresses.
            $result = Invoke-BootstrapHarness -FailAt 'register' -TaskExists -WithExistingRuntime

            $result.ExitCode  | Should -Be 3
            $result.Error     | Should -BeLike '*registering the scheduled task (injected)*'
            $result.CallNames | Should -Contain 'disable'
            $result.CallNames | Should -Contain 'register'
            $result.CallNames | Should -Not -Contain 'start'
            $result.CallNames | Should -Contain 'enable'
            [array]::IndexOf($result.CallNames, 'enable') | Should -BeGreaterThan ([array]::IndexOf($result.CallNames, 'register'))
            $result.TaskState.enabled | Should -BeTrue

            # Cleanup, not success masking: the fatal row still names the original failure.
            $fatal = @($result.Rows | Where-Object { $_.stage -eq 'fatal' })
            $fatal.Count | Should -Be 1
            $fatal[0].error_message | Should -BeLike '*registering the scheduled task (injected)*'
            $fatal[0].message       | Should -BeLike '*task_restore=restored*'
            @($result.Rows | Where-Object { $_.stage -eq 'success' }).Count | Should -Be 0
        }

        It 'does not re-enable after Start-ScheduledTask fails, because registration already closed the window' -Skip:(-not $script:IsAdmin) {
            # Upper boundary of the same flag: once Register returned, the task is registered and
            # enabled, so a later Start failure owes no Enable call.
            $result = Invoke-BootstrapHarness -FailAt 'start' -TaskExists -WithExistingRuntime

            $result.ExitCode  | Should -Be 3
            $result.Error     | Should -BeLike '*could not be started (injected)*'
            $result.CallNames | Should -Contain 'register'
            $result.CallNames | Should -Contain 'start'
            $result.CallNames | Should -Not -Contain 'enable'
            $result.TaskState.exists  | Should -BeTrue
            $result.TaskState.enabled | Should -BeTrue

            @($result.Rows | Where-Object { $_.stage -eq 'success' }).Count | Should -Be 0
            @($result.Rows | Where-Object { $_.stage -eq 'fatal' })[0].message | Should -BeLike '*task_restore=not_needed*'
        }

        It 'restores a task an operator had already disabled when the runtime swap fails mid-replacement' -Skip:(-not $script:IsAdmin) {
            # The restore keys off "a task pre-existed", not off "this run disabled an enabled one":
            # a successful bootstrap does not preserve an operator disable either (Register -Force).
            $result = Invoke-BootstrapHarness -FailAt 'swap' -TaskExists -TaskInitiallyDisabled -WithExistingRuntime

            $result.ExitCode  | Should -Be 3
            $result.Error     | Should -BeLike '*is denied (injected)*'
            $result.CallNames | Should -Contain 'enable'
            $result.CallNames | Should -Not -Contain 'register'
            $result.TaskState.enabled | Should -BeTrue

            # The swap failure must preserve the old runtime so the re-enabled task remains runnable.
            Test-Path -LiteralPath (Join-Path $result.DscRoot 'current\version.txt') | Should -BeTrue
            (Get-Content -LiteralPath (Join-Path $result.DscRoot 'current\version.txt') -ErrorAction Stop) -join '' |
                Should -BeExactly '0.0.1-old'
            Test-Path -LiteralPath (Join-Path $result.DscRoot 'current.previous') | Should -BeFalse
        }
    }

    Context 'update flow, successful bootstrap' {

        BeforeAll {
            if ($script:IsAdmin) {
                $script:success = Invoke-BootstrapHarness -TaskExists -WithExistingRuntime
            }
        }

        It 'completes and registers the task exactly once, with no unregister and no restore' -Skip:(-not $script:IsAdmin) {
            $script:success.ExitCode | Should -Be 0
            @($script:success.CallNames | Where-Object { $_ -eq 'register' }).Count | Should -Be 1
            $script:success.CallNames | Should -Not -Contain 'unregister'
            $script:success.CallNames | Should -Not -Contain 'enable'
            $script:success.CallNames | Should -Contain 'start'

            $final = $script:success.TaskState
            $final.exists  | Should -BeTrue
            $final.enabled | Should -BeTrue
            @($script:success.Rows | Where-Object { $_.stage -eq 'success' }).Count | Should -Be 1

            # Replace-CurrentContent stages at the sibling "$Destination.new" and must land it, not leave it.
            Test-Path -LiteralPath (Join-Path $script:success.DscRoot 'current.new') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $script:success.DscRoot 'current.previous') | Should -BeFalse
        }

        It 'removes a stale current.previous directory left by a prior interrupted upgrade' -Skip:(-not $script:IsAdmin) {
            $result = Invoke-BootstrapHarness -WithExistingRuntime -WithStalePreviousRuntime

            $result.ExitCode | Should -Be 0
            Test-Path -LiteralPath (Join-Path $result.DscRoot 'current\version.txt') | Should -BeTrue
            (Get-Content -LiteralPath (Join-Path $result.DscRoot 'current\version.txt') -ErrorAction Stop) -join '' |
                Should -BeExactly '1.0.0'
            Test-Path -LiteralPath (Join-Path $result.DscRoot 'current.previous') | Should -BeFalse
        }

        It 'preserves the registration arguments and settings' -Skip:(-not $script:IsAdmin) {
            $register = @($script:success.Calls | Where-Object { $_.call -eq 'register' })[0]
            $register.force              | Should -BeTrue
            $register.execute            | Should -Be 'powershell.exe'
            $register.arguments          | Should -BeLike ('*-File "{0}"*' -f (Join-Path $script:success.DscRoot 'current\Run-Enforcement.ps1'))
            $register.arguments          | Should -BeLike ('*-DscRoot "{0}"*' -f $script:success.DscRoot)
            $register.arguments          | Should -BeLike ('*-LogDir "{0}"*' -f (Join-Path $script:success.DscRoot 'logs'))
            $register.arguments          | Should -Not -BeLike '*-AuditOnly*'
            $register.multipleInstances  | Should -Be 'IgnoreNew'
            $register.executionTimeLimit | Should -Be ([string]([System.Xml.XmlConvert]::ToString([timespan]::FromMinutes(180))))
            $register.userId             | Should -Be 'SYSTEM'

            Test-Path -LiteralPath (Join-Path $script:success.DscRoot 'logs\.initial-run') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $script:success.DscRoot 'current\Run-Enforcement.ps1') | Should -BeTrue
        }

        It 'quotes a DscRoot with a trailing separator without escaping the closing quote' -Skip:(-not $script:IsAdmin) {
            $result = Invoke-BootstrapHarness -TaskExists -DscRootTrailingSeparator
            $register = @($result.Calls | Where-Object { $_.call -eq 'register' })[0]
            $escapedRoot = '"' + $result.DscRoot + '\\' + '"'

            $result.ExitCode | Should -Be 0
            $register.arguments | Should -BeLike ('*-DscRoot {0} -LogDir*' -f $escapedRoot)
            $register.arguments | Should -BeLike ('*-LogDir "{0}"*' -f (Join-Path $result.DscRoot 'logs'))
        }
    }

    Context 'fresh install, no pre-existing task' {

        It 'never fabricates a task when the registration itself fails' -Skip:(-not $script:IsAdmin) {
            # Nothing pre-existed, so nothing may be conjured by an Enable against a name that was
            # never registered -- even though the run reached the far end of the window.
            $result = Invoke-BootstrapHarness -FailAt 'register'

            $result.ExitCode  | Should -Be 3
            $result.Error     | Should -BeLike '*registering the scheduled task (injected)*'
            $result.CallNames | Should -Contain 'register'
            $result.CallNames | Should -Not -Contain 'enable'
            $result.TaskState.exists | Should -BeFalse

            @($result.Rows | Where-Object { $_.stage -eq 'fatal' })[0].message | Should -BeLike '*task_restore=not_needed*'
        }
    }

    Context 'restoration failure' {

        It 'surfaces a failed restore without replacing the original bootstrap error' -Skip:(-not $script:IsAdmin) {
            $result = Invoke-BootstrapHarness -FailAt 'swap' -TaskExists -EnableFails -WithExistingRuntime

            $result.ExitCode | Should -Be 3
            $result.Error    | Should -BeLike '*is denied (injected)*'
            $result.Error    | Should -Not -BeLike '*enabling the scheduled task (injected)*'
            $result.Stdout   | Should -BeLike '*WARNING: could not restore enforcement task*'

            $fatal = @($result.Rows | Where-Object { $_.stage -eq 'fatal' })
            $fatal.Count | Should -Be 1
            $fatal[0].error_message | Should -BeLike '*is denied (injected)*'
            $fatal[0].message       | Should -BeLike '*task_restore=failed: *enabling the scheduled task (injected)*'
            $result.TaskState.enabled | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $result.DscRoot 'current\version.txt') | Should -BeTrue
            (Get-Content -LiteralPath (Join-Path $result.DscRoot 'current\version.txt') -ErrorAction Stop) -join '' |
                Should -BeExactly '0.0.1-old'
        }
    }
}
