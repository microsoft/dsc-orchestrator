#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pester v5 reconciliation property suite for single-pass emit
    (Write-FinalStateResourceRecords in Dsc.JsonLog.psm1).
.DESCRIPTION
    Drives a REAL emit to a temp resources.jsonl (TestDrive, not the mocked CI boundary) and
    asserts the two reconciliation invariants:

      (a) COUNT IDENTITY -- total == compliant + non_compliant + failed + skipped + unevaluated, over the
          same five-bucket model Invoke-Enforcement.ps1 uses (Get-RealResourceSummary on the final-state
          parse + the quarantine split folded into failed/unevaluated). Mirrors the invariant at ~L1209.

      (b) ROW DEDUP -- keyed on (resource_name, phase, event) against the WRITTEN file. The final
          state emits exactly one `test` and one `verify` row per INNER resource and one set
          start/end per WRAPPER. The hazard caught is duplicate (name, phase, event) tuples ACROSS
          passes: a two-pass scenario fed through the single-emit path must NOT duplicate.

    Deliberately NOT asserted: "no name in two buckets / no name emitted twice". Rows are legitimately
    multi-phase (a remediated resource carries both a test and a verify row) and resource_name spans
    two namespaces (set/quarantine rows carry the WRAPPER name; test/verify rows carry the INNER name).
    Asserting a name partition would compare wrapper names to inner names -- wrong.

    Companion to the row-duplication characterization in Dsc.Recovery.Tests.ps1: that test
    pins the low-level Write-ResourceRecords primitive as append-only (calling it twice duplicates);
    this suite proves the CALLER now emits once.

    See scripts/dscv3/tests/README.md for the CI invocation contract.
#>

Set-StrictMode -Version Latest

BeforeAll {
    Set-StrictMode -Version Latest

    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ModuleRoot = Join-Path $script:RepoRoot 'src\agent\windows\Modules'
    # Write-FinalStateResourceRecords' call graph: ResultProjection (action map + inner projection +
    # summary), Reasons (reason phrases), HostContext (Get-HostIdentity), Lifecycle (set rows), JsonLog.
    Import-Module (Join-Path $script:ModuleRoot 'Dsc.HostContext.psm1') -Force
    Import-Module (Join-Path $script:ModuleRoot 'Dsc.ResultProjection.psm1') -Force
    Import-Module (Join-Path $script:ModuleRoot 'Dsc.Reasons.psm1') -Force
    Import-Module (Join-Path $script:ModuleRoot 'Dsc.Lifecycle.psm1') -Force
    Import-Module (Join-Path $script:ModuleRoot 'Dsc.JsonLog.psm1') -Force
    # Write-FragmentUnevaluatedRows enumerates declared resources (Get-DeclaredResources) from a YAML
    # fragment; the fixtures render those fragments for the culprit/collateral emit test.
    Import-Module (Join-Path $script:ModuleRoot 'Dsc.YamlLines.psm1') -Force
    . (Join-Path $script:RepoRoot 'tests\fixtures\Dsc.ConfigFilter.Fixtures.ps1')

    # Run-level constants shared by every emit (values are immaterial to reconciliation).
    $script:Schema  = '3.0'
    $script:RunId   = 'run-recon'
    $script:Trigger = 'scheduled'
    $script:TestTs  = '2026-06-15T00:00:00.000Z'
    $script:VerifyTs = '2026-06-15T00:05:00.000Z'

    # A flat (non-adapter) test entry: inner name == declared name, so resource_name is the entry name.
    function script:New-FlatEntry {
        param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][bool]$InDesired)
        $diff = if ($InDesired) { @() } else { @('Prop1') }
        [pscustomobject]@{
            name   = $Name
            type   = 'Test/Simple'
            result = [pscustomobject]@{ inDesiredState = $InDesired; differingProperties = $diff }
        }
    }

    # An adapter wrapper entry holding N inners. Wrapper name != inner names, so set rows (wrapper
    # namespace) and test/verify rows (inner namespace) never share a resource_name -- the 1:N seam.
    function script:New-AdapterEntry {
        param(
            [Parameter(Mandatory)][string]$Wrapper,
            [Parameter(Mandatory)][object[]]$Inners   # each: @{ Type; Name; InDesired }
        )
        $innerObjs = foreach ($i in $Inners) {
            [pscustomobject]@{
                type       = [string]$i.Type
                name       = [string]$i.Name
                properties = [pscustomobject]@{ InDesiredState = [bool]$i.InDesired }
            }
        }
        [pscustomobject]@{
            name   = $Wrapper
            type   = 'Microsoft.DSC/PowerShell'
            result = [pscustomobject]@{
                hadErrors   = $false
                actualState = [pscustomobject]@{ result = @($innerObjs) }
            }
        }
    }

    function script:New-ParsedResult {
        param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Entries)
        [pscustomobject]@{ HadErrors = $false; Results = @($Entries); Duration = 'PT0S' }
    }

    # Final-state single emit with the standard run-level params; verify rows only when -FinalVerify given.
    function script:Invoke-FinalEmit {
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][object]$FinalTest,
            [Parameter()][AllowNull()][object]$FinalVerify = $null
        )
        Write-FinalStateResourceRecords -FinalTest $FinalTest -FinalTestGet $null `
            -TestTimestamp $script:TestTs -TestTimings $null `
            -FinalVerify $FinalVerify -FinalVerifyGet $null -VerifyTimestamp $script:VerifyTs -VerifyTimings $null `
            -Trigger $script:Trigger -Path $Path -SchemaVersion $script:Schema -RunId $script:RunId `
            -ConfigVersion 'v1' -Group 'hp' -Role 'svc' -FragmentName 'Frag'
    }

    # One set start + end pair for a wrapper (the per-wrapper set-lifecycle markers).
    function script:Add-SetRows {
        param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Wrapper)
        Write-SetLifecycleEvent -Phase 'start' -RunTrigger $script:Trigger -Path $Path -SchemaVersion $script:Schema `
            -RunId $script:RunId -HostName 'host1' -Group 'hp' -Role 'svc' -ConfigVersion 'v1' `
            -ResourceName $Wrapper -Adapter 'Microsoft.DSC/PowerShell'
        Write-SetLifecycleEvent -Phase 'end' -RunTrigger $script:Trigger -Path $Path -SchemaVersion $script:Schema `
            -RunId $script:RunId -HostName 'host1' -Group 'hp' -Role 'svc' -ConfigVersion 'v1' `
            -ResourceName $Wrapper -Adapter 'Microsoft.DSC/PowerShell' -Result 'set_complete' -DurationIso 'PT1S'
    }

    # One wrapper-namespace 'unevaluated' row per quarantined resource (what the quarantine fold emits).
    function script:Add-QuarantineRow {
        param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Wrapper)
        Write-ResourceRecord -Path $Path -SchemaVersion $script:Schema -RunId $script:RunId -Timestamp $script:TestTs `
            -Computer 'host1' -Group 'hp' -Role 'svc' -ConfigVersion 'v1' -Trigger $script:Trigger -Phase 'test' `
            -Adapter 'Microsoft.DSC/PowerShell' -AdapterInstanceName $Wrapper -ResourceType 'Microsoft.DSC/PowerShell' `
            -ResourceName $Wrapper -Action 'test' -LifecycleEvent 'complete' -Result 'unevaluated' -HadErrors $true `
            -DurationSource 'inherited_from_run'
    }

    function script:Get-EmittedRows {
        param([Parameter(Mandatory)][string]$Path)
        if (-not (Test-Path -LiteralPath $Path)) { return @() }
        @(Get-Content -LiteralPath $Path | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    }

    function script:New-LogPath {
        Join-Path $TestDrive ('resources-{0}.jsonl' -f [guid]::NewGuid().ToString('N'))
    }
}

Describe 'Write-FinalStateResourceRecords reconciliation' {

    Context 'count identity and single-emit row dedup' {

        It 'flat resources, no set: one test row each; buckets reconcile' {
            $log = New-LogPath
            $test = New-ParsedResult -Entries @(
                New-FlatEntry -Name 'ResourceA' -InDesired $true
                New-FlatEntry -Name 'ResourceB' -InDesired $true
            )
            Invoke-FinalEmit -Path $log -FinalTest $test

            $rows = Get-EmittedRows -Path $log
            @($rows | Where-Object { $_.phase -eq 'test' }).Count   | Should -Be 2
            @($rows | Where-Object { $_.phase -eq 'verify' }).Count | Should -Be 0
            @($rows | Where-Object { $_.phase -eq 'set' }).Count    | Should -Be 0

            # (b) ROW DEDUP: every (resource_name, phase, event) tuple appears exactly once.
            $byKey = $rows | Group-Object { '{0}|{1}|{2}' -f $_.resource_name, $_.phase, $_.event }
            foreach ($g in $byKey) { $g.Count | Should -Be 1 }

            # (a) COUNT IDENTITY: no set ran -> final state is the test parse.
            $summary = Get-RealResourceSummary -ParsedTest $test
            $skipped = 0; $unevaluated = 0; $failed = 0   # survivors are never failed
            $total = $summary.TotalCountReal + $unevaluated
            $summary.Compliant    | Should -Be 2
            $summary.NonCompliant | Should -Be 0
            $total | Should -Be ($summary.Compliant + $summary.NonCompliant + $failed + $skipped + $unevaluated)
        }

        It 'adapter wrapper remediated: inner test+verify rows, wrapper set start/end; namespaces stay distinct' {
            $log = New-LogPath
            # Wrapper W holds 2 inners; both drift on test, both clean on verify (remediated).
            $test = New-ParsedResult -Entries @(
                New-AdapterEntry -Wrapper 'WrapperW' -Inners @(
                    @{ Type = 'Inner/A'; Name = 'inner1'; InDesired = $false }
                    @{ Type = 'Inner/B'; Name = 'inner2'; InDesired = $false }
                )
            )
            $verify = New-ParsedResult -Entries @(
                New-AdapterEntry -Wrapper 'WrapperW' -Inners @(
                    @{ Type = 'Inner/A'; Name = 'inner1'; InDesired = $true }
                    @{ Type = 'Inner/B'; Name = 'inner2'; InDesired = $true }
                )
            )
            Add-SetRows -Path $log -Wrapper 'WrapperW'
            Invoke-FinalEmit -Path $log -FinalTest $test -FinalVerify $verify

            $rows = Get-EmittedRows -Path $log
            @($rows | Where-Object { $_.phase -eq 'test' }).Count   | Should -Be 2
            @($rows | Where-Object { $_.phase -eq 'verify' }).Count | Should -Be 2
            @($rows | Where-Object { $_.phase -eq 'set' }).Count    | Should -Be 2

            # Inner-namespace rows carry the inner names; wrapper-namespace rows carry the wrapper name.
            @($rows | Where-Object { $_.phase -in @('test','verify') } | ForEach-Object { $_.resource_name } | Sort-Object -Unique) |
                Should -Be @('inner1', 'inner2')
            @($rows | Where-Object { $_.phase -eq 'set' } | ForEach-Object { $_.resource_name } | Sort-Object -Unique) |
                Should -Be @('WrapperW')

            # (b) ROW DEDUP across all rows: 6 distinct tuples (2 test + 2 verify + set start + set end).
            $byKey = $rows | Group-Object { '{0}|{1}|{2}' -f $_.resource_name, $_.phase, $_.event }
            @($byKey).Count | Should -Be 6
            foreach ($g in $byKey) { $g.Count | Should -Be 1 }

            # (a) COUNT IDENTITY: a set ran -> final state is the verify parse (survivor state).
            $summary = Get-RealResourceSummary -ParsedTest $verify
            $skipped = 0; $unevaluated = 0; $failed = 0   # survivors are never failed
            $total = $summary.TotalCountReal + $unevaluated
            $summary.Compliant    | Should -Be 2
            $summary.NonCompliant | Should -Be 0
            $total | Should -Be ($summary.Compliant + $summary.NonCompliant + $failed + $skipped + $unevaluated)
        }

        It 'verify shows residual drift: the non_compliant bucket reconciles' {
            $log = New-LogPath
            $test = New-ParsedResult -Entries @(
                New-AdapterEntry -Wrapper 'WrapperW' -Inners @(
                    @{ Type = 'Inner/A'; Name = 'inner1'; InDesired = $false }
                    @{ Type = 'Inner/B'; Name = 'inner2'; InDesired = $false }
                )
            )
            # Post-set: inner1 converged, inner2 still drifted (set did not fix it).
            $verify = New-ParsedResult -Entries @(
                New-AdapterEntry -Wrapper 'WrapperW' -Inners @(
                    @{ Type = 'Inner/A'; Name = 'inner1'; InDesired = $true }
                    @{ Type = 'Inner/B'; Name = 'inner2'; InDesired = $false }
                )
            )
            Add-SetRows -Path $log -Wrapper 'WrapperW'
            Invoke-FinalEmit -Path $log -FinalTest $test -FinalVerify $verify

            $rows = Get-EmittedRows -Path $log
            $byKey = $rows | Group-Object { '{0}|{1}|{2}' -f $_.resource_name, $_.phase, $_.event }
            foreach ($g in $byKey) { $g.Count | Should -Be 1 }

            $summary = Get-RealResourceSummary -ParsedTest $verify
            $skipped = 0; $unevaluated = 0; $failed = 0   # survivors are never failed
            $total = $summary.TotalCountReal + $unevaluated
            $summary.Compliant    | Should -Be 1
            $summary.NonCompliant | Should -Be 1
            $total | Should -Be ($summary.Compliant + $summary.NonCompliant + $failed + $skipped + $unevaluated)
        }

        It 'quarantine folds into unevaluated exactly once: buckets reconcile across namespaces' {
            $log = New-LogPath
            # Survivors {inner1,inner2} converge; the culprit wrapper is quarantined (1 unevaluated row).
            $test = New-ParsedResult -Entries @(
                New-AdapterEntry -Wrapper 'SurvivorW' -Inners @(
                    @{ Type = 'Inner/A'; Name = 'inner1'; InDesired = $false }
                    @{ Type = 'Inner/B'; Name = 'inner2'; InDesired = $false }
                )
            )
            $verify = New-ParsedResult -Entries @(
                New-AdapterEntry -Wrapper 'SurvivorW' -Inners @(
                    @{ Type = 'Inner/A'; Name = 'inner1'; InDesired = $true }
                    @{ Type = 'Inner/B'; Name = 'inner2'; InDesired = $true }
                )
            )
            Add-SetRows -Path $log -Wrapper 'SurvivorW'
            Invoke-FinalEmit -Path $log -FinalTest $test -FinalVerify $verify
            Add-QuarantineRow -Path $log -Wrapper 'CulpritW'   # fold quarantine union -> unevaluated, once

            $rows = Get-EmittedRows -Path $log
            @($rows | Where-Object { $_.result -eq 'unevaluated' }).Count | Should -Be 1
            $byKey = $rows | Group-Object { '{0}|{1}|{2}' -f $_.resource_name, $_.phase, $_.event }
            foreach ($g in $byKey) { $g.Count | Should -Be 1 }

            # (a) COUNT IDENTITY: total = survivor count + quarantine; quarantine is the unevaluated bucket.
            $summary = Get-RealResourceSummary -ParsedTest $verify
            $skipped = 0; $failed = 0   # survivors are never failed
            $unevaluated = @($rows | Where-Object { $_.result -eq 'unevaluated' }).Count
            $total = $summary.TotalCountReal + $unevaluated
            $summary.Compliant    | Should -Be 2
            $summary.NonCompliant | Should -Be 0
            $unevaluated          | Should -Be 1
            $total                | Should -Be 3
            $total | Should -Be ($summary.Compliant + $summary.NonCompliant + $failed + $skipped + $unevaluated)
        }
    }

    Context 'two-pass convergence emits only the final pass (no across-pass duplication)' {

        It 'a resource drifted in pass 1 AND pass 2 gets exactly one test and one verify row' {
            $log = New-LogPath
            # Two-pass run: pass 1 tests the survivor as drifted (intermediate), pass 2 is the FINAL pass
            # (drifted on test, clean on verify). The single-emit contract takes ONLY the final pass --
            # so the survivor must not accumulate a second test row from pass 1.
            $pass1Test = New-ParsedResult -Entries @(
                New-AdapterEntry -Wrapper 'WrapperW' -Inners @(@{ Type = 'Inner/A'; Name = 'inner1'; InDesired = $false })
            )
            $finalTest = New-ParsedResult -Entries @(
                New-AdapterEntry -Wrapper 'WrapperW' -Inners @(@{ Type = 'Inner/A'; Name = 'inner1'; InDesired = $false })
            )
            $finalVerify = New-ParsedResult -Entries @(
                New-AdapterEntry -Wrapper 'WrapperW' -Inners @(@{ Type = 'Inner/A'; Name = 'inner1'; InDesired = $true })
            )
            $null = $pass1Test   # pinned to document the discarded intermediate pass; never emitted

            Add-SetRows -Path $log -Wrapper 'WrapperW'
            Invoke-FinalEmit -Path $log -FinalTest $finalTest -FinalVerify $finalVerify

            $rows = Get-EmittedRows -Path $log
            # Exactly one test row and one verify row for the inner -- pass 1's test row never reached the file.
            @($rows | Where-Object { $_.resource_name -eq 'inner1' -and $_.phase -eq 'test' }).Count   | Should -Be 1
            @($rows | Where-Object { $_.resource_name -eq 'inner1' -and $_.phase -eq 'verify' }).Count | Should -Be 1

            # No (resource_name, phase, event) tuple is duplicated across the two passes.
            $byKey = $rows | Group-Object { '{0}|{1}|{2}' -f $_.resource_name, $_.phase, $_.event }
            foreach ($g in $byKey) { $g.Count | Should -Be 1 }
        }
    }

    Context 'dormant set-lifecycle buffer sink' {

        It 'with no sink, set rows stream to the file' {
            $log = New-LogPath
            Add-SetRows -Path $log -Wrapper 'WrapperW'
            $rows = Get-EmittedRows -Path $log
            @($rows | Where-Object { $_.phase -eq 'set' }).Count | Should -Be 2
        }

        It 'with a sink, set rows buffer into the list and the file is not written' {
            $log = New-LogPath
            $sink = [System.Collections.Generic.List[object]]::new()
            Write-SetLifecycleEvent -Phase 'start' -RunTrigger $script:Trigger -Path $log -SchemaVersion $script:Schema `
                -RunId $script:RunId -HostName 'host1' -Group 'hp' -Role 'svc' -ConfigVersion 'v1' `
                -ResourceName 'WrapperW' -Adapter 'Microsoft.DSC/PowerShell' -RecordSink $sink
            Write-SetLifecycleEvent -Phase 'end' -RunTrigger $script:Trigger -Path $log -SchemaVersion $script:Schema `
                -RunId $script:RunId -HostName 'host1' -Group 'hp' -Role 'svc' -ConfigVersion 'v1' `
                -ResourceName 'WrapperW' -Adapter 'Microsoft.DSC/PowerShell' -Result 'set_complete' -DurationIso 'PT1S' -RecordSink $sink

            $sink.Count | Should -Be 2
            Test-Path -LiteralPath $log | Should -BeFalse
        }
    }
}

Describe 'Get-FragmentBucketCounts reconciliation' {

    # Drives the SAME helper Invoke-Enforcement calls on its test- and verify-phase folds, proving the
    # 5-bucket invariant holds with the quarantine split counted exactly once even when both folds run.
    Context 'recover-then-remediate (set/verify aborts quarantine, survivors remediate)' {

        It 'counts the quarantine split once across the test fold AND the verify fold' {
            # Survivors drift on test, converge on verify; one culprit wrapper is quarantined (failed).
            $testParse = New-ParsedResult -Entries @(
                New-AdapterEntry -Wrapper 'SurvivorW' -Inners @(
                    @{ Type = 'Inner/A'; Name = 'inner1'; InDesired = $false }
                    @{ Type = 'Inner/B'; Name = 'inner2'; InDesired = $false }
                )
            )
            $verifyParse = New-ParsedResult -Entries @(
                New-AdapterEntry -Wrapper 'SurvivorW' -Inners @(
                    @{ Type = 'Inner/A'; Name = 'inner1'; InDesired = $true }
                    @{ Type = 'Inner/B'; Name = 'inner2'; InDesired = $true }
                )
            )
            $quarFailed = 1; $quarNonCompliant = 0; $quarUneval = 0

            # Test-phase fold then verify-phase fold, reusing the result var exactly as the body does.
            $buckets = Get-FragmentBucketCounts -SurvivorSummary (Get-RealResourceSummary -ParsedTest $testParse)   -QuarantineFailedCount $quarFailed -QuarantineNonCompliantCount $quarNonCompliant -QuarantineUnevaluatedCount $quarUneval
            $buckets = Get-FragmentBucketCounts -SurvivorSummary (Get-RealResourceSummary -ParsedTest $verifyParse) -QuarantineFailedCount $quarFailed -QuarantineNonCompliantCount $quarNonCompliant -QuarantineUnevaluatedCount $quarUneval

            $skipped = 0
            $buckets.Failed       | Should -Be 1   # quarantine culprit counted ONCE (regression guard for the double-fold)
            $buckets.Unevaluated  | Should -Be 0
            $buckets.Compliant    | Should -Be 2
            $buckets.NonCompliant | Should -Be 0
            $buckets.Total        | Should -Be 3   # 2 survivors + 1 quarantine culprit
            $buckets.Total | Should -Be ($buckets.Compliant + $buckets.NonCompliant + $buckets.Failed + $skipped + $buckets.Unevaluated)
        }

        It 'no quarantine: total is the survivor count and failed/unevaluated are zero' {
            $verifyParse = New-ParsedResult -Entries @(
                New-AdapterEntry -Wrapper 'SurvivorW' -Inners @(
                    @{ Type = 'Inner/A'; Name = 'inner1'; InDesired = $true }
                )
            )
            $buckets = Get-FragmentBucketCounts -SurvivorSummary (Get-RealResourceSummary -ParsedTest $verifyParse) -QuarantineFailedCount 0 -QuarantineNonCompliantCount 0 -QuarantineUnevaluatedCount 0

            $skipped = 0
            $buckets.Failed      | Should -Be 0
            $buckets.Unevaluated | Should -Be 0
            $buckets.Total       | Should -Be 1
            $buckets.Total | Should -Be ($buckets.Compliant + $buckets.NonCompliant + $buckets.Failed + $skipped + $buckets.Unevaluated)
        }
    }

    # The five buckets answer five distinct questions. The bucket = the CHECK VERDICT; had_errors is
    # orthogonal. Survivors are compliant/non_compliant by verdict (never failed); the quarantine split
    # routes by abort phase (test -> failed, set/verify -> non_compliant, collateral -> unevaluated).
    Context 'five-bucket classification (check-verdict model)' {

        It 'survivors are verdict-only; quarantine routes failed/non_compliant/unevaluated by phase' {
            # SurvivorW: one inner in state (compliant), one drifted (non_compliant) -- no survivor is failed.
            $verify = New-ParsedResult -Entries @(
                New-AdapterEntry -Wrapper 'SurvivorW' -Inners @(
                    @{ Type = 'Inner/A'; Name = 'innerOk';    InDesired = $true }
                    @{ Type = 'Inner/B'; Name = 'innerDrift'; InDesired = $false }
                )
            )
            $summary = Get-RealResourceSummary -ParsedTest $verify

            # Quarantine: test-abort culprit (failed) + set/verify-abort culprit (non_compliant) + collateral (unevaluated).
            $buckets = Get-FragmentBucketCounts -SurvivorSummary $summary `
                -QuarantineFailedCount 1 -QuarantineNonCompliantCount 1 -QuarantineUnevaluatedCount 1
            $skipped = 0

            $buckets.Compliant    | Should -Be 1
            $buckets.NonCompliant | Should -Be 2   # survivor drift (1) + set/verify-abort culprit (1)
            $buckets.Failed       | Should -Be 1   # test-abort culprit only (survivors never failed)
            $buckets.Unevaluated  | Should -Be 1   # dependsOn collateral
            $buckets.Total        | Should -Be 5   # 2 survivors + 3 quarantine

            # Every resource counted in exactly one bucket: total == c + nc + failed + unevaluated (+ skipped).
            $buckets.Total | Should -Be ($buckets.Compliant + $buckets.NonCompliant + $buckets.Failed + $skipped + $buckets.Unevaluated)

            # Only the survivor drift is listed in NonCompliantResources (quarantine rows are wrapper-namespace).
            @($buckets.NonCompliantList).Count   | Should -Be 1
            @($buckets.NonCompliantList)[0].name | Should -Be 'innerDrift'
        }
    }
}

Describe 'Get-RealResourceSummary verdict-only classification (check-verdict model)' {

    It 'an out-of-state inner is NonCompliant regardless of errors; survivors are never Failed' {
        $verify = New-ParsedResult -Entries @(
            New-AdapterEntry -Wrapper 'DriftW' -Inners @(@{ Type = 'Inner/A'; Name = 'innerD'; InDesired = $false })
            New-AdapterEntry -Wrapper 'OkW'    -Inners @(@{ Type = 'Inner/B'; Name = 'innerO'; InDesired = $true })
        )
        $summary = Get-RealResourceSummary -ParsedTest $verify

        $summary.Compliant      | Should -Be 1
        $summary.NonCompliant   | Should -Be 1
        $summary.TotalCountReal | Should -Be 2
        # No Failed field on the survivor summary -- survivors are never failed.
        @($summary.PSObject.Properties.Name) | Should -Not -Contain 'Failed'
        @($summary.NonCompliantResources).Count   | Should -Be 1
        @($summary.NonCompliantResources)[0].name | Should -Be 'innerD'
    }
}

Describe 'Write-FragmentUnevaluatedRows culprit/collateral split by abort phase (check-verdict model)' {

    BeforeAll {
        $script:FragCtx = @{
            SchemaVersion = $script:Schema; RunId = $script:RunId; Timestamp = $script:TestTs
            Computer = 'host1'; Group = 'hp'; Role = 'svc'; ConfigVersion = 'v1'; Trigger = $script:Trigger
        }
    }

    It 'a TEST-abort culprit is result=failed (+FailedCount); collateral is unevaluated' {
        $frag = Join-Path $TestDrive ('frag-{0}.dsc.yaml' -f [guid]::NewGuid().ToString('N'))
        New-DscConfigFile -Path $frag -Wrappers @(@{ Name = 'CulpritW' }, @{ Name = 'CollateralW' }) | Out-Null
        $log = New-LogPath

        # CulpritW aborted at TEST -> no verdict -> failed; CollateralW is the dependsOn collateral.
        $r = Write-FragmentUnevaluatedRows -FragmentName 'Frag' -FragmentPath $frag -Cause 'resource_resolution' `
            -Excerpt '' -NativeExitCode 2 -Context $script:FragCtx -ResourcesLogPath $log `
            -CulpritMap @{ 'CulpritW' = @{ Excerpt = 'boom'; Phase = 'test' } }

        $r.EmittedCount      | Should -Be 2
        $r.FailedCount       | Should -Be 1
        $r.NonCompliantCount | Should -Be 0
        $r.UnevaluatedCount  | Should -Be 1
        $r.Fallback          | Should -BeFalse

        $rows = Get-EmittedRows -Path $log
        $culprit = $rows | Where-Object { $_.resource_name -eq 'CulpritW-inner' }
        $culprit.result     | Should -Be 'failed'
        $culprit.had_errors | Should -BeTrue
        ($rows | Where-Object { $_.resource_name -eq 'CollateralW-inner' }).result | Should -Be 'unevaluated'
    }

    It 'a SET/VERIFY-abort culprit is result=non_compliant + had_errors (+NonCompliantCount); collateral is unevaluated' {
        $frag = Join-Path $TestDrive ('frag-{0}.dsc.yaml' -f [guid]::NewGuid().ToString('N'))
        New-DscConfigFile -Path $frag -Wrappers @(@{ Name = 'CulpritW' }, @{ Name = 'CollateralW' }) | Out-Null
        $log = New-LogPath

        # CulpritW aborted at SET -> it WAS evaluated as drifted at test -> non_compliant + had_errors.
        $r = Write-FragmentUnevaluatedRows -FragmentName 'Frag' -FragmentPath $frag -Cause 'resource_resolution' `
            -Excerpt '' -NativeExitCode 2 -Context $script:FragCtx -ResourcesLogPath $log `
            -CulpritMap @{ 'CulpritW' = @{ Excerpt = 'set boom'; Phase = 'set' } }

        $r.EmittedCount      | Should -Be 2
        $r.FailedCount       | Should -Be 0
        $r.NonCompliantCount | Should -Be 1
        $r.UnevaluatedCount  | Should -Be 1

        $rows = Get-EmittedRows -Path $log
        $culprit = $rows | Where-Object { $_.resource_name -eq 'CulpritW-inner' }
        $culprit.result           | Should -Be 'non_compliant'
        $culprit.had_errors       | Should -BeTrue
        $culprit.in_desired_state | Should -BeFalse
        ($rows | Where-Object { $_.resource_name -eq 'CollateralW-inner' }).result | Should -Be 'unevaluated'
    }

    It 'an unattributable crash (enumeration fails) stays unevaluated, never failed' {
        # Nonexistent fragment path -> Get-DeclaredResources throws -> single fallback row, unattributable.
        $missing = Join-Path $TestDrive ('missing-{0}.dsc.yaml' -f [guid]::NewGuid().ToString('N'))
        $log = New-LogPath

        $r = Write-FragmentUnevaluatedRows -FragmentName 'Frag' -FragmentPath $missing -Cause 'yaml_enum_failed' `
            -Excerpt 'enum boom' -NativeExitCode 9 -Context $script:FragCtx -ResourcesLogPath $log

        $r.Fallback          | Should -BeTrue
        $r.FailedCount       | Should -Be 0
        $r.NonCompliantCount | Should -Be 0
        $r.UnevaluatedCount  | Should -Be 1

        $rows = Get-EmittedRows -Path $log
        @($rows).Count    | Should -Be 1
        $rows[0].result   | Should -Be 'unevaluated'
    }
}

Describe 'Five-bucket invariant property: buckets reconcile against the written rows (check-verdict model)' {

    It 'a real mixed-phase quarantine emit + survivor summary: row results match the buckets' {
        $log = New-LogPath

        # Survivors: inner1 converged (compliant), inner2 still drifted with NO error (non_compliant).
        $verify = New-ParsedResult -Entries @(
            New-AdapterEntry -Wrapper 'SurvivorW' -Inners @(
                @{ Type = 'Inner/A'; Name = 'inner1'; InDesired = $true }
                @{ Type = 'Inner/B'; Name = 'inner2'; InDesired = $false }
            )
        )
        $test = New-ParsedResult -Entries @(
            New-AdapterEntry -Wrapper 'SurvivorW' -Inners @(
                @{ Type = 'Inner/A'; Name = 'inner1'; InDesired = $false }
                @{ Type = 'Inner/B'; Name = 'inner2'; InDesired = $false }
            )
        )
        Add-SetRows -Path $log -Wrapper 'SurvivorW'
        Invoke-FinalEmit -Path $log -FinalTest $test -FinalVerify $verify

        # A REAL quarantine emit spanning all three phases: a TEST-abort culprit (failed), a SET-abort
        # culprit (non_compliant), and dependsOn collateral (unevaluated).
        $frag = Join-Path $TestDrive ('frag-{0}.dsc.yaml' -f [guid]::NewGuid().ToString('N'))
        New-DscConfigFile -Path $frag -Wrappers @(@{ Name = 'TestCulpritW' }, @{ Name = 'SetCulpritW' }, @{ Name = 'CollateralW' }) | Out-Null
        $emit = Write-FragmentUnevaluatedRows -FragmentName 'Frag' -FragmentPath $frag -Cause 'resource_resolution' `
            -Excerpt '' -NativeExitCode 2 -Context $script:FragCtx -ResourcesLogPath $log -CulpritMap @{
                'TestCulpritW' = @{ Excerpt = 'test boom'; Phase = 'test' }
                'SetCulpritW'  = @{ Excerpt = 'set boom';  Phase = 'set' }
            }

        # Reconcile exactly as Invoke-Enforcement does: survivor summary + the quarantine three-way split.
        $summary = Get-RealResourceSummary -ParsedTest $verify
        $buckets = Get-FragmentBucketCounts -SurvivorSummary $summary `
            -QuarantineFailedCount $emit.FailedCount -QuarantineNonCompliantCount $emit.NonCompliantCount -QuarantineUnevaluatedCount $emit.UnevaluatedCount
        $skipped = 0

        # (a) The five-bucket invariant holds on the reconciled counts.
        $buckets.Total | Should -Be ($buckets.Compliant + $buckets.NonCompliant + $buckets.Failed + $skipped + $buckets.Unevaluated)
        $buckets.Compliant    | Should -Be 1
        $buckets.NonCompliant | Should -Be 2   # survivor drift (1) + set-abort culprit (1)
        $buckets.Failed       | Should -Be 1   # test-abort culprit only
        $buckets.Unevaluated  | Should -Be 1
        $buckets.Total        | Should -Be 5

        # (b) The WRITTEN rows back the buckets: 'failed' appears ONLY for the no-verdict test-abort row,
        # so the failed-result row count equals the failed bucket; same for unevaluated.
        $rows = Get-EmittedRows -Path $log
        @($rows | Where-Object { $_.result -eq 'failed' }).Count      | Should -Be $buckets.Failed
        @($rows | Where-Object { $_.result -eq 'unevaluated' }).Count | Should -Be $buckets.Unevaluated
        # The only failed row is the test-abort culprit (no survivor row carries result=failed).
        @($rows | Where-Object { $_.result -eq 'failed' })[0].resource_name | Should -Be 'TestCulpritW-inner'
    }
}
