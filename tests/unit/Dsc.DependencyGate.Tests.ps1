#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pester v5 suite for the DSCv3 cross-fragment dependency gate (AB#16393610).
.DESCRIPTION
    Pins the enforce-mode blocking contract so a fragment with explicit dependsOn is skipped when a
    named dependency does not strictly succeed, and the block telemetry names both the dependency and
    its terminal status:

      AC1  A dependency that ends failed / non_compliant / unevaluated blocks its dependent.
      AC2  Blocking propagates transitively (a skipped fragment blocks its own dependents).
      AC3  A fragment with no dependency on the failed one is unaffected.
      AC4  Get-BlockedByDetail reports each blocking dependency's terminal status.
      AC6  AuditOnly never gates.

    Also pins the exit-0 per-resource-error guard (Test-ParsedTestHadResourceErrors): an adapter
    envelope reporting result.hadErrors while its inner results omit InDesiredState is scored
    compliant by Get-ResourceCompliance, so without the guard a fragment whose only failure signal is
    a per-resource error would pass the success gate and fail to block its dependents.

    See scripts/dscv3/tests/README.md for the CI invocation contract.
#>

Set-StrictMode -Version Latest

BeforeAll {
    Set-StrictMode -Version Latest

    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ModuleRoot = Join-Path $script:RepoRoot 'src\agent\windows\Modules'
    # Import through the production surface exactly as Invoke-Enforcement.ps1 does: the aggregate
    # manifest (Dsc.Toolkit.psd1) plus the runtime module imported directly. This validates
    # FunctionsToExport — importing the leaf .psm1 directly would mask a missing manifest export.
    Import-Module (Join-Path $script:ModuleRoot 'Dsc.Toolkit.psd1') -Force -DisableNameChecking
    Import-Module (Join-Path $script:ModuleRoot 'Dsc.Runtime.Dependencies.psm1') -Force

    function script:New-GateTracker {
        param([Parameter(Mandatory)][string[]]$Names)
        $t = New-FragmentStatusTracker
        foreach ($n in $Names) { Initialize-FragmentStatus -Tracker $t -FragmentName $n }
        return $t
    }

    # Mark a fragment as a strict success (Evaluated, no error flags) so it does NOT block dependents.
    function script:Set-Succeeded {
        param([Parameter(Mandatory)]$Tracker, [Parameter(Mandatory)][string]$Name)
        $s = Get-FragmentStatus -Tracker $Tracker -FragmentName $Name
        $s.Evaluated = $true
        Set-FragmentTerminalStatus -Status $s -Value 'compliant'
    }

    # An adapter wrapper whose inner resource carries result.hadErrors but no InDesiredState — the
    # exact shape that Get-ResourceCompliance scores compliant (the exit-0 hole).
    function script:New-ErroredAdapterEntry {
        param([string]$InnerName = 'HostsFileCorp', [bool]$HadErrors = $true)
        [pscustomobject]@{
            name   = 'HostsWrapper'
            type   = 'Microsoft.DSC/PowerShell'
            result = [pscustomobject]@{
                hadErrors   = $HadErrors
                actualState = [pscustomobject]@{
                    result = @(
                        [pscustomobject]@{ type = 'Corp/Hosts'; name = $InnerName; properties = [pscustomobject]@{} }
                    )
                }
            }
        }
    }
}

Describe 'Dependency gate — Test-ShouldSkipDueToDependency' {

    It 'does not skip a fragment with no dependencies' {
        $t = New-GateTracker -Names @('A')
        Test-ShouldSkipDueToDependency -Tracker $t -DependsOn @() -AuditOnly:$false | Should -BeFalse
    }

    It 'does not skip when the dependency strictly succeeded (AC3)' {
        $t = New-GateTracker -Names @('Dep', 'App')
        Set-Succeeded -Tracker $t -Name 'Dep'
        Test-ShouldSkipDueToDependency -Tracker $t -DependsOn @('Dep') -AuditOnly:$false | Should -BeFalse
    }

    It 'skips when the dependency is unevaluated — never got a verdict (AC1)' {
        # Default-initialized status = Evaluated:$false, the state a parse/module failure leaves.
        $t = New-GateTracker -Names @('HostsFileCorp', 'AgentHealthCheck')
        Test-ShouldSkipDueToDependency -Tracker $t -DependsOn @('HostsFileCorp') -AuditOnly:$false | Should -BeTrue
    }

    It 'skips when the dependency ended failed — had errors (AC1)' {
        $t = New-GateTracker -Names @('Dep', 'App')
        $s = Get-FragmentStatus -Tracker $t -FragmentName 'Dep'
        $s.Evaluated = $true; $s.HadErrors = $true
        Test-ShouldSkipDueToDependency -Tracker $t -DependsOn @('Dep') -AuditOnly:$false | Should -BeTrue
    }

    It 'skips when the dependency ended non_compliant — drift persisted (AC1)' {
        $t = New-GateTracker -Names @('Dep', 'App')
        $s = Get-FragmentStatus -Tracker $t -FragmentName 'Dep'
        $s.Evaluated = $true; $s.FinalNonCompliantCount = 2
        Test-ShouldSkipDueToDependency -Tracker $t -DependsOn @('Dep') -AuditOnly:$false | Should -BeTrue
    }

    It 'skips only when at least one of several dependencies did not succeed' {
        $t = New-GateTracker -Names @('Good', 'Bad', 'App')
        Set-Succeeded -Tracker $t -Name 'Good'   # Bad left unevaluated
        Test-ShouldSkipDueToDependency -Tracker $t -DependsOn @('Good', 'Bad') -AuditOnly:$false | Should -BeTrue
    }

    It 'propagates the block transitively through a skipped fragment (AC2)' {
        # A fails -> B (dependsOn A) is skipped -> C (dependsOn B) must also be blocked.
        $t = New-GateTracker -Names @('A', 'B', 'C')
        $a = Get-FragmentStatus -Tracker $t -FragmentName 'A'
        $a.Evaluated = $true; $a.HadErrors = $true                 # A failed
        Test-ShouldSkipDueToDependency -Tracker $t -DependsOn @('A') -AuditOnly:$false | Should -BeTrue
        # B was skipped: telemetry 'skipped' but Evaluated stays $false, so it cannot satisfy C's gate.
        Set-FragmentTerminalStatus -Status (Get-FragmentStatus -Tracker $t -FragmentName 'B') -Value 'skipped'
        Test-ShouldSkipDueToDependency -Tracker $t -DependsOn @('B') -AuditOnly:$false | Should -BeTrue
    }

    It 'never gates in AuditOnly mode, even with a failed dependency (AC6)' {
        $t = New-GateTracker -Names @('Dep', 'App')
        $s = Get-FragmentStatus -Tracker $t -FragmentName 'Dep'
        $s.Evaluated = $true; $s.HadErrors = $true
        Test-ShouldSkipDueToDependency -Tracker $t -DependsOn @('Dep') -AuditOnly:$true | Should -BeFalse
    }
}

Describe 'Dependency gate — block telemetry (Get-BlockedByDetail) (AC4)' {

    It 'omits dependencies that strictly succeeded' {
        $t = New-GateTracker -Names @('Dep', 'App')
        Set-Succeeded -Tracker $t -Name 'Dep'
        $detail = Get-BlockedByDetail -Tracker $t -DependsOn @('Dep')
        @($detail).Count | Should -Be 0
    }

    It 'reports the blocking dependency name and its terminal status' {
        $t = New-GateTracker -Names @('HostsFileCorp', 'App')
        $detail = @(Get-BlockedByDetail -Tracker $t -DependsOn @('HostsFileCorp'))
        $detail.Count | Should -Be 1
        $detail[0].name   | Should -Be 'HostsFileCorp'
        $detail[0].status | Should -Be 'unevaluated'
    }

    It 'surfaces distinct terminal statuses per blocking dependency' {
        $t = New-GateTracker -Names @('Failed', 'Drifted', 'Skipped', 'Ok', 'App')
        $f = Get-FragmentStatus -Tracker $t -FragmentName 'Failed';  $f.Evaluated = $true; $f.HadErrors = $true
        $d = Get-FragmentStatus -Tracker $t -FragmentName 'Drifted'; $d.Evaluated = $true; $d.FinalNonCompliantCount = 1
        Set-FragmentTerminalStatus -Status (Get-FragmentStatus -Tracker $t -FragmentName 'Skipped') -Value 'skipped'
        Set-Succeeded -Tracker $t -Name 'Ok'

        $detail = Get-BlockedByDetail -Tracker $t -DependsOn @('Failed', 'Drifted', 'Skipped', 'Ok')
        @($detail | ForEach-Object { $_.name }) | Should -Not -Contain 'Ok'
        ($detail | Where-Object { $_.name -eq 'Failed' }).status  | Should -Be 'failed'
        ($detail | Where-Object { $_.name -eq 'Drifted' }).status | Should -Be 'non_compliant'
        ($detail | Where-Object { $_.name -eq 'Skipped' }).status | Should -Be 'skipped'
    }
}

Describe 'Dependency gate — terminal status resolution' {

    It 'returns the explicit terminal status when one is set' {
        $t = New-GateTracker -Names @('X')
        $s = Get-FragmentStatus -Tracker $t -FragmentName 'X'
        Set-FragmentTerminalStatus -Status $s -Value 'skipped'
        Resolve-FragmentTerminalStatus -Status $s | Should -Be 'skipped'
    }

    It 'derives failed / non_compliant / unevaluated / compliant from flags when unset' {
        $t = New-GateTracker -Names @('U', 'F', 'N', 'C')
        Resolve-FragmentTerminalStatus -Status (Get-FragmentStatus -Tracker $t -FragmentName 'U') | Should -Be 'unevaluated'

        $f = Get-FragmentStatus -Tracker $t -FragmentName 'F'; $f.Evaluated = $true; $f.HadErrors = $true
        Resolve-FragmentTerminalStatus -Status $f | Should -Be 'failed'

        $n = Get-FragmentStatus -Tracker $t -FragmentName 'N'; $n.Evaluated = $true; $n.FinalNonCompliantCount = 1
        Resolve-FragmentTerminalStatus -Status $n | Should -Be 'non_compliant'

        $c = Get-FragmentStatus -Tracker $t -FragmentName 'C'; $c.Evaluated = $true
        Resolve-FragmentTerminalStatus -Status $c | Should -Be 'compliant'
    }

    It 'rejects an invalid terminal status value' {
        $t = New-GateTracker -Names @('X')
        $s = Get-FragmentStatus -Tracker $t -FragmentName 'X'
        { Set-FragmentTerminalStatus -Status $s -Value 'bogus' } | Should -Throw
    }
}

Describe 'Exit-0 per-resource-error guard (Test-ParsedTestHadResourceErrors) (B2)' {

    It 'confirms the hole: an errored adapter entry without InDesiredState scores compliant' {
        $entry = New-ErroredAdapterEntry
        (Get-ResourceCompliance -Entry $entry).InDesiredState | Should -BeTrue
    }

    It 'detects the per-resource error the compliance scorer misses' {
        $parsed = [pscustomobject]@{
            HadErrors = $false   # top-level clean; exit 0 assumed
            Results   = @(
                [pscustomobject]@{ name = 'Ok'; type = 'Test/Simple'; result = [pscustomobject]@{ inDesiredState = $true } }
                (New-ErroredAdapterEntry)
            )
            Duration  = 'PT0S'
        }
        Test-ParsedTestHadResourceErrors -ParsedTest $parsed | Should -BeTrue
    }

    It 'detects an inner adapter resource error when the wrapper reports no error' {
        # Wrapper hadErrors=$false but an inner resource failed — the wrapper-only check would miss it.
        $entry = [pscustomobject]@{
            name   = 'HostsWrapper'
            type   = 'Microsoft.DSC/PowerShell'
            result = [pscustomobject]@{
                hadErrors   = $false
                actualState = [pscustomobject]@{
                    result = @(
                        [pscustomobject]@{ type = 'Corp/Hosts'; name = 'HostsFileCorp'; hadErrors = $true; properties = [pscustomobject]@{} }
                    )
                }
            }
        }
        Test-ParsedTestHadResourceErrors -ParsedTest ([pscustomobject]@{ Results = @($entry) }) | Should -BeTrue
    }

    It 'returns false when no resource reported an error' {
        $parsed = [pscustomobject]@{
            HadErrors = $false
            Results   = @(
                [pscustomobject]@{ name = 'Ok'; type = 'Test/Simple'; result = [pscustomobject]@{ inDesiredState = $true } }
                (New-ErroredAdapterEntry -HadErrors:$false)
            )
            Duration  = 'PT0S'
        }
        Test-ParsedTestHadResourceErrors -ParsedTest $parsed | Should -BeFalse
    }

    It 'returns false for an empty result set' {
        Test-ParsedTestHadResourceErrors -ParsedTest ([pscustomobject]@{ Results = @() }) | Should -BeFalse
    }
}

Describe 'Production module surface (Dsc.Toolkit.psd1 exports)' {

    It 'exports the per-resource-error guard the enforcement gate calls' {
        # Would fail if Test-ParsedTestHadResourceErrors were missing from FunctionsToExport, i.e. the
        # exact regression class where every fragment throws at the gate call and falls into the catch.
        Get-Command -Name 'Test-ParsedTestHadResourceErrors' -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'exports the skip-row emitter' {
        Get-Command -Name 'Write-FragmentSkippedRows' -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'Skip-row telemetry serialization (Write-FragmentSkippedRows) (AC4)' {

    BeforeAll {
        $script:SkipCtx = @{
            SchemaVersion = '3.0'; RunId = 'run-skip'; Timestamp = '2026-07-14T00:00:00.000Z'
            Computer = 'C'; Group = 'H'; Role = 'S'; ConfigVersion = 'v'; Trigger = 'scheduled'
        }
    }

    It 'records blockedByDetail with name and terminal status for a small dependency list' {
        $log = Join-Path $TestDrive 'skip-small.jsonl'
        $detail = @([pscustomobject]@{ name = 'HostsFileCorp'; status = 'unevaluated' })
        # Bogus FragmentPath forces the single-row fallback (no YAML fixture needed).
        Write-FragmentSkippedRows -FragmentName 'AgentHealthCheck' -FragmentPath (Join-Path $TestDrive 'none.dsc.yaml') `
            -BlockedBy @('HostsFileCorp') -BlockedByDetail $detail -Context $script:SkipCtx -ResourcesLogPath $log | Out-Null
        $row = Get-Content -LiteralPath $log | Select-Object -First 1 | ConvertFrom-Json
        $msg = $row.error_message | ConvertFrom-Json
        $msg.tag                     | Should -Be 'fragment_skipped'
        $msg.blockedBy               | Should -Contain 'HostsFileCorp'
        $msg.blockedByDetail[0].name   | Should -Be 'HostsFileCorp'
        $msg.blockedByDetail[0].status | Should -Be 'unevaluated'
    }

    It 'stays valid JSON and within budget under a huge dependency list' {
        $log = Join-Path $TestDrive 'skip-huge.jsonl'
        $names  = 1..200 | ForEach-Object { "Fragment-With-A-Deliberately-Long-Name-Number-$_" }
        $detail = $names | ForEach-Object { [pscustomobject]@{ name = $_; status = 'unevaluated' } }
        Write-FragmentSkippedRows -FragmentName 'AgentHealthCheck' -FragmentPath (Join-Path $TestDrive 'none.dsc.yaml') `
            -BlockedBy $names -BlockedByDetail $detail -Context $script:SkipCtx -ResourcesLogPath $log | Out-Null
        $msg = (Get-Content -LiteralPath $log | Select-Object -First 1 | ConvertFrom-Json).error_message
        $msg.Length | Should -BeLessOrEqual 2000
        # Must parse as valid JSON — a substringed payload would throw here.
        { $msg | ConvertFrom-Json } | Should -Not -Throw
        ($msg | ConvertFrom-Json).tag | Should -Be 'fragment_skipped'
    }
}
