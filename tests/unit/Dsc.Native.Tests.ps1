# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pester v5 unit suite for set-abort plumbing in Dsc.Native.psm1 +
    Dsc.Lifecycle.psm1 — the abort signal (Aborted/Unreached), the retained Started name-set,
    and the synthetic/observed completionKind discriminator.
.DESCRIPTION
    The dsc.exe boundary (Invoke-DscNative) is the only thing mocked: the mock drives the REAL
    lifecycle callback with constructed `--progress-format json` lines (so the real Started/InFlight/
    Errored state is built) and returns a constructed native result. Everything downstream
    (New-SetLifecycleCallback, the synthetic drain, Find-DscErrorSignal, the abort computation, the
    resources.jsonl emit) runs for real, so the Aborted/Unreached classification is proven against
    constructed inputs, not faked. The lifecycle callback is a GetNewClosure() closure that does not
    pick up Pester mocks, so the real set-lifecycle rows are written to a throwaway temp log; the
    tests assert only on Invoke-DscSet's return shape, never on the file.

    Abort classification is exercised in all three expected directions:
      (a) Command-variant (in-flight>0): a never-started sibling drives Unreached; exit!=0 -> Aborted.
      (b) failure-then-abort (in-flight==0): an observed-failure culprit + a never-started sibling
          (the shape a bare in-flight count misses); exit!=0 -> Aborted.
      (c) clean convergence (exit 0): a forward-expanded compliant upstream is NOT a drifted seed so
          it can't be Unreached; all seeds started -> Unreached empty, Aborted=false. Plus the
          exit-0 conjunct on its own (Unreached non-empty but exit 0 -> Aborted=false).

    These mocks prove the classification logic independently of a deployment adapter.

    See scripts/dscv3/tests/README.md for the CI invocation contract.
#>

Set-StrictMode -Version Latest

BeforeAll {
    Set-StrictMode -Version Latest

    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ModuleRoot = Join-Path $script:RepoRoot 'src\agent\windows\Modules'
    # Invoke-DscSet's call graph: Invoke-DscNative (mocked dsc boundary), ConvertFrom-DscTestJson +
    # Get-NestedProperty (ResultProjection), New-SetLifecycleCallback + Write-SetLifecycleEvent
    # (Lifecycle), Find-DscErrorSignal (Diagnostics), Get-WrapperInnerTypeMap (ConfigFilter),
    # Write-NativeStderr (HostContext). The real set-lifecycle emit needs New-ResourceRecord +
    # Write-JsonLine (JsonLog) and its reason helpers (Reasons).
    Import-Module (Join-Path $script:ModuleRoot 'Dsc.HostContext.psm1') -Force
    Import-Module (Join-Path $script:ModuleRoot 'Dsc.ResultProjection.psm1') -Force
    Import-Module (Join-Path $script:ModuleRoot 'Dsc.ConfigFilter.psm1') -Force
    Import-Module (Join-Path $script:ModuleRoot 'Dsc.Lifecycle.psm1') -Force
    Import-Module (Join-Path $script:ModuleRoot 'Dsc.Diagnostics.psm1') -Force
    Import-Module (Join-Path $script:ModuleRoot 'Dsc.Reasons.psm1') -Force
    Import-Module (Join-Path $script:ModuleRoot 'Dsc.JsonLog.psm1') -Force
    Import-Module (Join-Path $script:ModuleRoot 'Dsc.Native.psm1') -Force

    # Throwaway log for the real set-lifecycle emit side effect (never asserted on).
    $script:TempLogDir = Join-Path $PSScriptRoot 'TestResults\native-abort-tests'
    if (-not (Test-Path -LiteralPath $script:TempLogDir)) {
        New-Item -ItemType Directory -Path $script:TempLogDir -Force | Out-Null
    }
    $script:ResourcesLog = Join-Path $script:TempLogDir 'resources.jsonl'

    # Constructed `--progress-format json` progress lines (mirror dsc.exe set output).
    function script:New-StartTick {
        param([string]$Name)
        "{`"activity`":`"Set '$Name'`",`"resourceName`":`"$Name`",`"resourceType`":`"Microsoft.DSC/PowerShell`"}"
    }
    function script:New-FailTick {
        param([string]$Name)
        "{`"activity`":`"Set '$Name'`",`"resourceName`":`"$Name`",`"failure`":{`"message`":`"boom`"}}"
    }
    function script:New-CompleteTick {
        param([string]$Name)
        "{`"activity`":`"Set '$Name'`",`"resourceName`":`"$Name`",`"result`":{`"afterState`":{}}}"
    }

    # Drives Invoke-DscSet through the mocked dsc boundary with the standard streaming params on.
    function script:Invoke-SetUnderTest {
        param([string[]]$DriftedSeedNames = @())
        Invoke-DscSet -DscExePath 'C:\fake\dsc.exe' -ConfigFilePath 'C:\fake\set.yaml' `
            -ResourcesLogPath $script:ResourcesLog -ResourcesSchemaVersion 'v1' `
            -RunId 'run1' -HostName 'host1' -Group 'hp1' -Role 'svc' `
            -ConfigVersion 'cv1' -RunTrigger 'scheduled' -FragmentName 'FragX' `
            -DriftedSeedNames $DriftedSeedNames
    }
}

AfterAll {
    if ($null -ne $script:TempLogDir -and (Test-Path -LiteralPath $script:TempLogDir)) {
        Remove-Item -LiteralPath $script:TempLogDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'New-SetLifecycleCallback retained Started name-set' {

    It 'adds a name to Started on its set-start tick and never prunes it, even after InFlight removal' {
        # BufferSink keeps the real emit file-free; we assert on State, not rows.
        $buffer = [System.Collections.Generic.List[object]]::new()
        $lc = New-SetLifecycleCallback -Path $script:ResourcesLog -SchemaVersion 'v1' -RunId 'r' `
            -HostName 'h' -Group '' -Role '' -ConfigVersion 'c' -RunTrigger 'scheduled' `
            -BufferSink $buffer

        & $lc.Callback (script:New-StartTick -Name 'A')
        $lc.State.Started.Contains('A') | Should -BeTrue
        $lc.State.InFlight.ContainsKey('A') | Should -BeTrue

        # An observed failure removes A from InFlight but Started retains it (= reached).
        & $lc.Callback (script:New-FailTick -Name 'A')
        $lc.State.InFlight.ContainsKey('A') | Should -BeFalse
        $lc.State.Started.Contains('A') | Should -BeTrue
    }
}

Describe 'Invoke-DscSet abort signal (Aborted / Unreached)' {

    BeforeEach {
        Mock -ModuleName Dsc.Native Get-WrapperInnerTypeMap { @{} }
        Mock -ModuleName Dsc.Native Write-NativeStderr {}

        Mock -ModuleName Dsc.Native Invoke-DscNative {
            param($DscExePath, $Subcommand, $ConfigFilePath, $OnStderrLine)
            $null = $DscExePath, $Subcommand, $ConfigFilePath   # mock binds dsc boundary; only OnStderrLine is exercised
            foreach ($line in $script:progressLines) {
                if ($null -ne $OnStderrLine) { & $OnStderrLine $line }
            }
            [pscustomobject]@{
                ExitCode = $script:nativeExit
                Stdout   = $script:nativeStdout
                Stderr   = $script:nativeStderr
            }
        }

        $script:progressLines = @()
        $script:nativeExit    = 0
        $script:nativeStdout  = '[]'
        $script:nativeStderr  = @()
    }

    Context 'direction (a): Command-variant abort, in-flight > 0' {

        It 'flags Aborted with the never-started sibling in Unreached and reaches the in-flight culprit' {
            # A starts but never terminates (DscError::Command) -> left in-flight -> synthetic-drained.
            # C (queued after A) never starts -> the fragment died before reaching it.
            $script:progressLines = @((script:New-StartTick -Name 'A'))
            $script:nativeExit    = 2
            $script:nativeStdout  = ''

            $result = script:Invoke-SetUnderTest -DriftedSeedNames @('A', 'C')

            $result.Aborted | Should -BeTrue
            $result.Unreached | Should -Be @('C')
            ($result.Unreached -contains 'A') | Should -BeFalse   # A reached (started) -> not Unreached
        }
    }

    Context 'direction (b): failure-event-then-abort, in-flight == 0' {

        It 'flags Aborted on a never-started sibling even though no resource is left in-flight' {
            # A emits a failure (removed from in-flight) then the fragment dies; sibling C never starts.
            # InFlight.Count == 0 here -- the shape a bare in-flight count would miss.
            $script:progressLines = @((script:New-FailTick -Name 'A'))
            $script:nativeExit    = 2

            $result = script:Invoke-SetUnderTest -DriftedSeedNames @('A', 'C')

            $result.Aborted | Should -BeTrue
            $result.Unreached | Should -Be @('C')
        }
    }

    Context 'direction (c): clean convergence (negative direction)' {

        It 'does not flag a clean exit-0 pass: a forward-expanded compliant upstream is not a seed' {
            # D (the only drifted seed) starts and completes. Compliant upstream B was pulled in by
            # dependsOn expansion and emits no terminal Set event -- but B is NOT a drifted seed, so it
            # cannot land in Unreached. All seeds reached + exit 0 -> Aborted false.
            $script:progressLines = @((script:New-CompleteTick -Name 'D'))
            $script:nativeExit    = 0

            $result = script:Invoke-SetUnderTest -DriftedSeedNames @('D')

            $result.Aborted | Should -BeFalse
            $result.Unreached.Count | Should -Be 0
        }

        It 'exit-0 conjunct alone keeps Aborted false even when a drifted seed is Unreached' {
            # Independent proof of the exit-code conjunct (MAJOR-1): a non-empty Unreached on a clean
            # exit-0, parseable, error-signal-free run is NOT an abort.
            $script:progressLines = @((script:New-CompleteTick -Name 'D'))
            $script:nativeExit    = 0
            $script:nativeStderr  = @()

            $result = script:Invoke-SetUnderTest -DriftedSeedNames @('D', 'E')

            $result.Unreached | Should -Be @('E')
            $result.Aborted | Should -BeFalse
        }
    }

    Context 'defensive defaults' {

        It 'returns Unreached empty and Aborted false when no drifted seeds are supplied' {
            $script:progressLines = @((script:New-StartTick -Name 'A'))
            $script:nativeExit    = 2

            $result = script:Invoke-SetUnderTest

            $result.Unreached.Count | Should -Be 0
            $result.Aborted | Should -BeFalse
        }

        It 'returns Unreached empty and Aborted false when every drifted seed reached a terminal event' {
            $script:progressLines = @((script:New-CompleteTick -Name 'A'), (script:New-CompleteTick -Name 'B'))
            $script:nativeExit    = 0

            $result = script:Invoke-SetUnderTest -DriftedSeedNames @('A', 'B')

            $result.Unreached.Count | Should -Be 0
            $result.Aborted | Should -BeFalse
        }
    }
}

Describe 'Invoke-DscSet Errored completionKind discriminator' {

    BeforeEach {
        Mock -ModuleName Dsc.Native Get-WrapperInnerTypeMap { @{} }
        Mock -ModuleName Dsc.Native Write-NativeStderr {}

        Mock -ModuleName Dsc.Native Invoke-DscNative {
            param($DscExePath, $Subcommand, $ConfigFilePath, $OnStderrLine)
            $null = $DscExePath, $Subcommand, $ConfigFilePath   # mock binds dsc boundary; only OnStderrLine is exercised
            foreach ($line in $script:progressLines) {
                if ($null -ne $OnStderrLine) { & $OnStderrLine $line }
            }
            [pscustomobject]@{
                ExitCode = $script:nativeExit
                Stdout   = $script:nativeStdout
                Stderr   = $script:nativeStderr
            }
        }

        $script:progressLines = @()
        $script:nativeExit    = 0
        $script:nativeStdout  = ''
        $script:nativeStderr  = @()
    }

    It "tags a synthetic-drain Errored entry completionKind='synthetic'" {
        $script:progressLines = @((script:New-StartTick -Name 'A'))
        $script:nativeExit    = 2

        $result = script:Invoke-SetUnderTest -DriftedSeedNames @('A')

        $entry = @($result.Errored | Where-Object { $_.name -eq 'A' })[0]
        $entry | Should -Not -BeNullOrEmpty
        $entry.completionKind | Should -Be 'synthetic'
    }

    It "tags an observed-failure Errored entry completionKind='observed'" {
        $script:progressLines = @((script:New-FailTick -Name 'A'))
        $script:nativeExit    = 2

        $result = script:Invoke-SetUnderTest -DriftedSeedNames @('A')

        $entry = @($result.Errored | Where-Object { $_.name -eq 'A' })[0]
        $entry | Should -Not -BeNullOrEmpty
        $entry.completionKind | Should -Be 'observed'
    }
}
