#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pester v5 unit suite for Dsc.Recovery.psm1 — the strip-and-retry recovery loop.
.DESCRIPTION
    Covers Invoke-FragmentConvergence:
      - happy-path parity (a clean pass-1 test is a single invocation, no recovery cost),
      - each bail guard (max_passes, unattributable, no_shrink) returning Recovered=$false
        with the right BailReason and the last failed invocation,
      - the additive convergence return shape (Phase/FinalTest/FinalVerify/SetErrored/Outcome)
        and the dormant -SetInvoker/-VerifyInvoker plumbing that is not yet invoked,
      - characterization tests that pin current hazards: the set-abort gap (set aborts -> drifted
        remainder lost) and resources.jsonl per-pass row duplication.

    The dsc-test boundary is injected via the -TestInvoker parameter (no real dsc.exe).
    The two cross-module seams the loop calls (Find-DscErrorSignal in Dsc.Diagnostics,
    New-StrippedConfigExcludingResources in Dsc.ConfigFilter) plus Write-NativeStderr are
    mocked into the Dsc.Recovery module scope.

    See scripts/dscv3/tests/README.md for the CI invocation contract.
#>

Set-StrictMode -Version Latest

BeforeAll {
    Set-StrictMode -Version Latest

    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ModuleRoot = Join-Path $script:RepoRoot 'src\agent\windows\Modules'
    # Recovery's call graph: TestInvoker (injected), Find-DscErrorSignal (Diagnostics),
    # New-StrippedConfigExcludingResources (ConfigFilter), Write-NativeStderr (HostContext).
    Import-Module (Join-Path $script:ModuleRoot 'Dsc.HostContext.psm1') -Force
    Import-Module (Join-Path $script:ModuleRoot 'Dsc.ResultProjection.psm1') -Force
    Import-Module (Join-Path $script:ModuleRoot 'Dsc.ConfigFilter.psm1') -Force
    Import-Module (Join-Path $script:ModuleRoot 'Dsc.Diagnostics.psm1') -Force
    # Reasons + JsonLog back the real resources.jsonl emit driven by the row-duplication test.
    Import-Module (Join-Path $script:ModuleRoot 'Dsc.Reasons.psm1') -Force
    Import-Module (Join-Path $script:ModuleRoot 'Dsc.JsonLog.psm1') -Force
    Import-Module (Join-Path $script:ModuleRoot 'Dsc.Recovery.psm1') -Force

    $script:DscExe = 'C:\fake\dsc.exe'
    $script:ConfigPath = 'C:\fake\fragment.dsc.yaml'

    # Builds a TestInvoker-shaped invocation object (matches Invoke-DscTestJson output).
    function script:New-Invocation {
        param(
            [Parameter(Mandatory)][int]$ExitCode,
            [Parameter(Mandatory)][bool]$HadErrors,
            [string[]]$Stderr = @()
        )
        [pscustomobject]@{
            Native  = [pscustomobject]@{ ExitCode = $ExitCode; Stderr = $Stderr }
            Parsed  = [pscustomobject]@{ HadErrors = $HadErrors; Results = @(); Duration = 'PT0S' }
            Timings = @()
        }
    }
}

Describe 'Invoke-FragmentConvergence (happy path + bail guards)' {

    BeforeEach {
        # Recovery writes "[recovery] ..." forensics to native stderr; silence it.
        Mock -ModuleName Dsc.Recovery Write-NativeStderr {}
        $script:invokeCount = 0
    }

    Context 'happy-path parity (clean pass-1 test)' {

        It 'returns after exactly one test invocation with no recovery work' {
            Mock -ModuleName Dsc.Recovery Find-DscErrorSignal {
                [pscustomobject]@{ Excerpt = ''; Tag = ''; ResourceName = ''; ResourceType = '' }
            }
            Mock -ModuleName Dsc.Recovery New-StrippedConfigExcludingResources {
                param([string[]]$ExcludeResourceNames)
                [pscustomobject]@{ Path = 'x'; ExcludedNames = @($ExcludeResourceNames); KeptNames = @() }
            }

            $invoker = {
                param($DscExePath, $ConfigFilePath)
                $script:invokeCount++
                New-Invocation -ExitCode 0 -HadErrors $false -Stderr @("config=$ConfigFilePath", "exe=$DscExePath")
            }

            $r = Invoke-FragmentConvergence -DscExePath $script:DscExe -ConfigFilePath $script:ConfigPath -TestInvoker $invoker

            $script:invokeCount | Should -Be 1
            $r.PassCount | Should -Be 1
            $r.Recovered | Should -BeFalse
            $r.BailReason | Should -Be ''
            $r.EffectiveConfigPath | Should -Be $script:ConfigPath
            $r.EffectiveConfigIsTemp | Should -BeFalse
            @($r.QuarantinedResources).Count | Should -Be 0
            @($r.Culprits).Count | Should -Be 0
            $r.TestInvocation.Native.ExitCode | Should -Be 0

            # No failure path => no signal extraction, no strip.
            Should -Invoke -ModuleName Dsc.Recovery Find-DscErrorSignal -Times 0 -Exactly
            Should -Invoke -ModuleName Dsc.Recovery New-StrippedConfigExcludingResources -Times 0 -Exactly
        }
    }

    Context 'recovery success path' {

        It 'recovers (Recovered=$true) when an attributable culprit is stripped on pass 1 and pass 2 tests clean' {
            # Pass 1 names WrapperA as the culprit; the strip keeps a non-empty survivor set;
            # pass 2 (the stripped subset) tests clean -> recovered.
            Mock -ModuleName Dsc.Recovery Find-DscErrorSignal {
                [pscustomobject]@{ Excerpt = 'value-type abort'; Tag = '[json_extracted]'; ResourceName = 'WrapperA'; ResourceType = 'Microsoft.DSC/PowerShell' }
            }
            Mock -ModuleName Dsc.Recovery New-StrippedConfigExcludingResources {
                param([string[]]$ExcludeResourceNames)
                [pscustomobject]@{
                    Path          = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ('dsc-recovery-test-' + [guid]::NewGuid().ToString('N') + '.yaml'))
                    ExcludedNames = @($ExcludeResourceNames)
                    KeptNames     = @('Survivor')
                }
            }

            $invoker = {
                param($DscExePath, $ConfigFilePath)
                $null = $DscExePath
                $script:invokeCount++
                if ($script:invokeCount -eq 1) {
                    # Pass 1: attributable failure (WrapperA) against the original config.
                    New-Invocation -ExitCode 1 -HadErrors $true -Stderr @("config=$ConfigFilePath", 'CULPRIT=WrapperA')
                } else {
                    # Pass 2: the stripped subset tests clean.
                    New-Invocation -ExitCode 0 -HadErrors $false -Stderr @("config=$ConfigFilePath")
                }
            }

            $r = Invoke-FragmentConvergence -DscExePath $script:DscExe -ConfigFilePath $script:ConfigPath -TestInvoker $invoker

            $script:invokeCount | Should -Be 2
            $r.PassCount | Should -Be 2
            $r.Recovered | Should -BeTrue
            $r.BailReason | Should -Be ''
            @($r.QuarantinedResources) | Should -Contain 'WrapperA'
            @($r.Culprits) | Should -Be @('WrapperA')
            @($r.CulpritDetails).Count | Should -Be 1
            @($r.CulpritDetails)[0].Name | Should -Be 'WrapperA'
            @($r.CulpritDetails)[0].Phase | Should -Be 'test'   # stripped at the test phase
            # Pass 2 ran against the stripped temp; the effective-config flag flips to temp.
            $r.EffectiveConfigIsTemp | Should -BeTrue
            $r.EffectiveConfigPath | Should -Not -Be $script:ConfigPath
            $r.EffectiveConfigPath | Should -BeLike (Join-Path ([System.IO.Path]::GetTempPath()) 'dsc-recovery-test-*.yaml')
            # The clean pass-2 invocation is the one returned to the caller.
            $r.TestInvocation.Native.ExitCode | Should -Be 0
            # Exactly one strip happened (pass 1); pass 2 returned clean before any further strip.
            Should -Invoke -ModuleName Dsc.Recovery New-StrippedConfigExcludingResources -Times 1 -Exactly
        }
    }

    Context 'bail guards' {

        It 'bails unattributable (empty culprit) on pass 1 without stripping' {
            Mock -ModuleName Dsc.Recovery Find-DscErrorSignal {
                [pscustomobject]@{ Excerpt = 'parse error'; Tag = '[fallback_excerpt]'; ResourceName = ''; ResourceType = '' }
            }
            Mock -ModuleName Dsc.Recovery New-StrippedConfigExcludingResources {
                param([string[]]$ExcludeResourceNames)
                [pscustomobject]@{ Path = 'x'; ExcludedNames = @($ExcludeResourceNames); KeptNames = @() }
            }

            $invoker = {
                param($DscExePath, $ConfigFilePath)
                $script:invokeCount++
                New-Invocation -ExitCode 2 -HadErrors $true -Stderr @("config=$ConfigFilePath", "exe=$DscExePath", 'no activity event')
            }

            $r = Invoke-FragmentConvergence -DscExePath $script:DscExe -ConfigFilePath $script:ConfigPath -TestInvoker $invoker

            $script:invokeCount | Should -Be 1
            $r.PassCount | Should -Be 1
            $r.Recovered | Should -BeFalse
            $r.BailReason | Should -Be 'unattributable'
            # Last failed invocation is returned for the caller's standard telemetry path.
            $r.TestInvocation.Native.ExitCode | Should -Be 2
            @($r.QuarantinedResources).Count | Should -Be 0
            Should -Invoke -ModuleName Dsc.Recovery New-StrippedConfigExcludingResources -Times 0 -Exactly
        }

        It 'bails no_shrink when the same culprit fails again after being stripped' {
            # Signal names the same culprit every pass.
            Mock -ModuleName Dsc.Recovery Find-DscErrorSignal {
                [pscustomobject]@{ Excerpt = 'value-type abort'; Tag = '[json_extracted]'; ResourceName = 'WrapperA'; ResourceType = 'Microsoft.DSC/PowerShell' }
            }
            Mock -ModuleName Dsc.Recovery New-StrippedConfigExcludingResources {
                param([string[]]$ExcludeResourceNames)
                [pscustomobject]@{
                    Path          = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ('dsc-recovery-test-' + [guid]::NewGuid().ToString('N') + '.yaml'))
                    ExcludedNames = @($ExcludeResourceNames)
                    KeptNames     = @('Survivor')
                }
            }

            $invoker = {
                param($DscExePath, $ConfigFilePath)
                $script:invokeCount++
                New-Invocation -ExitCode 1 -HadErrors $true -Stderr @("config=$ConfigFilePath", "exe=$DscExePath", 'CULPRIT=WrapperA')
            }

            $r = Invoke-FragmentConvergence -DscExePath $script:DscExe -ConfigFilePath $script:ConfigPath -TestInvoker $invoker

            $script:invokeCount | Should -Be 2
            $r.PassCount | Should -Be 2
            $r.Recovered | Should -BeFalse
            $r.BailReason | Should -Be 'no_shrink'
            $r.TestInvocation.Native.ExitCode | Should -Be 1
            @($r.Culprits) | Should -Be @('WrapperA')
            @($r.QuarantinedResources) | Should -Contain 'WrapperA'
            # Stripped once on pass 1; pass 2 bails before stripping.
            Should -Invoke -ModuleName Dsc.Recovery New-StrippedConfigExcludingResources -Times 1 -Exactly
        }

        It 'bails max_passes when the failing set keeps shrinking past the cap' {
            # Distinct culprit per pass so the failing set shrinks (avoids no_shrink) until the cap.
            $script:culpritSequence = @('WrapperA', 'WrapperB', 'WrapperC', 'WrapperD')
            Mock -ModuleName Dsc.Recovery Find-DscErrorSignal {
                param([string[]]$Stderr)
                $name = ''
                foreach ($line in @($Stderr)) { if ($line -match '^CULPRIT=(?<n>.*)$') { $name = $Matches['n'] } }
                [pscustomobject]@{ Excerpt = "abort on $name"; Tag = '[json_extracted]'; ResourceName = $name; ResourceType = 'Microsoft.DSC/PowerShell' }
            }
            Mock -ModuleName Dsc.Recovery New-StrippedConfigExcludingResources {
                param([string[]]$ExcludeResourceNames)
                [pscustomobject]@{
                    Path          = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ('dsc-recovery-test-' + [guid]::NewGuid().ToString('N') + '.yaml'))
                    ExcludedNames = @($ExcludeResourceNames)
                    KeptNames     = @('Survivor')
                }
            }

            $invoker = {
                param($DscExePath, $ConfigFilePath)
                $name = $script:culpritSequence[$script:invokeCount]
                $script:invokeCount++
                New-Invocation -ExitCode 1 -HadErrors $true -Stderr @("config=$ConfigFilePath", "exe=$DscExePath", "CULPRIT=$name")
            }

            $r = Invoke-FragmentConvergence -DscExePath $script:DscExe -ConfigFilePath $script:ConfigPath -TestInvoker $invoker -MaxPasses 3

            $script:invokeCount | Should -Be 3
            $r.PassCount | Should -Be 3
            $r.Recovered | Should -BeFalse
            $r.BailReason | Should -Be 'max_passes'
            # Last failed invocation (pass 3, the capped culprit) is returned.
            $r.TestInvocation.Native.Stderr | Should -Contain 'CULPRIT=WrapperC'
            # A and B were stripped on passes 1 and 2; C is captured for telemetry but not stripped.
            @($r.Culprits) | Should -Be @('WrapperA', 'WrapperB')
            @($r.CulpritDetails).Count | Should -Be 3
            @($r.QuarantinedResources) | Should -Be @('WrapperA', 'WrapperB')
            Should -Invoke -ModuleName Dsc.Recovery New-StrippedConfigExcludingResources -Times 2 -Exactly
        }

        It 'bails fully_stripped when the strip reports the culprit closure leaves no resources' {
            # Attributable culprit on pass 1, but stripping it (+ closure) would empty the config:
            # New-StrippedConfigExcludingResources throws with the "leaves no resources" message the
            # module keys on -> bail reason fully_stripped (no second pass).
            Mock -ModuleName Dsc.Recovery Find-DscErrorSignal {
                [pscustomobject]@{ Excerpt = 'value-type abort'; Tag = '[json_extracted]'; ResourceName = 'WrapperA'; ResourceType = 'Microsoft.DSC/PowerShell' }
            }
            Mock -ModuleName Dsc.Recovery New-StrippedConfigExcludingResources {
                throw "excluding wrapper 'WrapperA' and its reverse-dependsOn closure leaves no resources in the config."
            }

            $invoker = {
                param($DscExePath, $ConfigFilePath)
                $null = $DscExePath
                $script:invokeCount++
                New-Invocation -ExitCode 1 -HadErrors $true -Stderr @("config=$ConfigFilePath", 'CULPRIT=WrapperA')
            }

            $r = Invoke-FragmentConvergence -DscExePath $script:DscExe -ConfigFilePath $script:ConfigPath -TestInvoker $invoker

            $script:invokeCount | Should -Be 1
            $r.PassCount | Should -Be 1
            $r.Recovered | Should -BeFalse
            $r.BailReason | Should -Be 'fully_stripped'
            $r.TestInvocation.Native.ExitCode | Should -Be 1
            # Strip threw before the culprit/quarantine sets were mutated.
            @($r.QuarantinedResources).Count | Should -Be 0
            @($r.Culprits).Count | Should -Be 0
            Should -Invoke -ModuleName Dsc.Recovery New-StrippedConfigExcludingResources -Times 1 -Exactly
        }

        It 'bails strip_failed when the strip throws an unrelated exception' {
            # Attributable culprit on pass 1, but the strip throws an error that does NOT match the
            # "leaves no resources" pattern -> bail reason strip_failed (defensive fall-through).
            Mock -ModuleName Dsc.Recovery Find-DscErrorSignal {
                [pscustomobject]@{ Excerpt = 'value-type abort'; Tag = '[json_extracted]'; ResourceName = 'WrapperA'; ResourceType = 'Microsoft.DSC/PowerShell' }
            }
            Mock -ModuleName Dsc.Recovery New-StrippedConfigExcludingResources {
                throw 'unexpected I/O error while writing the stripped config to a temp file'
            }

            $invoker = {
                param($DscExePath, $ConfigFilePath)
                $null = $DscExePath
                $script:invokeCount++
                New-Invocation -ExitCode 1 -HadErrors $true -Stderr @("config=$ConfigFilePath", 'CULPRIT=WrapperA')
            }

            $r = Invoke-FragmentConvergence -DscExePath $script:DscExe -ConfigFilePath $script:ConfigPath -TestInvoker $invoker

            $script:invokeCount | Should -Be 1
            $r.PassCount | Should -Be 1
            $r.Recovered | Should -BeFalse
            $r.BailReason | Should -Be 'strip_failed'
            $r.TestInvocation.Native.ExitCode | Should -Be 1
            @($r.QuarantinedResources).Count | Should -Be 0
            @($r.Culprits).Count | Should -Be 0
            Should -Invoke -ModuleName Dsc.Recovery New-StrippedConfigExcludingResources -Times 1 -Exactly
        }
    }
}

Describe 'Invoke-FragmentConvergence plumbing' {

    BeforeEach {
        Mock -ModuleName Dsc.Recovery Write-NativeStderr {}
        $script:invokeCount = 0
        $script:setCalls    = 0
        $script:verifyCalls = 0
    }

    Context 'extended return shape (additive — existing fields preserved)' {

        It 'a clean pass-1 test returns Outcome=converged with the new fields populated' {
            Mock -ModuleName Dsc.Recovery Find-DscErrorSignal {
                [pscustomobject]@{ Excerpt = ''; Tag = ''; ResourceName = ''; ResourceType = '' }
            }

            $invoker = {
                param($DscExePath, $ConfigFilePath)
                $null = $DscExePath, $ConfigFilePath
                $script:invokeCount++
                New-Invocation -ExitCode 0 -HadErrors $false -Stderr @("config=$ConfigFilePath")
            }

            $r = Invoke-FragmentConvergence -DscExePath $script:DscExe -ConfigFilePath $script:ConfigPath -TestInvoker $invoker

            $r.Outcome     | Should -Be 'converged'
            $r.Phase       | Should -Be 'test'
            $r.FinalVerify | Should -BeNullOrEmpty
            @($r.SetErrored).Count | Should -Be 0
            # FinalTest is the returning test invocation (same object the caller reads as TestInvocation).
            $r.FinalTest | Should -Be $r.TestInvocation
            $r.FinalTest.Native.ExitCode | Should -Be 0
        }

        It 'an unattributable bail returns Outcome=bail with the new fields populated' {
            Mock -ModuleName Dsc.Recovery Find-DscErrorSignal {
                [pscustomobject]@{ Excerpt = 'parse error'; Tag = '[fallback_excerpt]'; ResourceName = ''; ResourceType = '' }
            }

            $invoker = {
                param($DscExePath, $ConfigFilePath)
                $null = $DscExePath, $ConfigFilePath
                $script:invokeCount++
                New-Invocation -ExitCode 2 -HadErrors $true -Stderr @("config=$ConfigFilePath", 'no activity event')
            }

            $r = Invoke-FragmentConvergence -DscExePath $script:DscExe -ConfigFilePath $script:ConfigPath -TestInvoker $invoker

            $r.Outcome     | Should -Be 'bail'
            $r.BailReason  | Should -Be 'unattributable'
            $r.Phase       | Should -Be 'test'
            $r.FinalVerify | Should -BeNullOrEmpty
            @($r.SetErrored).Count | Should -Be 0
            # On a bail FinalTest is the last failed invocation (what the caller's telemetry path reads).
            $r.FinalTest | Should -Be $r.TestInvocation
            $r.FinalTest.Native.ExitCode | Should -Be 2
        }
    }

    Context 'dormant set/verify invokers (test-only loop, not yet wired)' {

        It 'never invokes -SetInvoker or -VerifyInvoker on a converged run' {
            Mock -ModuleName Dsc.Recovery Find-DscErrorSignal {
                [pscustomobject]@{ Excerpt = ''; Tag = ''; ResourceName = ''; ResourceType = '' }
            }
            $testInvoker = {
                param($DscExePath, $ConfigFilePath)
                $null = $DscExePath, $ConfigFilePath
                $script:invokeCount++
                New-Invocation -ExitCode 0 -HadErrors $false
            }
            $setSpy    = { param($DscExePath, $ConfigFilePath) $null = $DscExePath, $ConfigFilePath; $script:setCalls++;    New-Invocation -ExitCode 0 -HadErrors $false }
            $verifySpy = { param($DscExePath, $ConfigFilePath) $null = $DscExePath, $ConfigFilePath; $script:verifyCalls++; New-Invocation -ExitCode 0 -HadErrors $false }

            $r = Invoke-FragmentConvergence -DscExePath $script:DscExe -ConfigFilePath $script:ConfigPath `
                -TestInvoker $testInvoker -SetInvoker $setSpy -VerifyInvoker $verifySpy

            $r.Outcome | Should -Be 'converged'
            $script:invokeCount | Should -Be 1
            $script:setCalls    | Should -Be 0
            $script:verifyCalls | Should -Be 0
        }

        It 'never invokes -SetInvoker or -VerifyInvoker on a bail run' {
            Mock -ModuleName Dsc.Recovery Find-DscErrorSignal {
                [pscustomobject]@{ Excerpt = 'parse error'; Tag = '[fallback_excerpt]'; ResourceName = ''; ResourceType = '' }
            }
            $testInvoker = {
                param($DscExePath, $ConfigFilePath)
                $null = $DscExePath, $ConfigFilePath
                $script:invokeCount++
                New-Invocation -ExitCode 2 -HadErrors $true
            }
            $setSpy    = { param($DscExePath, $ConfigFilePath) $null = $DscExePath, $ConfigFilePath; $script:setCalls++;    New-Invocation -ExitCode 0 -HadErrors $false }
            $verifySpy = { param($DscExePath, $ConfigFilePath) $null = $DscExePath, $ConfigFilePath; $script:verifyCalls++; New-Invocation -ExitCode 0 -HadErrors $false }

            $r = Invoke-FragmentConvergence -DscExePath $script:DscExe -ConfigFilePath $script:ConfigPath `
                -TestInvoker $testInvoker -SetInvoker $setSpy -VerifyInvoker $verifySpy

            $r.Outcome | Should -Be 'bail'
            $script:setCalls    | Should -Be 0
            $script:verifyCalls | Should -Be 0
        }
    }
}

Describe 'Recovery edge-case characterization (pins current hazards)' {

    BeforeEach {
        Mock -ModuleName Dsc.Recovery Write-NativeStderr {}
        $script:invokeCount = 0
    }

    Context 'set-abort gap (set aborts -> drifted remainder lost today)' {

        # Models today's post-recovery linear flow (Invoke-Enforcement.ps1 ~L862-934): recovery
        # handles TEST only; the caller runs set/verify once. A set abort ($parsedSet -eq $null)
        # skips verify and `continue`s, so the drifted siblings get no remediation and recovery
        # never re-enters — the #656 set-abort gap.
        function script:Invoke-TodayLinearFlow {
            param([scriptblock]$SetInvoker, [string[]]$DriftedSiblings)
            $set = & $SetInvoker
            if ($null -eq $set.Parsed) {
                return [pscustomobject]@{ VerifyRan = $false; LostSiblings = @($DriftedSiblings) }
            }
            return [pscustomobject]@{ VerifyRan = $true; LostSiblings = @() }
        }

        It 'today: a clean test then an aborting set drops the drifted remainder (no strip, no restart)' {
            Mock -ModuleName Dsc.Recovery Find-DscErrorSignal {
                [pscustomobject]@{ Excerpt = ''; Tag = ''; ResourceName = ''; ResourceType = '' }
            }
            Mock -ModuleName Dsc.Recovery New-StrippedConfigExcludingResources {
                param([string[]]$ExcludeResourceNames)
                [pscustomobject]@{ Path = 'x'; ExcludedNames = @($ExcludeResourceNames); KeptNames = @() }
            }

            # TEST is clean: a culprit whose Set throws is invisible to test-phase recovery, so the
            # module converges with no strip and an unchanged effective config.
            $testInvoker = {
                param($DscExePath, $ConfigFilePath)
                $null = $DscExePath, $ConfigFilePath
                $script:invokeCount++
                New-Invocation -ExitCode 0 -HadErrors $false -Stderr @("config=$ConfigFilePath")
            }
            $r = Invoke-FragmentConvergence -DscExePath $script:DscExe -ConfigFilePath $script:ConfigPath -TestInvoker $testInvoker

            $r.Outcome   | Should -Be 'converged'
            $r.Recovered | Should -BeFalse
            $r.Phase     | Should -Be 'test'
            @($r.QuarantinedResources).Count | Should -Be 0
            $r.EffectiveConfigPath | Should -Be $script:ConfigPath

            # SET aborts (unparseable output): today's caller skips verify and loses the siblings.
            $setAbort = { [pscustomobject]@{ Native = [pscustomobject]@{ ExitCode = 1 }; Parsed = $null } }
            $flow = Invoke-TodayLinearFlow -SetInvoker $setAbort -DriftedSiblings @('SiblingA', 'SiblingB')

            # CHARACTERIZATION — asserts today's imperfect reality as-true so the gate stays green.
            # TODO: invert — a strippable set abort strips the culprit and restarts
            # at test, so LostSiblings becomes empty and the siblings re-enforce.
            $flow.VerifyRan | Should -BeFalse
            @($flow.LostSiblings) | Should -Be @('SiblingA', 'SiblingB')

            # Recovery never stripped: the set-phase culprit is invisible to the test-only loop.
            Should -Invoke -ModuleName Dsc.Recovery New-StrippedConfigExcludingResources -Times 0 -Exactly
        }
    }

    Context 'resources.jsonl per-pass row duplication (low-level primitive is append-only)' {

        It 'Write-ResourceRecords is append-only: emitting the same test results twice accumulates duplicate (resource_name, phase) rows' {
            # Pins the low-level Write-ResourceRecords primitive as append-only: it has no cross-call
            # dedup, so two emits of the same results yield duplicate rows. This remains TRUE:
            # the refactor did not change the primitive; it moved single-emit
            # responsibility to the CALLER. The caller-level guarantee (one (resource_name, phase,
            # event) tuple per inner even across passes) is proven in Dsc.Reconciliation.Tests.ps1.
            # Assertion is against the WRITTEN FILE.
            $entries = @(
                [pscustomobject]@{ name = 'ResourceA'; type = 'Test/Simple'; result = [pscustomobject]@{ inDesiredState = $false; differingProperties = @('Prop1') } }
                [pscustomobject]@{ name = 'ResourceB'; type = 'Test/Simple'; result = [pscustomobject]@{ inDesiredState = $false; differingProperties = @('Prop2') } }
            )
            $parsed = [pscustomobject]@{ HadErrors = $false; Results = $entries; Duration = 'PT0S' }
            $actionMap = New-ResourceActionMap -InitialTest $parsed

            $logPath = Join-Path $TestDrive ('resources-{0}.jsonl' -f [guid]::NewGuid().ToString('N'))

            $emit = {
                Write-ResourceRecords -ParsedTest $parsed -ActionMap $actionMap -Phase 'test' -Trigger 'scheduled' `
                    -Path $logPath -SchemaVersion '3.0' -RunId 'run-1' -Timestamp '2026-06-15T00:00:00.000Z' `
                    -ConfigVersion 'v1' -Group 'hp' -Role 'svc' -FragmentName 'Frag'
            }
            & $emit   # pass 1
            & $emit   # pass 2 (today: appends, does not dedup)

            $rows = @(Get-Content -LiteralPath $logPath | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })

            # PRIMITIVE CHARACTERIZATION -- append-only is the intended low-level contract.
            # The refactor moved the single-emit guarantee to the caller, where it is proven in
            # Dsc.Reconciliation.Tests.ps1 ('two-pass convergence emits only the final pass'); this
            # test stays green to pin that the primitive itself must never silently dedup.
            $rows.Count | Should -Be 4
            $byKey = $rows | Group-Object { '{0}|{1}' -f $_.resource_name, $_.phase }
            @($byKey).Count | Should -Be 2
            foreach ($g in $byKey) { $g.Count | Should -Be 2 }
        }
    }
}

Describe 'Convergence loop (test -> set -> verify)' {

    BeforeAll {
        Set-StrictMode -Version Latest

        # Real Get-DriftedTopLevelResourceNames drives drift off crafted Results (inDesiredState),
        # so the loop's drift gating + the closures are exercised without a stateful mock.
        function script:New-Inv {
            param(
                [int]$ExitCode = 0,
                [bool]$HadErrors = $false,
                [string[]]$Stderr = @(),
                # @{ Name = '<wrapper>'; InDesiredState = $bool } per top-level result entry.
                [object[]]$Resources = @()
            )
            $results = @(foreach ($res in $Resources) {
                [pscustomobject]@{ name = $res.Name; type = 'Test/Simple'; result = [pscustomobject]@{ inDesiredState = [bool]$res.InDesiredState } }
            })
            [pscustomobject]@{
                Native  = [pscustomobject]@{ ExitCode = $ExitCode; Stderr = @($Stderr) }
                Parsed  = [pscustomobject]@{ HadErrors = $HadErrors; Results = $results; Duration = 'PT0S' }
                Timings = @()
            }
        }

        # SET-invoker return shape (matches Invoke-DscSet): the loop reads Aborted/Errored/BufferedRows.
        function script:New-Set {
            param(
                [bool]$Aborted = $false,
                [object[]]$Errored = @(),
                [object[]]$BufferedRows = @(),
                [int]$ExitCode = 0,
                [string[]]$Stderr = @()
            )
            [pscustomobject]@{
                Native       = [pscustomobject]@{ ExitCode = $ExitCode; Stderr = @($Stderr) }
                Parsed       = [pscustomobject]@{ HadErrors = $false; Results = @(); Duration = 'PT0S' }
                Errored      = @($Errored)
                Aborted      = $Aborted
                Unreached    = @()
                BufferedRows = @($BufferedRows)
            }
        }

        # Parses CULPRIT=<name> from an invocation's stderr; no CULPRIT line -> empty (unattributable).
        $script:FindByStderr = {
            param([string[]]$Stderr)
            $name = ''
            foreach ($line in @($Stderr)) { if ($line -match '^CULPRIT=(?<n>.*)$') { $name = $Matches['n'] } }
            [pscustomobject]@{ Excerpt = "abort on $name"; Tag = '[json_extracted]'; ResourceName = $name; ResourceType = 'Microsoft.DSC/PowerShell' }
        }
        # Strip succeeds, excluding the named culprit and keeping a non-empty survivor set.
        $script:StripKeepSurvivor = {
            param([string[]]$ExcludeResourceNames)
            [pscustomobject]@{
                Path          = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ('dsc-loop-test-' + [guid]::NewGuid().ToString('N') + '.yaml'))
                ExcludedNames = @($ExcludeResourceNames)
                KeptNames     = @('Survivor')
            }
        }

        # Always-clean test that reports a single drifted wrapper, so the loop proceeds to SET.
        $script:CleanDriftTest = {
            param($DscExePath, $ConfigFilePath)
            $null = $DscExePath, $ConfigFilePath
            $script:invokeCount++
            New-Inv -ExitCode 0 -HadErrors $false -Resources @(@{ Name = 'X'; InDesiredState = $false })
        }
        # Clean set / clean verify (verify reports the wrapper now compliant -> converged).
        $script:CleanSet    = { param($DscExePath, $ConfigFilePath, $ParsedTest) $null = $DscExePath, $ConfigFilePath, $ParsedTest; $script:setCalls++;    New-Set }
        $script:CleanVerify = { param($DscExePath, $ConfigFilePath) $null = $DscExePath, $ConfigFilePath; $script:verifyCalls++; New-Inv -ExitCode 0 -HadErrors $false -Resources @(@{ Name = 'X'; InDesiredState = $true }) }
    }

    BeforeEach {
        Mock -ModuleName Dsc.Recovery Write-NativeStderr {}
        $script:invokeCount = 0
        $script:setCalls    = 0
        $script:verifyCalls = 0
    }

    Context 'per-phase strip + restart, then survivors converge' {

        It 'a TEST abort strips the culprit, restarts at test, and the survivors remediate' {
            Mock -ModuleName Dsc.Recovery Find-DscErrorSignal $script:FindByStderr
            Mock -ModuleName Dsc.Recovery New-StrippedConfigExcludingResources $script:StripKeepSurvivor

            $testInvoker = {
                param($DscExePath, $ConfigFilePath)
                $null = $DscExePath
                $script:invokeCount++
                if ($script:invokeCount -eq 1) {
                    New-Inv -ExitCode 1 -HadErrors $true -Stderr @("config=$ConfigFilePath", 'CULPRIT=WrapperA')
                } else {
                    New-Inv -ExitCode 0 -HadErrors $false -Resources @(@{ Name = 'X'; InDesiredState = $false })
                }
            }

            $r = Invoke-FragmentConvergence -DscExePath $script:DscExe -ConfigFilePath $script:ConfigPath `
                -TestInvoker $testInvoker -SetInvoker $script:CleanSet -VerifyInvoker $script:CleanVerify

            $r.Outcome   | Should -Be 'converged'
            $r.Phase     | Should -Be 'verify'
            $r.Recovered | Should -BeTrue
            @($r.Culprits) | Should -Be @('WrapperA')
            $script:invokeCount | Should -Be 2
            $script:setCalls    | Should -Be 1
            $script:verifyCalls | Should -Be 1
            Should -Invoke -ModuleName Dsc.Recovery New-StrippedConfigExcludingResources -Times 1 -Exactly
        }

        It 'a SET abort strips the culprit, restarts at test, and the survivors remediate' {
            Mock -ModuleName Dsc.Recovery Find-DscErrorSignal $script:FindByStderr
            Mock -ModuleName Dsc.Recovery New-StrippedConfigExcludingResources $script:StripKeepSurvivor

            $setInvoker = {
                param($DscExePath, $ConfigFilePath, $ParsedTest)
                $null = $DscExePath, $ConfigFilePath, $ParsedTest
                $script:setCalls++
                if ($script:setCalls -eq 1) { New-Set -Aborted $true -ExitCode 1 -Stderr @('CULPRIT=WrapperC') } else { New-Set }
            }

            $r = Invoke-FragmentConvergence -DscExePath $script:DscExe -ConfigFilePath $script:ConfigPath `
                -TestInvoker $script:CleanDriftTest -SetInvoker $setInvoker -VerifyInvoker $script:CleanVerify

            $r.Outcome   | Should -Be 'converged'
            $r.Phase     | Should -Be 'verify'
            $r.Recovered | Should -BeTrue
            @($r.Culprits) | Should -Be @('WrapperC')
            $script:invokeCount | Should -Be 2
            $script:setCalls    | Should -Be 2
            $script:verifyCalls | Should -Be 1
            Should -Invoke -ModuleName Dsc.Recovery New-StrippedConfigExcludingResources -Times 1 -Exactly
        }

        It 'a VERIFY abort strips the culprit, restarts at test, and the survivors remediate' {
            Mock -ModuleName Dsc.Recovery Find-DscErrorSignal $script:FindByStderr
            Mock -ModuleName Dsc.Recovery New-StrippedConfigExcludingResources $script:StripKeepSurvivor

            $verifyInvoker = {
                param($DscExePath, $ConfigFilePath)
                $null = $DscExePath, $ConfigFilePath
                $script:verifyCalls++
                if ($script:verifyCalls -eq 1) {
                    New-Inv -ExitCode 1 -HadErrors $true -Stderr @('CULPRIT=WrapperV')
                } else {
                    New-Inv -ExitCode 0 -HadErrors $false -Resources @(@{ Name = 'X'; InDesiredState = $true })
                }
            }

            $r = Invoke-FragmentConvergence -DscExePath $script:DscExe -ConfigFilePath $script:ConfigPath `
                -TestInvoker $script:CleanDriftTest -SetInvoker $script:CleanSet -VerifyInvoker $verifyInvoker

            $r.Outcome   | Should -Be 'converged'
            $r.Phase     | Should -Be 'verify'
            $r.Recovered | Should -BeTrue
            @($r.Culprits) | Should -Be @('WrapperV')
            $script:invokeCount | Should -Be 2
            $script:setCalls    | Should -Be 2
            $script:verifyCalls | Should -Be 2
            Should -Invoke -ModuleName Dsc.Recovery New-StrippedConfigExcludingResources -Times 1 -Exactly
        }
    }

    Context 'every bail guard is reachable from a set-phase and a verify-phase abort' {

        # Builds the three invokers so the abort lands at $Ph; the other phases run clean.
        function script:Get-AbortInvokers {
            param([string]$Ph, [scriptblock]$AbortBody)
            $cleanSet    = { param($DscExePath, $ConfigFilePath, $ParsedTest) $null = $DscExePath, $ConfigFilePath, $ParsedTest; $script:setCalls++;    New-Set }
            $cleanVerify = { param($DscExePath, $ConfigFilePath) $null = $DscExePath, $ConfigFilePath; $script:verifyCalls++; New-Inv -ExitCode 0 -HadErrors $false -Resources @(@{ Name = 'X'; InDesiredState = $true }) }
            if ($Ph -eq 'set') {
                return @{ Test = $script:CleanDriftTest; Set = $AbortBody; Verify = $cleanVerify }
            }
            return @{ Test = $script:CleanDriftTest; Set = $cleanSet; Verify = $AbortBody }
        }

        It 'bails unattributable on a <Ph> abort with an empty culprit (no strip)' -ForEach @(@{ Ph = 'set' }, @{ Ph = 'verify' }) {
            Mock -ModuleName Dsc.Recovery Find-DscErrorSignal $script:FindByStderr
            Mock -ModuleName Dsc.Recovery New-StrippedConfigExcludingResources $script:StripKeepSurvivor
            $script:setErrMsg = 'set step failed on WrapperE: access denied'

            $abort = if ($Ph -eq 'set') {
                { param($DscExePath, $ConfigFilePath, $ParsedTest) $null = $DscExePath, $ConfigFilePath, $ParsedTest; $script:setCalls++; New-Set -Aborted $true -ExitCode 2 -Stderr @('no activity event') -Errored @([pscustomobject]@{ name = 'WrapperE'; message = $script:setErrMsg }) }
            } else {
                { param($DscExePath, $ConfigFilePath) $null = $DscExePath, $ConfigFilePath; $script:verifyCalls++; New-Inv -ExitCode 2 -HadErrors $true -Stderr @('no activity event') }
            }
            $inv = Get-AbortInvokers -Ph $Ph -AbortBody $abort

            $r = Invoke-FragmentConvergence -DscExePath $script:DscExe -ConfigFilePath $script:ConfigPath `
                -TestInvoker $inv.Test -SetInvoker $inv.Set -VerifyInvoker $inv.Verify

            $r.Outcome    | Should -Be 'bail'
            $r.BailReason | Should -Be 'unattributable'
            $r.Phase      | Should -Be $Ph
            Should -Invoke -ModuleName Dsc.Recovery New-StrippedConfigExcludingResources -Times 0 -Exactly
            if ($Ph -eq 'set') {
                # Content, not just shape: the aborting set's Errored entry flows through to SetErrored.
                @($r.SetErrored).Count   | Should -BeGreaterThan 0
                @($r.SetErrored.message) | Should -Contain $script:setErrMsg
            }
        }

        It 'bails fully_stripped on a <Ph> abort when the strip empties the config' -ForEach @(@{ Ph = 'set' }, @{ Ph = 'verify' }) {
            Mock -ModuleName Dsc.Recovery Find-DscErrorSignal $script:FindByStderr
            Mock -ModuleName Dsc.Recovery New-StrippedConfigExcludingResources { throw "excluding wrapper 'WrapperA' and its reverse-dependsOn closure leaves no resources in the config." }

            $abort = if ($Ph -eq 'set') {
                { param($DscExePath, $ConfigFilePath, $ParsedTest) $null = $DscExePath, $ConfigFilePath, $ParsedTest; $script:setCalls++; New-Set -Aborted $true -ExitCode 1 -Stderr @('CULPRIT=WrapperA') }
            } else {
                { param($DscExePath, $ConfigFilePath) $null = $DscExePath, $ConfigFilePath; $script:verifyCalls++; New-Inv -ExitCode 1 -HadErrors $true -Stderr @('CULPRIT=WrapperA') }
            }
            $inv = Get-AbortInvokers -Ph $Ph -AbortBody $abort

            $r = Invoke-FragmentConvergence -DscExePath $script:DscExe -ConfigFilePath $script:ConfigPath `
                -TestInvoker $inv.Test -SetInvoker $inv.Set -VerifyInvoker $inv.Verify

            $r.Outcome    | Should -Be 'bail'
            $r.BailReason | Should -Be 'fully_stripped'
            $r.Phase      | Should -Be $Ph
            @($r.QuarantinedResources).Count | Should -Be 0
        }

        It 'bails strip_failed on a <Ph> abort when the strip throws an unrelated error' -ForEach @(@{ Ph = 'set' }, @{ Ph = 'verify' }) {
            Mock -ModuleName Dsc.Recovery Find-DscErrorSignal $script:FindByStderr
            Mock -ModuleName Dsc.Recovery New-StrippedConfigExcludingResources { throw 'unexpected I/O error while writing the stripped config to a temp file' }

            $abort = if ($Ph -eq 'set') {
                { param($DscExePath, $ConfigFilePath, $ParsedTest) $null = $DscExePath, $ConfigFilePath, $ParsedTest; $script:setCalls++; New-Set -Aborted $true -ExitCode 1 -Stderr @('CULPRIT=WrapperA') }
            } else {
                { param($DscExePath, $ConfigFilePath) $null = $DscExePath, $ConfigFilePath; $script:verifyCalls++; New-Inv -ExitCode 1 -HadErrors $true -Stderr @('CULPRIT=WrapperA') }
            }
            $inv = Get-AbortInvokers -Ph $Ph -AbortBody $abort

            $r = Invoke-FragmentConvergence -DscExePath $script:DscExe -ConfigFilePath $script:ConfigPath `
                -TestInvoker $inv.Test -SetInvoker $inv.Set -VerifyInvoker $inv.Verify

            $r.Outcome    | Should -Be 'bail'
            $r.BailReason | Should -Be 'strip_failed'
            $r.Phase      | Should -Be $Ph
        }

        It 'bails no_shrink on a <Ph> abort when the same culprit recurs after a strip' -ForEach @(@{ Ph = 'set' }, @{ Ph = 'verify' }) {
            Mock -ModuleName Dsc.Recovery Find-DscErrorSignal $script:FindByStderr
            Mock -ModuleName Dsc.Recovery New-StrippedConfigExcludingResources $script:StripKeepSurvivor

            # Same culprit (WrapperA) every pass: pass 1 strips it, pass 2 re-abort -> no_shrink.
            $abort = if ($Ph -eq 'set') {
                { param($DscExePath, $ConfigFilePath, $ParsedTest) $null = $DscExePath, $ConfigFilePath, $ParsedTest; $script:setCalls++; New-Set -Aborted $true -ExitCode 1 -Stderr @('CULPRIT=WrapperA') }
            } else {
                { param($DscExePath, $ConfigFilePath) $null = $DscExePath, $ConfigFilePath; $script:verifyCalls++; New-Inv -ExitCode 1 -HadErrors $true -Stderr @('CULPRIT=WrapperA') }
            }
            $inv = Get-AbortInvokers -Ph $Ph -AbortBody $abort

            $r = Invoke-FragmentConvergence -DscExePath $script:DscExe -ConfigFilePath $script:ConfigPath `
                -TestInvoker $inv.Test -SetInvoker $inv.Set -VerifyInvoker $inv.Verify

            $r.Outcome    | Should -Be 'bail'
            $r.BailReason | Should -Be 'no_shrink'
            $r.Phase      | Should -Be $Ph
            @($r.Culprits) | Should -Be @('WrapperA')
            Should -Invoke -ModuleName Dsc.Recovery New-StrippedConfigExcludingResources -Times 1 -Exactly
        }

        It 'bails max_passes on a <Ph> abort when a rotating culprit shrinks past the cap' -ForEach @(@{ Ph = 'set' }, @{ Ph = 'verify' }) {
            $script:culpritSeq = @('WrapperA', 'WrapperB', 'WrapperC')
            Mock -ModuleName Dsc.Recovery Find-DscErrorSignal $script:FindByStderr
            Mock -ModuleName Dsc.Recovery New-StrippedConfigExcludingResources $script:StripKeepSurvivor

            $abort = if ($Ph -eq 'set') {
                { param($DscExePath, $ConfigFilePath, $ParsedTest) $null = $DscExePath, $ConfigFilePath, $ParsedTest; $name = $script:culpritSeq[$script:setCalls]; $script:setCalls++; New-Set -Aborted $true -ExitCode 1 -Stderr @("CULPRIT=$name") }
            } else {
                { param($DscExePath, $ConfigFilePath) $null = $DscExePath, $ConfigFilePath; $name = $script:culpritSeq[$script:verifyCalls]; $script:verifyCalls++; New-Inv -ExitCode 1 -HadErrors $true -Stderr @("CULPRIT=$name") }
            }
            $inv = Get-AbortInvokers -Ph $Ph -AbortBody $abort

            $r = Invoke-FragmentConvergence -DscExePath $script:DscExe -ConfigFilePath $script:ConfigPath `
                -TestInvoker $inv.Test -SetInvoker $inv.Set -VerifyInvoker $inv.Verify -MaxPasses 3

            $r.Outcome    | Should -Be 'bail'
            $r.BailReason | Should -Be 'max_passes'
            $r.Phase      | Should -Be $Ph
            $r.PassCount  | Should -Be 3
            @($r.Culprits) | Should -Be @('WrapperA', 'WrapperB')
            @($r.CulpritDetails).Count | Should -Be 3
            @($r.CulpritDetails.Phase | Sort-Object -Unique) | Should -Be $Ph   # every strip happened at the abort phase
            Should -Invoke -ModuleName Dsc.Recovery New-StrippedConfigExcludingResources -Times 2 -Exactly
        }
    }

    Context 'happy-path parity (RED-LINE: one test, one set, one verify, no strip)' {

        It 'a clean pass-1 test with drift runs exactly one set + verify and carries the set rows out' {
            Mock -ModuleName Dsc.Recovery Find-DscErrorSignal $script:FindByStderr
            Mock -ModuleName Dsc.Recovery New-StrippedConfigExcludingResources $script:StripKeepSurvivor

            $setRow = [pscustomobject]@{ resource_name = 'X'; phase = 'set'; lifecycle_event = 'end' }
            $setInvoker = { param($DscExePath, $ConfigFilePath, $ParsedTest) $null = $DscExePath, $ConfigFilePath, $ParsedTest; $script:setCalls++; New-Set -BufferedRows @($setRow) }

            $r = Invoke-FragmentConvergence -DscExePath $script:DscExe -ConfigFilePath $script:ConfigPath `
                -TestInvoker $script:CleanDriftTest -SetInvoker $setInvoker -VerifyInvoker $script:CleanVerify

            $r.Outcome   | Should -Be 'converged'
            $r.Phase     | Should -Be 'verify'
            $r.PassCount | Should -Be 1
            $r.Recovered | Should -BeFalse
            $script:invokeCount | Should -Be 1
            $script:setCalls    | Should -Be 1
            $script:verifyCalls | Should -Be 1
            # FinalSetRows == the single set's buffered rows (the enforcement finally flushes these).
            @($r.FinalSetRows).Count | Should -Be 1
            @($r.FinalSetRows)[0].resource_name | Should -Be 'X'
            Should -Invoke -ModuleName Dsc.Recovery New-StrippedConfigExcludingResources -Times 0 -Exactly
        }
    }

    Context 'observe-only path (RED-LINE: -EnableSet:$false never mutates on a dry run)' {

        It 'a clean-but-drifted test with -EnableSet:$false converges at test, invoking neither set nor verify' {
            Mock -ModuleName Dsc.Recovery Find-DscErrorSignal $script:FindByStderr
            Mock -ModuleName Dsc.Recovery New-StrippedConfigExcludingResources $script:StripKeepSurvivor

            # Clean (exit 0, no errors) yet drifted: AuditOnly/WhatIf reports drift but MUST NOT mutate.
            $r = Invoke-FragmentConvergence -DscExePath $script:DscExe -ConfigFilePath $script:ConfigPath `
                -EnableSet:$false -TestInvoker $script:CleanDriftTest -SetInvoker $script:CleanSet -VerifyInvoker $script:CleanVerify

            $r.Outcome     | Should -Be 'converged'
            $r.Phase       | Should -Be 'test'
            $r.FinalVerify | Should -BeNullOrEmpty
            $script:invokeCount | Should -Be 1
            # The dry-run mutation guard: zero set, zero verify.
            $script:setCalls    | Should -Be 0
            $script:verifyCalls | Should -Be 0
        }

        It 'the SAME drifted input with -EnableSet:$true DOES invoke set (the flag gates set, nothing else)' {
            Mock -ModuleName Dsc.Recovery Find-DscErrorSignal $script:FindByStderr
            Mock -ModuleName Dsc.Recovery New-StrippedConfigExcludingResources $script:StripKeepSurvivor

            $r = Invoke-FragmentConvergence -DscExePath $script:DscExe -ConfigFilePath $script:ConfigPath `
                -EnableSet:$true -TestInvoker $script:CleanDriftTest -SetInvoker $script:CleanSet -VerifyInvoker $script:CleanVerify

            $r.Outcome | Should -Be 'converged'
            $script:invokeCount | Should -Be 1
            $script:setCalls    | Should -Be 1
            $script:verifyCalls | Should -Be 1
        }
    }

    Context 'lying setter never loops (RED-LINE: terminal drift reports once, zero restarts)' {

        It 'a clean verify that still shows drift returns drift_persisted with no strip and no extra invocations' {
            Mock -ModuleName Dsc.Recovery Find-DscErrorSignal $script:FindByStderr
            Mock -ModuleName Dsc.Recovery New-StrippedConfigExcludingResources $script:StripKeepSurvivor

            # Verify is a CLEAN run (exit 0, no errors) but the wrapper is still drifted: the setter
            # silently failed to converge. This MUST terminate, never strip-and-restart.
            $lyingVerify = { param($DscExePath, $ConfigFilePath) $null = $DscExePath, $ConfigFilePath; $script:verifyCalls++; New-Inv -ExitCode 0 -HadErrors $false -Resources @(@{ Name = 'X'; InDesiredState = $false }) }

            $r = Invoke-FragmentConvergence -DscExePath $script:DscExe -ConfigFilePath $script:ConfigPath `
                -TestInvoker $script:CleanDriftTest -SetInvoker $script:CleanSet -VerifyInvoker $lyingVerify

            $r.Outcome   | Should -Be 'drift_persisted'
            $r.Phase     | Should -Be 'verify'
            $r.Recovered | Should -BeFalse
            $r.FinalVerify | Should -Not -BeNullOrEmpty
            # Zero restarts: one of each invocation, no strip.
            $script:invokeCount | Should -Be 1
            $script:setCalls    | Should -Be 1
            $script:verifyCalls | Should -Be 1
            Should -Invoke -ModuleName Dsc.Recovery New-StrippedConfigExcludingResources -Times 0 -Exactly
        }

        It 'Write-RunSummary accepts the drift_persisted outcome the loop returns (no ValidateSet gap)' {
            $outcomeParam = (Get-Command Write-RunSummary).Parameters['Outcome']
            $validValues  = ($outcomeParam.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }).ValidValues
            'drift_persisted' | Should -BeIn $validValues
        }
    }

    Context 'partial set then restart targets only the still-drifted survivors' {

        It 'excludes an already-applied wrapper from the pass-2 set (no dependsOn forward-expansion)' {
            Mock -ModuleName Dsc.Recovery Find-DscErrorSignal $script:FindByStderr
            Mock -ModuleName Dsc.Recovery New-StrippedConfigExcludingResources $script:StripKeepSurvivor

            # Pass 1 set applies WrapperB then aborts on WrapperC; restart shows B clean, D still drifted.
            $testInvoker = {
                param($DscExePath, $ConfigFilePath)
                $null = $DscExePath, $ConfigFilePath
                $script:invokeCount++
                if ($script:invokeCount -eq 1) {
                    New-Inv -ExitCode 0 -HadErrors $false -Resources @(@{ Name = 'WrapperB'; InDesiredState = $false }, @{ Name = 'WrapperC'; InDesiredState = $false }, @{ Name = 'WrapperD'; InDesiredState = $false })
                } else {
                    New-Inv -ExitCode 0 -HadErrors $false -Resources @(@{ Name = 'WrapperB'; InDesiredState = $true }, @{ Name = 'WrapperD'; InDesiredState = $false })
                }
            }
            # The set records the still-drifted names it is handed each pass (the seam the closure filters).
            $script:setDriftedByPass = New-Object System.Collections.Generic.List[object]
            $setInvoker = {
                param($DscExePath, $ConfigFilePath, $ParsedTest)
                $null = $DscExePath, $ConfigFilePath
                $script:setCalls++
                # Direct assignment preserves the helper's ,$array idiom (no nested-array wrap).
                $drifted = Get-DriftedTopLevelResourceNames -ParsedTest $ParsedTest
                $script:setDriftedByPass.Add($drifted)
                if ($script:setCalls -eq 1) { New-Set -Aborted $true -ExitCode 1 -Stderr @('CULPRIT=WrapperC') } else { New-Set }
            }

            $r = Invoke-FragmentConvergence -DscExePath $script:DscExe -ConfigFilePath $script:ConfigPath `
                -TestInvoker $testInvoker -SetInvoker $setInvoker -VerifyInvoker $script:CleanVerify

            $r.Outcome | Should -Be 'converged'
            @($script:setDriftedByPass[0]) | Should -Be @('WrapperB', 'WrapperC', 'WrapperD')
            # Pass 2 targets only WrapperD -- the already-applied WrapperB is excluded.
            @($script:setDriftedByPass[1]) | Should -Be @('WrapperD')
        }
    }

    Context 'C1 adversarial: forward-expansion re-pulls a compliant upstream without duplicating its row' {

        BeforeAll {
            . (Join-Path $script:RepoRoot 'tests\fixtures\Dsc.ConfigFilter.Fixtures.ps1')
        }

        It 'pass-2 filtered set re-includes the compliant dependency yet flushes exactly one row for it' {
            # Real config: WrapperD dependsOn WrapperB; WrapperC is the pass-1 culprit.
            $sourceCfg = New-DscConfigFile -Path (Join-Path $TestDrive 'c1-source.yaml') -Wrappers @(
                @{ Name = 'WrapperB' }
                @{ Name = 'WrapperC' }
                @{ Name = 'WrapperD'; DependsOn = @('WrapperB') }
            )
            # Strip removes the pass-1 culprit (WrapperC) and writes a REAL survivor config (B + D)
            # so pass 2's set can run the real forward-expansion filter against it.
            $survivorCfg = New-DscConfigFile -Path (Join-Path $TestDrive 'c1-survivors.yaml') -Wrappers @(
                @{ Name = 'WrapperB' }
                @{ Name = 'WrapperD'; DependsOn = @('WrapperB') }
            )
            Mock -ModuleName Dsc.Recovery Find-DscErrorSignal $script:FindByStderr
            Mock -ModuleName Dsc.Recovery New-StrippedConfigExcludingResources {
                param([string[]]$ExcludeResourceNames)
                [pscustomobject]@{ Path = $survivorCfg; ExcludedNames = @($ExcludeResourceNames); KeptNames = @('WrapperB', 'WrapperD') }
            }.GetNewClosure()

            $testInvoker = {
                param($DscExePath, $ConfigFilePath)
                $null = $DscExePath, $ConfigFilePath
                $script:invokeCount++
                if ($script:invokeCount -eq 1) {
                    New-Inv -ExitCode 0 -HadErrors $false -Resources @(@{ Name = 'WrapperB'; InDesiredState = $false }, @{ Name = 'WrapperC'; InDesiredState = $false }, @{ Name = 'WrapperD'; InDesiredState = $false })
                } else {
                    New-Inv -ExitCode 0 -HadErrors $false -Resources @(@{ Name = 'WrapperB'; InDesiredState = $true }, @{ Name = 'WrapperD'; InDesiredState = $false })
                }
            }
            # Set mimics the enforcement closure: real filter against the effective config, buffer a
            # set row per emitted wrapper. Pass 1 emits a WrapperB row then aborts (discarded on restart).
            $script:pass2FilteredNames = @()
            $setInvoker = {
                param($DscExePath, $ConfigFilePath, $ParsedTest)
                $null = $DscExePath
                $script:setCalls++
                $drifted  = Get-DriftedTopLevelResourceNames -ParsedTest $ParsedTest
                $filtered = New-FilteredConfigForResources -SourcePath $ConfigFilePath -ResourceNames $drifted
                try {
                    $graph = Get-EmittedWrapperGraph -Path $filtered
                    $names = @($graph.Keys)
                } finally {
                    if (Test-Path -LiteralPath $filtered) { Remove-Item -LiteralPath $filtered -Force -ErrorAction SilentlyContinue }
                }
                $rows = @($names | ForEach-Object { [pscustomobject]@{ resource_name = $_; phase = 'set'; lifecycle_event = 'end' } })
                if ($script:setCalls -eq 1) {
                    New-Set -Aborted $true -ExitCode 1 -Stderr @('CULPRIT=WrapperC') -BufferedRows $rows
                } else {
                    $script:pass2FilteredNames = $names
                    New-Set -BufferedRows $rows
                }
            }

            $r = Invoke-FragmentConvergence -DscExePath $script:DscExe -ConfigFilePath $sourceCfg `
                -TestInvoker $testInvoker -SetInvoker $setInvoker -VerifyInvoker $script:CleanVerify

            $r.Outcome | Should -Be 'converged'
            # Documented C1 behavior: requesting only WrapperD re-pulls its compliant upstream WrapperB.
            @($script:pass2FilteredNames) | Should -Contain 'WrapperB'

            # The enforcement finally flushes ONLY the final set's rows; emulate it and assert no dup B.
            $jsonl = Join-Path $TestDrive ('c1-resources-{0}.jsonl' -f [guid]::NewGuid().ToString('N'))
            foreach ($row in @($r.FinalSetRows)) { Write-JsonLine -Path $jsonl -Record $row }
            $rows = @(Get-Content -LiteralPath $jsonl | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
            @($rows | Where-Object { $_.resource_name -eq 'WrapperB' }).Count | Should -Be 1
        }
    }

    Context 'set-lifecycle buffer suppression' {

        It 'discards an intermediate (stripped) pass set rows and flushes only the final set rows' {
            Mock -ModuleName Dsc.Recovery Find-DscErrorSignal $script:FindByStderr
            Mock -ModuleName Dsc.Recovery New-StrippedConfigExcludingResources $script:StripKeepSurvivor

            $pass1Row = [pscustomobject]@{ resource_name = 'Intermediate'; phase = 'set' }
            $pass2Row = [pscustomobject]@{ resource_name = 'Final'; phase = 'set' }
            $setInvoker = {
                param($DscExePath, $ConfigFilePath, $ParsedTest)
                $null = $DscExePath, $ConfigFilePath, $ParsedTest
                $script:setCalls++
                if ($script:setCalls -eq 1) { New-Set -Aborted $true -ExitCode 1 -Stderr @('CULPRIT=WrapperA') -BufferedRows @($pass1Row) }
                else { New-Set -BufferedRows @($pass2Row) }
            }

            $r = Invoke-FragmentConvergence -DscExePath $script:DscExe -ConfigFilePath $script:ConfigPath `
                -TestInvoker $script:CleanDriftTest -SetInvoker $setInvoker -VerifyInvoker $script:CleanVerify

            $r.Outcome | Should -Be 'converged'
            @($r.FinalSetRows).Count | Should -Be 1
            @($r.FinalSetRows)[0].resource_name | Should -Be 'Final'
            @($r.FinalSetRows).resource_name | Should -Not -Contain 'Intermediate'
        }
    }

    Context 'termination: a culprit rotating across all three phases still bails at the cap' {

        It 'rotating phase + culprit shrinks the keep-set every pass and bails max_passes' {
            $script:rotSeq = @('WrapperA', 'WrapperB', 'WrapperC')
            Mock -ModuleName Dsc.Recovery Find-DscErrorSignal $script:FindByStderr
            Mock -ModuleName Dsc.Recovery New-StrippedConfigExcludingResources $script:StripKeepSurvivor

            # Pass 1 aborts at TEST, pass 2 at SET, pass 3 at VERIFY -- each with a distinct culprit.
            $testInvoker = {
                param($DscExePath, $ConfigFilePath)
                $null = $DscExePath, $ConfigFilePath
                $script:invokeCount++
                if ($script:invokeCount -eq 1) {
                    New-Inv -ExitCode 1 -HadErrors $true -Stderr @('CULPRIT=WrapperA')
                } else {
                    New-Inv -ExitCode 0 -HadErrors $false -Resources @(@{ Name = 'X'; InDesiredState = $false })
                }
            }
            $setInvoker = {
                param($DscExePath, $ConfigFilePath, $ParsedTest)
                $null = $DscExePath, $ConfigFilePath, $ParsedTest
                $script:setCalls++
                if ($script:setCalls -eq 1) { New-Set -Aborted $true -ExitCode 1 -Stderr @('CULPRIT=WrapperB') } else { New-Set }
            }
            $verifyInvoker = {
                param($DscExePath, $ConfigFilePath)
                $null = $DscExePath, $ConfigFilePath
                $script:verifyCalls++
                New-Inv -ExitCode 1 -HadErrors $true -Stderr @('CULPRIT=WrapperC')
            }

            $r = Invoke-FragmentConvergence -DscExePath $script:DscExe -ConfigFilePath $script:ConfigPath `
                -TestInvoker $testInvoker -SetInvoker $setInvoker -VerifyInvoker $verifyInvoker -MaxPasses 3

            $r.Outcome    | Should -Be 'bail'
            $r.BailReason | Should -Be 'max_passes'
            $r.PassCount  | Should -Be 3
            $r.Phase      | Should -Be 'verify'
            # Monotonic shrink: A stripped (pass 1), B stripped (pass 2); C captured but not stripped at cap.
            @($r.Culprits) | Should -Be @('WrapperA', 'WrapperB')
            @($r.CulpritDetails).Count | Should -Be 3
            # Each culprit records the phase it aborted at: A=test, B=set, C=verify.
            (@($r.CulpritDetails) | Where-Object { $_.Name -eq 'WrapperA' }).Phase | Should -Be 'test'
            (@($r.CulpritDetails) | Where-Object { $_.Name -eq 'WrapperB' }).Phase | Should -Be 'set'
            (@($r.CulpritDetails) | Where-Object { $_.Name -eq 'WrapperC' }).Phase | Should -Be 'verify'
            Should -Invoke -ModuleName Dsc.Recovery New-StrippedConfigExcludingResources -Times 2 -Exactly
        }
    }
}
