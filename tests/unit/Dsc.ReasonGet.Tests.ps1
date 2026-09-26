#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Focused tests for pre-set reason harvesting.
.DESCRIPTION
    Verifies that one optional reason get runs after a clean drifted test and before set, that its
    envelope follows the test projection, and that failures cannot block remediation. Also covers
    AuditOnly, convergence restarts, and test-duration accounting.
#>

Set-StrictMode -Version Latest

BeforeAll {
    Set-StrictMode -Version Latest

    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:AgentRoot = Join-Path $script:RepoRoot 'src\agent\windows'
    $script:ModuleRoot = Join-Path $script:AgentRoot 'Modules'
    $script:EnforcementPath = Join-Path $script:AgentRoot 'Invoke-Enforcement.ps1'

    Import-Module (Join-Path $script:ModuleRoot 'Dsc.HostContext.psm1') -Force
    Import-Module (Join-Path $script:ModuleRoot 'Dsc.ResultProjection.psm1') -Force
    Import-Module (Join-Path $script:ModuleRoot 'Dsc.ConfigFilter.psm1') -Force
    Import-Module (Join-Path $script:ModuleRoot 'Dsc.Diagnostics.psm1') -Force
    Import-Module (Join-Path $script:ModuleRoot 'Dsc.Reasons.psm1') -Force
    Import-Module (Join-Path $script:ModuleRoot 'Dsc.JsonLog.psm1') -Force
    Import-Module (Join-Path $script:ModuleRoot 'Dsc.Recovery.psm1') -Force

    $script:DscExe = 'C:\fake\dsc.exe'
    $script:ConfigPath = 'C:\fake\fragment.dsc.yaml'

    function script:New-TestInvocation {
        param([bool]$InDesiredState)

        [pscustomobject]@{
            Native = [pscustomobject]@{ ExitCode = 0; Stderr = @() }
            Parsed = [pscustomobject]@{
                HadErrors = $false
                Duration  = 'PT0S'
                Results   = @(
                    [pscustomobject]@{
                        name   = 'WrapperA'
                        type   = 'Microsoft.DSC/PowerShell'
                        result = [pscustomobject]@{ inDesiredState = $InDesiredState }
                    }
                )
            }
            Timings = @()
        }
    }

    function script:New-SetResult {
        param([bool]$Aborted = $false)

        [pscustomobject]@{
            Native       = [pscustomobject]@{ ExitCode = $(if ($Aborted) { 1 } else { 0 }); Stderr = @('set result') }
            Parsed       = $null
            Errored      = @()
            BufferedRows = @()
            Aborted      = $Aborted
        }
    }

    # Minimal PowerShell-adapter TEST envelope: one wrapper hosting one inner resource. Shaped like a
    # real composed fragment so Test-IsDscAdapterWrapper unwraps it and the projection emits one row.
    function script:New-AdapterTestParsed {
        param([bool]$InDesiredState = $false)

        [pscustomobject]@{
            HadErrors = $false
            Duration  = 'PT0S'
            Results   = @(
                [pscustomobject]@{
                    name   = 'HostsFileCorpWrapper'
                    type   = 'Microsoft.DSC/PowerShell'
                    result = [pscustomobject]@{
                        hadErrors   = $false
                        actualState = [pscustomobject]@{
                            result = @(
                                [pscustomobject]@{
                                    type       = 'EndSecHostsFile/EndSecHostsFile'
                                    name       = 'HostsFileCorp'
                                    properties = [pscustomobject]@{ InDesiredState = $InDesiredState }
                                }
                            )
                        }
                    }
                }
            )
        }
    }

    # Matching GET envelope carrying the module-authored Reasons[] the harvest exists to capture. The
    # composite key (adapterType|adapterName|innerType|innerName) must match New-AdapterTestParsed.
    function script:New-AdapterGetParsed {
        param(
            [Parameter(Mandatory)][string]$Phrase,
            [string]$Code = 'block_absent'
        )

        [pscustomobject]@{
            HadErrors = $false
            Results   = @(
                [pscustomobject]@{
                    name   = 'HostsFileCorpWrapper'
                    type   = 'Microsoft.DSC/PowerShell'
                    result = [pscustomobject]@{
                        actualState = [pscustomobject]@{
                            result = @(
                                [pscustomobject]@{
                                    type       = 'EndSecHostsFile/EndSecHostsFile'
                                    name       = 'HostsFileCorp'
                                    properties = [pscustomobject]@{
                                        Reasons = @(
                                            [pscustomobject]@{ Code = $Code; Phrase = $Phrase }
                                        )
                                    }
                                }
                            )
                        }
                    }
                }
            )
        }
    }

    # Runs the real emit path and returns the parsed resources.jsonl rows for a single fragment.
    function script:Invoke-FinalStateEmit {
        param(
            [Parameter(Mandatory)][object]$FinalTest,
            [Parameter()][AllowNull()][object]$FinalTestGet
        )

        $out = Join-Path $TestDrive ("resources-{0}.jsonl" -f ([guid]::NewGuid().ToString('N')))
        Write-FinalStateResourceRecords `
            -FinalTest $FinalTest -FinalTestGet $FinalTestGet `
            -TestTimestamp '2026-07-30T00:00:00Z' -Trigger 'scheduled' -Path $out `
            -SchemaVersion '3.0' -RunId 'run-reasonget' -ConfigVersion '1.6.7' `
            -Group 'hp' -Role 'svc' -FragmentName 'FragmentA'
        return @(Get-Content -LiteralPath $out | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    }

    # Drives the REAL enforcement wiring: the `$periodicGetParsed = $recovery.TestGet` assignment and
    # bundle staging, then the real single post-convergence emit -- both dot-sourced verbatim out of
    # Invoke-Enforcement.ps1. Nothing between $recovery and resources.jsonl is faked, so severing the
    # script-level fix (the line that makes the harvest reach telemetry at all) fails here.
    function script:Invoke-EnforcementWiringEmit {
        param(
            [Parameter(Mandatory)][object]$Recovery,
            [Parameter(Mandatory)][object]$ParsedTest
        )

        $wiringSource = Get-EnforcementSnippet `
            -StartAnchor '# Reasons come from the pre-set harvest run inside convergence' `
            -EndAnchor '# Survivor summary + quarantine split'
        $emitSource = Get-EnforcementSnippet `
            -StartAnchor '# Single post-convergence emit: write the staged final test + verify rows exactly once, on' `
            -EndAnchor "# Flush the loop's buffered final-set rows once."

        $warnings = [System.Collections.Generic.List[string]]::new()
        function local:Write-NativeStderr {
            param($Text)
            $warnings.Add([string]$Text)
        }

        # Enforcement-loop locals the two snippets close over, named exactly as production names them.
        $recovery              = $Recovery
        $parsedTest            = $ParsedTest
        $testTimestamp         = '2026-07-30T00:00:00Z'
        $testTimings           = $null
        $pendingVerifyBundle   = $null
        $fragmentName          = 'FragmentA'
        $RunTrigger            = 'scheduled'
        $resourcesLog          = Join-Path $TestDrive ("wiring-{0}.jsonl" -f ([guid]::NewGuid().ToString('N')))
        $resourcesSchemaVersion = '3.0'
        $runId                 = 'run-wiring'
        $configVersion         = '1.6.7'
        $group                 = 'hp'
        $role                  = 'svc'
        $configurationHash     = $null
        # Consumed only inside the dot-sourced production snippets, which PSSA cannot follow.
        $null = $testTimestamp, $testTimings, $pendingVerifyBundle, $fragmentName, $RunTrigger,
            $resourcesSchemaVersion, $runId, $configVersion, $group, $role, $configurationHash

        . ([scriptblock]::Create($wiringSource))
        . ([scriptblock]::Create($emitSource))

        $rows = @()
        if (Test-Path -LiteralPath $resourcesLog) {
            $rows = @(Get-Content -LiteralPath $resourcesLog | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        }
        return [pscustomobject]@{
            Rows             = $rows
            Warnings         = @($warnings)
            StagedGet        = $pendingTestBundle.Get
            HarvestedParsed  = $periodicGetParsed
        }
    }

    function script:Get-EnforcementSnippet {
        param(
            [Parameter(Mandatory)][string]$StartAnchor,
            [Parameter(Mandatory)][string]$EndAnchor
        )

        $lines = @(Get-Content -LiteralPath $script:EnforcementPath)
        $start = -1
        $end = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($start -lt 0 -and $lines[$i].Contains($StartAnchor)) {
                $start = $i
                continue
            }
            if ($start -ge 0 -and $lines[$i].Contains($EndAnchor)) {
                $end = $i
                break
            }
        }
        if ($start -lt 0 -or $end -lt 0) {
            throw "Could not find enforcement snippet between '$StartAnchor' and '$EndAnchor'."
        }
        return ($lines[$start..($end - 1)] -join "`n")
    }

    # The production EnableSet decision line, extracted verbatim from Invoke-Enforcement.ps1.
    $script:EnableSetSource = Get-EnforcementSnippet `
        -StartAnchor '# One decision governs set: AuditOnly observes only, and ShouldProcess (-WhatIf / -Confirm)' `
        -EndAnchor '# Convergence wraps test->(targeted set)->verify, stripping an attributable abort'

    # Evaluates the real EnableSet expression inside a genuine advanced function so $PSCmdlet is a real
    # PSScriptCmdlet: -WhatIf makes ShouldProcess return $false, no switch returns $true. This exercises
    # the actual `(-not $AuditOnly) -and $PSCmdlet.ShouldProcess(...)` mapping rather than a fake object.
    function script:Get-EnableSetDecision {
        [CmdletBinding(SupportsShouldProcess)]
        # Both usages live inside the dot-sourced snippet string, which PSSA cannot analyze:
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSShouldProcess', '',
            Justification = 'The ShouldProcess call is in the enforcement snippet dot-sourced from $script:EnableSetSource; SupportsShouldProcess is required so $PSCmdlet.ShouldProcess resolves to a real PSScriptCmdlet.'
        )]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSReviewUnusedParameter', '',
            Justification = '$AuditOnly is referenced by the dot-sourced enforcement snippet; PSSA cannot follow usage inside a [scriptblock]::Create string.'
        )]
        param([Parameter(Mandatory)][bool]$AuditOnly)
        $fragmentName = 'FragmentA'
        $null = $fragmentName
        . ([scriptblock]::Create($script:EnableSetSource))
        return [bool]$enableSet
    }
}

Describe 'Invoke-FragmentConvergence pre-set reason get' {
    BeforeEach {
        Mock -ModuleName Dsc.Recovery Write-NativeStderr {}
        $script:order = [System.Collections.Generic.List[string]]::new()
        $script:setCalled = $false
    }

    It 'orders TEST -> GET -> SET -> VERIFY and propagates the GET envelope' {
        $script:envelope = [pscustomobject]@{ HadErrors = $false; Results = @('pre-set') }
        $script:seenConfig = ''
        $script:seenNames = @()

        $testInvoker = {
            param($ExePath, $ConfigFilePath)
            $null = $ExePath, $ConfigFilePath
            $script:order.Add('test')
            New-TestInvocation -InDesiredState $false
        }
        $getInvoker = {
            param($ExePath, $ConfigFilePath, $DriftedNames)
            $null = $ExePath
            $script:order.Add('get')
            $script:seenConfig = $ConfigFilePath
            $script:seenNames = @($DriftedNames)
            $script:envelope
        }
        $setInvoker = {
            param($ExePath, $ConfigFilePath, $ParsedTest)
            $null = $ExePath, $ConfigFilePath, $ParsedTest
            $script:order.Add('set')
            New-SetResult
        }
        $verifyInvoker = {
            param($ExePath, $ConfigFilePath)
            $null = $ExePath, $ConfigFilePath
            $script:order.Add('verify')
            New-TestInvocation -InDesiredState $true
        }

        $result = Invoke-FragmentConvergence -DscExePath $script:DscExe -ConfigFilePath $script:ConfigPath `
            -TestInvoker $testInvoker -TestGetInvoker $getInvoker `
            -SetInvoker $setInvoker -VerifyInvoker $verifyInvoker

        $script:order -join ',' | Should -Be 'test,get,set,verify'
        $script:seenConfig | Should -Be $script:ConfigPath
        $script:seenNames | Should -Be @('WrapperA')
        $result.TestGet | Should -Be $script:envelope
    }

    It 'still converges with null TestGet when both the callback and stderr diagnostic throw' {
        Mock -ModuleName Dsc.Recovery Write-NativeStderr { throw 'stderr writer failed' }

        $testInvoker = {
            param($ExePath, $ConfigFilePath)
            $null = $ExePath, $ConfigFilePath
            New-TestInvocation -InDesiredState $false
        }
        $getInvoker = {
            param($ExePath, $ConfigFilePath, $DriftedNames)
            $null = $ExePath, $ConfigFilePath, $DriftedNames
            throw 'optional telemetry failed'
        }
        $setInvoker = {
            param($ExePath, $ConfigFilePath, $ParsedTest)
            $null = $ExePath, $ConfigFilePath, $ParsedTest
            $script:setCalled = $true
            New-SetResult
        }
        $verifyInvoker = {
            param($ExePath, $ConfigFilePath)
            $null = $ExePath, $ConfigFilePath
            New-TestInvocation -InDesiredState $true
        }

        $result = Invoke-FragmentConvergence -DscExePath $script:DscExe -ConfigFilePath $script:ConfigPath `
            -TestInvoker $testInvoker -TestGetInvoker $getInvoker `
            -SetInvoker $setInvoker -VerifyInvoker $verifyInvoker

        $script:setCalled | Should -BeTrue
        $result.Outcome | Should -Be 'converged'
        $result.Phase | Should -Be 'verify'
        $result.TestGet | Should -BeNullOrEmpty
        Should -Invoke -ModuleName Dsc.Recovery Write-NativeStderr -Times 1
    }

    It 'does not invoke GET when TEST finds no drift' {
        $script:getCalled = $false
        $testInvoker = {
            param($ExePath, $ConfigFilePath)
            $null = $ExePath, $ConfigFilePath
            New-TestInvocation -InDesiredState $true
        }
        $getInvoker = {
            param($ExePath, $ConfigFilePath, $DriftedNames)
            $null = $ExePath, $ConfigFilePath, $DriftedNames
            $script:getCalled = $true
        }

        $result = Invoke-FragmentConvergence -DscExePath $script:DscExe -ConfigFilePath $script:ConfigPath `
            -TestInvoker $testInvoker -TestGetInvoker $getInvoker

        $script:getCalled | Should -BeFalse
        $result.TestGet | Should -BeNullOrEmpty
    }

    It 'still invokes GET once when set is disabled for AuditOnly or WhatIf' {
        $script:getCount = 0
        $script:envelope = [pscustomobject]@{ HadErrors = $false; Results = @('audit') }
        $testInvoker = {
            param($ExePath, $ConfigFilePath)
            $null = $ExePath, $ConfigFilePath
            New-TestInvocation -InDesiredState $false
        }
        $getInvoker = {
            param($ExePath, $ConfigFilePath, $DriftedNames)
            $null = $ExePath, $ConfigFilePath, $DriftedNames
            $script:getCount++
            $script:envelope
        }

        $result = Invoke-FragmentConvergence -DscExePath $script:DscExe -ConfigFilePath $script:ConfigPath `
            -TestInvoker $testInvoker -TestGetInvoker $getInvoker -EnableSet $false

        $script:getCount | Should -Be 1
        $script:setCalled | Should -BeFalse
        $result.TestGet | Should -Be $script:envelope
        $result.Phase | Should -Be 'test'
    }

    It 'resets TestGet when a set abort causes a convergence restart' {
        Mock -ModuleName Dsc.Recovery Find-DscErrorSignal {
            [pscustomobject]@{
                Excerpt = 'set abort'; ResourceName = 'WrapperA'
                ResourceType = 'Microsoft.DSC/PowerShell'
            }
        }
        Mock -ModuleName Dsc.Recovery New-StrippedConfigExcludingResources {
            param($SourcePath, $ExcludeResourceNames)
            $null = $SourcePath
            [pscustomobject]@{
                Path          = 'C:\fake\stripped.dsc.yaml'
                ExcludedNames = @($ExcludeResourceNames)
                KeptNames     = @('Survivor')
            }
        }

        $script:getPass = 0
        $script:setPass = 0
        $script:getPaths = [System.Collections.Generic.List[string]]::new()
        $testInvoker = {
            param($ExePath, $ConfigFilePath)
            $null = $ExePath, $ConfigFilePath
            New-TestInvocation -InDesiredState $false
        }
        $getInvoker = {
            param($ExePath, $ConfigFilePath, $DriftedNames)
            $null = $ExePath, $DriftedNames
            $script:getPass++
            $script:getPaths.Add([string]$ConfigFilePath)
            if ($script:getPass -eq 1) {
                return [pscustomobject]@{ HadErrors = $false; Results = @('stale') }
            }
            return $null
        }
        $setInvoker = {
            param($ExePath, $ConfigFilePath, $ParsedTest)
            $null = $ExePath, $ConfigFilePath, $ParsedTest
            $script:setPass++
            New-SetResult -Aborted:($script:setPass -eq 1)
        }
        $verifyInvoker = {
            param($ExePath, $ConfigFilePath)
            $null = $ExePath, $ConfigFilePath
            New-TestInvocation -InDesiredState $true
        }

        $result = Invoke-FragmentConvergence -DscExePath $script:DscExe -ConfigFilePath $script:ConfigPath `
            -TestInvoker $testInvoker -TestGetInvoker $getInvoker `
            -SetInvoker $setInvoker -VerifyInvoker $verifyInvoker

        $result.PassCount | Should -Be 2
        $script:getPass | Should -Be 2
        $result.TestGet | Should -BeNullOrEmpty
        # Pass 2 must harvest the STRIPPED effective config, not the original: reasons have to describe
        # the resources the retry pass actually tests.
        $script:getPaths[0] | Should -Be $script:ConfigPath
        $script:getPaths[1] | Should -Be 'C:\fake\stripped.dsc.yaml'
    }

    It 'discards the pass-1 envelope when the restarted pass finds no drift (per-pass reset, not overwrite)' {
        # The other restart test lets pass 2 harvest and return $null, so it cannot distinguish the
        # per-pass reset from a plain overwrite. Here pass 2 is clean: the harvest never runs, so only
        # the explicit `$ctx.LastTestGet = $null` reset can keep the stale pass-1 envelope out of the
        # result. Drop that reset and this test reports the pass-1 reasons against a converged pass.
        Mock -ModuleName Dsc.Recovery Find-DscErrorSignal {
            [pscustomobject]@{
                Excerpt = 'set abort'; ResourceName = 'WrapperA'
                ResourceType = 'Microsoft.DSC/PowerShell'
            }
        }
        Mock -ModuleName Dsc.Recovery New-StrippedConfigExcludingResources {
            param($SourcePath, $ExcludeResourceNames)
            $null = $SourcePath
            [pscustomobject]@{
                Path          = 'C:\fake\stripped.dsc.yaml'
                ExcludedNames = @($ExcludeResourceNames)
                KeptNames     = @('Survivor')
            }
        }

        $script:testPass = 0
        $script:getPass = 0
        $script:stale = [pscustomobject]@{ HadErrors = $false; Results = @('stale-pass-1') }
        $testInvoker = {
            param($ExePath, $ConfigFilePath)
            $null = $ExePath, $ConfigFilePath
            $script:testPass++
            New-TestInvocation -InDesiredState ($script:testPass -ge 2)
        }
        $getInvoker = {
            param($ExePath, $ConfigFilePath, $DriftedNames)
            $null = $ExePath, $ConfigFilePath, $DriftedNames
            $script:getPass++
            $script:stale
        }
        $setInvoker = {
            param($ExePath, $ConfigFilePath, $ParsedTest)
            $null = $ExePath, $ConfigFilePath, $ParsedTest
            New-SetResult -Aborted $true
        }

        $result = Invoke-FragmentConvergence -DscExePath $script:DscExe -ConfigFilePath $script:ConfigPath `
            -TestInvoker $testInvoker -TestGetInvoker $getInvoker -SetInvoker $setInvoker

        $result.PassCount | Should -Be 2
        $script:getPass | Should -Be 1
        $result.Phase | Should -Be 'test'
        $result.Outcome | Should -Be 'converged'
        $result.TestGet | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-Enforcement pre-set reason get boundary' {
    It 'returns null when the get path and warning writer both throw' {
        $helperSource = Get-EnforcementSnippet `
            -StartAnchor 'function script:Write-OptionalReasonDiagnostic' `
            -EndAnchor 'function script:Get-DscResourceResolutionFailureToken'
        . ([scriptblock]::Create($helperSource))

        function local:Write-NativeStderr {
            param($Text)
            $null = $Text
            throw 'stderr writer failed'
        }
        function local:New-FilteredConfigForResources {
            param($SourcePath, $ResourceNames)
            $null = $SourcePath, $ResourceNames
            return 'C:\fake\reason-get.dsc.yaml'
        }
        function local:Invoke-DscGetJson {
            param($DscExePath, $ConfigFilePath)
            $null = $DscExePath, $ConfigFilePath
            throw 'optional get failed'
        }

        $fragmentName = 'FragmentA'
        $fragTimers = @{ ReasonGet = [TimeSpan]::Zero }
        $closureSource = Get-EnforcementSnippet `
            -StartAnchor '# REASON GET seam: one pre-set `dsc config get` scoped to the drifted wrappers.' `
            -EndAnchor '# One decision governs set: AuditOnly observes only, and ShouldProcess (-WhatIf / -Confirm)'
        . ([scriptblock]::Create($closureSource))

        $result = & $testGetInvoker $script:DscExe $script:ConfigPath @('WrapperA')
        $null = $fragmentName, $fragTimers

        $result | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-Enforcement duration accounting' {
    It 'subtracts reason-get elapsed time from test_duration and clamps at zero' {
        $source = Get-EnforcementSnippet `
            -StartAnchor '# Test wall-clock excludes set, verify, and the pre-set reason get without changing the schema.' `
            -EndAnchor '# Strip-and-retry recovery temp config is owned here;'

        $fragConvergeSw = [pscustomobject]@{
            IsRunning = $false
            Elapsed   = [TimeSpan]::FromSeconds(15)
        }
        $fragTimers = @{
            Set           = [TimeSpan]::FromSeconds(3)
            Verify        = [TimeSpan]::FromSeconds(2)
            ReasonGet = [TimeSpan]::FromSeconds(7)
        }
        $null = $fragTimers
        $aggSetElapsed = [TimeSpan]::Zero
        $aggVerifyElapsed = [TimeSpan]::Zero
        $aggTestElapsed = [TimeSpan]::Zero

        . ([scriptblock]::Create($source))

        $aggSetElapsed | Should -Be ([TimeSpan]::FromSeconds(3))
        $aggVerifyElapsed | Should -Be ([TimeSpan]::FromSeconds(2))
        $aggTestElapsed | Should -Be ([TimeSpan]::FromSeconds(3))

        $fragConvergeSw.Elapsed = [TimeSpan]::FromSeconds(5)
        $aggTestElapsed = [TimeSpan]::Zero
        . ([scriptblock]::Create($source))
        $aggTestElapsed | Should -Be ([TimeSpan]::Zero)
    }
}

Describe 'Reason projection consumes the pre-set TestGet envelope' {
    # These exercise the REAL emit path (Write-FinalStateResourceRecords -> Write-ResourceRecords ->
    # Get-PowerShellAdapterInnerReasons), so a regression that stops propagating the harvested reason
    # onto the non_compliant test row -- the exact telemetry bug in ADO 16372772 -- fails here.

    It 'stamps the harvested pre-set reason on the non_compliant test row (not the synthetic fallback)' {
        $phrase = "Managed block 'Corp' drift: block not present; 155 missing"
        $rows = @(Invoke-FinalStateEmit `
            -FinalTest (New-AdapterTestParsed -InDesiredState $false) `
            -FinalTestGet (New-AdapterGetParsed -Phrase $phrase -Code 'block_absent'))

        $rows.Count | Should -Be 1
        $rows[0].resource_name | Should -Be 'HostsFileCorp'
        $rows[0].result | Should -Be 'non_compliant'
        @($rows[0].reasons).Count | Should -Be 1
        $rows[0].reasons[0].code | Should -Be 'block_absent'
        $rows[0].reasons[0].code | Should -Not -Be 'synthetic'
        $rows[0].reasons[0].phrase | Should -Be $phrase
    }

    It 'falls back to the synthetic reason when the harvest is unavailable (null TestGet)' {
        $rows = @(Invoke-FinalStateEmit `
            -FinalTest (New-AdapterTestParsed -InDesiredState $false) `
            -FinalTestGet $null)

        $rows.Count | Should -Be 1
        $rows[0].resource_name | Should -Be 'HostsFileCorp'
        $rows[0].result | Should -Be 'non_compliant'
        @($rows[0].reasons).Count | Should -Be 1
        $rows[0].reasons[0].code | Should -Be 'synthetic'
        # The synthetic phrase is the projection's wrapper-drift text, never a post-set adapter phrase.
        $rows[0].reasons[0].phrase | Should -Not -BeNullOrEmpty
        $rows[0].reasons[0].phrase | Should -Not -Match 'present and matches'
    }
}

Describe 'Enforcement wires the convergence harvest into the emitted telemetry' {
    # The projection tests above hand -FinalTestGet straight to the emit helper, which proves the
    # projection but NOT that Invoke-Enforcement.ps1 actually sources it from $recovery.TestGet. That
    # single assignment IS the script-level half of the ADO 16372772 fix: with it reverted to $null
    # (or to a post-set get) the whole suite stayed green. These dot-source the real assignment, the
    # real bundle staging, and the real post-convergence emit, so that revert now fails here.

    It 'carries the pre-set harvest from recovery.TestGet onto the emitted non_compliant row' {
        $phrase = "Managed block 'Corp' drift: block not present; 155 missing"
        $recovery = [pscustomobject]@{
            TestGet = New-AdapterGetParsed -Phrase $phrase -Code 'block_absent'
        }

        $emit = Invoke-EnforcementWiringEmit -Recovery $recovery -ParsedTest (New-AdapterTestParsed -InDesiredState $false)

        $emit.Warnings | Should -BeNullOrEmpty
        $emit.HarvestedParsed | Should -Not -BeNullOrEmpty
        $emit.StagedGet | Should -Be $recovery.TestGet
        $emit.Rows.Count | Should -Be 1
        $emit.Rows[0].phase | Should -Be 'test'
        $emit.Rows[0].resource_name | Should -Be 'HostsFileCorp'
        $emit.Rows[0].result | Should -Be 'non_compliant'
        @($emit.Rows[0].reasons).Count | Should -Be 1
        $emit.Rows[0].reasons[0].code | Should -Be 'block_absent'
        $emit.Rows[0].reasons[0].code | Should -Not -Be 'synthetic'
        $emit.Rows[0].reasons[0].phrase | Should -Be $phrase
    }

    It 'emits the synthetic fallback through the same wiring when recovery.TestGet is null' {
        $recovery = [pscustomobject]@{ TestGet = $null }

        $emit = Invoke-EnforcementWiringEmit -Recovery $recovery -ParsedTest (New-AdapterTestParsed -InDesiredState $false)

        $emit.Warnings | Should -BeNullOrEmpty
        $emit.HarvestedParsed | Should -BeNullOrEmpty
        $emit.Rows.Count | Should -Be 1
        $emit.Rows[0].result | Should -Be 'non_compliant'
        @($emit.Rows[0].reasons).Count | Should -Be 1
        $emit.Rows[0].reasons[0].code | Should -Be 'synthetic'
    }

    It 'end-to-end: real convergence result feeds the real wiring so the row carries the PRE-set reason' {
        # Nothing hand-built between the seam and the row: real Invoke-FragmentConvergence produces
        # $recovery, real enforcement wiring stages it, real emit writes it. The set invoker flips the
        # harvest to the post-remediation "present and matches" envelope, so if the harvest ever moved
        # back after set -- the shipped defect -- this row would read "matches" against a
        # non_compliant verdict. It must read the pre-set drift reason instead.
        Mock -ModuleName Dsc.Recovery Write-NativeStderr {}
        $script:remediated = $false
        $preSet = New-AdapterGetParsed -Phrase 'Managed block not present; 155 entries missing' -Code 'block_absent'
        $postSet = New-AdapterGetParsed -Phrase 'Managed block is present and matches' -Code 'block_ok'

        $testInvoker = {
            param($ExePath, $ConfigFilePath)
            $null = $ExePath, $ConfigFilePath
            New-TestInvocation -InDesiredState $false
        }
        $getInvoker = {
            param($ExePath, $ConfigFilePath, $DriftedNames)
            $null = $ExePath, $ConfigFilePath, $DriftedNames
            if ($script:remediated) { return $postSet }
            return $preSet
        }
        $setInvoker = {
            param($ExePath, $ConfigFilePath, $ParsedTest)
            $null = $ExePath, $ConfigFilePath, $ParsedTest
            $script:remediated = $true
            New-SetResult
        }
        $verifyInvoker = {
            param($ExePath, $ConfigFilePath)
            $null = $ExePath, $ConfigFilePath
            New-TestInvocation -InDesiredState $true
        }

        $recovery = Invoke-FragmentConvergence -DscExePath $script:DscExe -ConfigFilePath $script:ConfigPath `
            -TestInvoker $testInvoker -TestGetInvoker $getInvoker `
            -SetInvoker $setInvoker -VerifyInvoker $verifyInvoker

        $recovery.Outcome | Should -Be 'converged'
        $script:remediated | Should -BeTrue

        $emit = Invoke-EnforcementWiringEmit -Recovery $recovery -ParsedTest (New-AdapterTestParsed -InDesiredState $false)

        $emit.Warnings | Should -BeNullOrEmpty
        $emit.Rows.Count | Should -Be 1
        $emit.Rows[0].result | Should -Be 'non_compliant'
        $emit.Rows[0].reasons[0].code | Should -Be 'block_absent'
        $emit.Rows[0].reasons[0].phrase | Should -Be 'Managed block not present; 155 entries missing'
        $emit.Rows[0].reasons[0].phrase | Should -Not -Match 'present and matches'
    }
}

Describe 'AuditOnly / WhatIf map to EnableSet through the real script expression' {
    # The other AuditOnly coverage passes -EnableSet $false directly, which skips the production
    # mapping. Get-EnableSetDecision dot-sources the ACTUAL `$enableSet = (-not $AuditOnly) -and
    # $PSCmdlet.ShouldProcess(...)` line out of Invoke-Enforcement.ps1 into a real advanced function,
    # so dropping the AuditOnly guard or inverting the ShouldProcess sense is caught here. Full-script
    # invocation is impractical -- the enforcement loop needs log dirs, the reboot inbox, host identity,
    # and a live dsc.exe -- so this isolates the single decision line and feeds its result to the real
    # convergence.
    BeforeEach {
        Mock -ModuleName Dsc.Recovery Write-NativeStderr {}
        $script:getCount = 0
        $script:setCount = 0

        $script:auditGetInvoker = {
            param($ExePath, $ConfigFilePath, $DriftedNames)
            $null = $ExePath, $ConfigFilePath, $DriftedNames
            $script:getCount++
            [pscustomobject]@{ HadErrors = $false; Results = @('reason') }
        }
        $script:auditSetInvoker = {
            param($ExePath, $ConfigFilePath, $ParsedTest)
            $null = $ExePath, $ConfigFilePath, $ParsedTest
            $script:setCount++
            New-SetResult
        }
        $script:auditTestInvoker = {
            param($ExePath, $ConfigFilePath)
            $null = $ExePath, $ConfigFilePath
            New-TestInvocation -InDesiredState $false
        }
        $script:auditVerifyInvoker = {
            param($ExePath, $ConfigFilePath)
            $null = $ExePath, $ConfigFilePath
            New-TestInvocation -InDesiredState $true
        }
    }

    It 'AuditOnly=$true yields EnableSet=$false: harvest runs once, set never runs' {
        $enableSet = Get-EnableSetDecision -AuditOnly $true
        $enableSet | Should -BeFalse

        $result = Invoke-FragmentConvergence -DscExePath $script:DscExe -ConfigFilePath $script:ConfigPath `
            -TestInvoker $script:auditTestInvoker -TestGetInvoker $script:auditGetInvoker `
            -SetInvoker $script:auditSetInvoker -EnableSet:$enableSet

        $script:getCount | Should -Be 1
        $script:setCount | Should -Be 0
        $result.Phase | Should -Be 'test'
        $result.Outcome | Should -Be 'converged'
    }

    It 'WhatIf declines ShouldProcess yields EnableSet=$false: harvest runs once, set never runs' {
        $enableSet = Get-EnableSetDecision -AuditOnly $false -WhatIf
        $enableSet | Should -BeFalse

        $result = Invoke-FragmentConvergence -DscExePath $script:DscExe -ConfigFilePath $script:ConfigPath `
            -TestInvoker $script:auditTestInvoker -TestGetInvoker $script:auditGetInvoker `
            -SetInvoker $script:auditSetInvoker -EnableSet:$enableSet

        $script:getCount | Should -Be 1
        $script:setCount | Should -Be 0
        $result.Phase | Should -Be 'test'
    }

    It 'not AuditOnly and ShouldProcess allows: EnableSet=$true drives set (positive control)' {
        $enableSet = Get-EnableSetDecision -AuditOnly $false
        $enableSet | Should -BeTrue

        $result = Invoke-FragmentConvergence -DscExePath $script:DscExe -ConfigFilePath $script:ConfigPath `
            -TestInvoker $script:auditTestInvoker -TestGetInvoker $script:auditGetInvoker `
            -SetInvoker $script:auditSetInvoker -VerifyInvoker $script:auditVerifyInvoker -EnableSet:$enableSet

        $script:getCount | Should -Be 1
        $script:setCount | Should -Be 1
        $result.Phase | Should -Be 'verify'
        $result.Outcome | Should -Be 'converged'
    }
}
