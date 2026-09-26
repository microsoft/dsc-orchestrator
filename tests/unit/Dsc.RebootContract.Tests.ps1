#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pester v5 unit suite for the orchestrator-owned reboot READ+HANDLE side: Dsc.Reboot.psm1, and
    the reboot-decision logic wired inline into Invoke-Enforcement.ps1 (resume classification,
    cap/latch gate, outcome derivation, terminal retire/latch branch, unreached-fragment
    accounting). The suite exercises the Orchestrator-owned Request-DscReboot writer and the agent's
    registry reader against an isolated TestRegistry:\ drive.
.DESCRIPTION
    This suite tests the REAL implementation, not a harness reimplementation of it. Logic that
    lives in importable functions (Dsc.Reboot.psm1) is called directly.
    Logic that lives inline in Invoke-Enforcement.ps1 with no callable seam (resume/stale-sentinel
    classification, the cap/latch request-detection gate, the outcome-derivation override, the
    terminal latch/retire branch, the post-loop unreached-fragment accounting) is exercised by
    dot-sourcing the exact, anchor-located source text out of the real script file
    (Get-EnforcementSnippet) and running it in a controlled local scope -- so a real regression in
    that inline logic fails these tests, the same as a regression in an importable function would.

    Registry-touching functions always take an explicit -RegistryRoot pointed at a fresh
    TestRegistry:\ subkey (New-RegRoot) -- this suite never touches real HKLM. restart-state.json
    fixtures live under TestDrive:\.

    Invoke-OrchestratorRebootFinalize's internal step ordering (1: restart-state write, 2: clear
    registry inbox, 3: sentinel, 4: reboot-in-progress marker, 5: run summary append, 6: rebooter)
    is pinned via the -StepRecorder injection seam, asserted by recorded index -- not just "all
    complete before the rebooter fires".

    See tests/README.md for the test invocation contract.
#>

Set-StrictMode -Version Latest

BeforeAll {
    Set-StrictMode -Version Latest

    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:AgentRoot = Join-Path $script:RepoRoot 'src\agent\windows'
    $script:ModuleRoot = Join-Path $script:AgentRoot 'Modules'
    $script:EnforcementScriptPath = Join-Path $script:AgentRoot 'Invoke-Enforcement.ps1'
    $script:RebootContractPath = Join-Path $script:RepoRoot 'docs\operations\reboot-requests.md'

    Import-Module (Join-Path $script:ModuleRoot 'Dsc.Toolkit.psd1') -Force -DisableNameChecking

    $script:EnforcementSourceLinesCache = $null

    # ---- Generic fixtures / helpers -----------------------------------------------------------

    function script:New-RegRoot {
        # A fresh TestRegistry:\ subkey per call -- never touches real HKLM.
        Join-Path 'TestRegistry:\' ("Reboot-" + [Guid]::NewGuid().ToString('N'))
    }

    function script:Write-RestartState {
        param(
            [Parameter(Mandatory)][string]$Path,
            [string]$EnforcementId = 'enforcement-1',
            [string]$ConfigVersion = '1.0.0',
            [bool]$RebootPending = $true,
            [string]$PreRebootBootId = '2026-01-01T00:00:00.0000000Z',
            [bool]$LoopLatched = $false,
            [int]$RebootCount = 1,
            [string]$RebootKind = 'Immediate',
            [string]$RebootRequestedBy = 'Requester1',
            [string]$PreRebootRunId = 'run-1',
            [string]$InitiatedAt = '2026-01-01T00:00:01.0000000Z',
            [object[]]$Requesters
        )
        if ($null -eq $Requesters) {
            $Requesters = @(
                [ordered]@{ requester_id = $RebootRequestedBy; kind = $RebootKind; request_count = 1; last_requested_at = $InitiatedAt }
            )
        }
        $record = [ordered]@{
            schema_version      = '1.1'
            enforcement_id          = $EnforcementId
            config_version      = $ConfigVersion
            reboot_pending      = $RebootPending
            pre_reboot_boot_id  = $PreRebootBootId
            loop_latched        = $LoopLatched
            reboot_count        = $RebootCount
            reboot_kind         = $RebootKind
            reboot_requested_by = $RebootRequestedBy
            pre_reboot_run_id   = $PreRebootRunId
            initiated_at        = $InitiatedAt
            requesters          = $Requesters
        }
        $dir = Split-Path -Parent $Path
        if (-not [string]::IsNullOrEmpty($dir) -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        ($record | ConvertTo-Json -Depth 10 -Compress) | Set-Content -LiteralPath $Path -Encoding utf8 -Force
    }

    function script:Get-EmittedRows {
        # Bug fix (empty-pipeline collapse): a unary-comma return guarantees the caller always
        # gets a real (possibly zero-length) array, never $null, regardless of row count.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSReviewUnusedParameter', '',
            Justification = '$RunId is referenced from the Where-Object script-block closure; PSSA cannot follow closure-captured usage.'
        )]
        param([Parameter(Mandatory)][string]$Path, [string]$RunId = '')
        if (-not (Test-Path -LiteralPath $Path)) { return ,@() }
        $lines = @(Get-Content -LiteralPath $Path)
        $parsed = @(
            $lines | ForEach-Object { $_ | ConvertFrom-Json } |
                Where-Object { [string]::IsNullOrEmpty($RunId) -or $_.run_id -eq $RunId }
        )
        return ,$parsed
    }

    function script:New-RebootRunSummaryArgs {
        param([hashtable]$Overrides = @{})
        $base = @{
            Group = 'pool-1'; Role = 'svc-1'; DscExeVersion = '1.0.0'
            Mode = 'enforce'; Trigger = 'scheduled'
            TotalResources = 5; CompliantResources = 5; NonCompliantCount = 0
            FailedCount = 0; SkippedCount = 0; UnevaluatedCount = 0
            HadErrors = $false
            TestDuration = 'PT1S'; SetDuration = 'PT0S'; VerifyDuration = 'PT1S'; TotalDuration = 'PT2S'
            ExitCode = 0; ErrorMessage = ''
            NonCompliantResources = @(); ErroringResources = @()
        }
        foreach ($k in $Overrides.Keys) { $base[$k] = $Overrides[$k] }
        return $base
    }

    function script:New-FinalizeArgs {
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][string]$RegistryRoot,
            [Parameter(Mandatory)][string]$SentinelPath,
            [Parameter(Mandatory)][string]$RebootInProgressPath,
            [Parameter(Mandatory)][string]$RunsLogPath,
            [string]$EnforcementId = 'enforcement-1',
            [string]$ConfigVersion = '1.0.0',
            [string]$RunId = 'run-1',
            [string]$RequestedBy = 'Requester1',
            [ValidateSet('Immediate', 'Eventual')][string]$Kind = 'Immediate',
            [int]$IncomingRebootCount = 0,
            [hashtable]$RunSummaryArgs,
            [scriptblock]$Rebooter,
            [scriptblock]$Clock,
            [scriptblock]$Exit
        )
        $bag = @{
            Path = $Path; RegistryRoot = $RegistryRoot; SentinelPath = $SentinelPath
            RebootInProgressPath = $RebootInProgressPath; RunsLogPath = $RunsLogPath
            EnforcementId = $EnforcementId; ConfigVersion = $ConfigVersion; RunId = $RunId
            RequestedBy = $RequestedBy; Kind = $Kind; IncomingRebootCount = $IncomingRebootCount
            RunSummaryArgs = if ($RunSummaryArgs) { $RunSummaryArgs } else { New-RebootRunSummaryArgs }
        }
        if ($Rebooter) { $bag.Rebooter = $Rebooter }
        if ($Clock) { $bag.Clock = $Clock }
        if ($Exit) { $bag.Exit = $Exit }
        return $bag
    }

    # ---- "Dot-source the real orchestrator snippet" technique ---------------------------------
    # Invoke-Enforcement.ps1 has several decision blocks with no callable seam (cap/latch gate,
    # resume/stale-sentinel classification, outcome-derivation override, terminal latch/retire,
    # unreached-fragment accounting). Rather than reimplement that logic in a test harness (which
    # would pass regardless of real correctness), these helpers extract the EXACT source text
    # between two anchor strings out of the real file and dot-source it, so a real regression
    # there fails these tests exactly like a regression in an importable function would.

    function script:Get-EnforcementSourceLines {
        if ($null -eq $script:EnforcementSourceLinesCache) {
            $script:EnforcementSourceLinesCache = @(Get-Content -LiteralPath $script:EnforcementScriptPath)
        }
        return $script:EnforcementSourceLinesCache
    }

    function script:Get-EnforcementSnippet {
        param(
            [Parameter(Mandatory)][string]$StartAnchor,
            [string]$EndAnchor = ''
        )
        $lines = Get-EnforcementSourceLines
        $startIdx = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i].Contains($StartAnchor)) { $startIdx = $i; break }
        }
        if ($startIdx -lt 0) {
            throw "Get-EnforcementSnippet: start anchor not found in Invoke-Enforcement.ps1 -- orchestrator shape changed: '$StartAnchor'"
        }
        if ([string]::IsNullOrEmpty($EndAnchor)) {
            return $lines[$startIdx]
        }
        $endIdx = -1
        for ($i = $startIdx + 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i].Contains($EndAnchor)) { $endIdx = $i; break }
        }
        if ($endIdx -lt 0) {
            throw "Get-EnforcementSnippet: end anchor not found in Invoke-Enforcement.ps1 -- orchestrator shape changed: '$EndAnchor'"
        }
        return ($lines[$startIdx..($endIdx - 1)] -join "`n")
    }

    # Sentinel helpers (Update-RunSentinel / Remove-RunSentinel) are real functions used by the
    # resume-classification snippet; extract + script-scope them once, file-wide.
    $sentinelSrc = (Get-EnforcementSnippet -StartAnchor 'function Update-RunSentinel {' -EndAnchor '$currentDir   = Join-Path') `
        -replace 'function Update-RunSentinel \{', 'function script:Update-RunSentinel {' `
        -replace 'function Remove-RunSentinel \{', 'function script:Remove-RunSentinel {'
    . ([scriptblock]::Create($sentinelSrc))

    function script:Invoke-RealResumeClassification {
        <#
        Dot-sources the real resume/override classification + stale-sentinel-suppression block
        (Invoke-Enforcement.ps1 ~L307-403) into this function's own local scope, after resetting
        the $script:Reboot* state exactly as the real top-of-script init block does.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSReviewUnusedParameter', '',
            Justification = 'Params are referenced by name from the real Invoke-Enforcement.ps1 source text dot-sourced via [scriptblock]::Create($src); PSSA cannot follow usage inside a runtime-built scriptblock.'
        )]
        param(
            [Parameter(Mandatory)][string]$LogDir,
            [Parameter(Mandatory)][string]$configVersion,
            [Parameter(Mandatory)][string]$runsLog,
            [string]$runsSchemaVersion = '3.0',
            [string]$group = 'pool-1',
            [string]$role = 'svc-1',
            [AllowNull()][string]$configurationHash = $null,
            [string]$dscExeVersion = '1.0.0',
            [string]$mode = 'enforce',
            [string]$RunTrigger = 'scheduled'
        )
        $script:RebootEnforcementId           = ''
        $script:RebootCountIncoming       = 0
        $script:RebootLoopLatchedIncoming = $false
        $script:RebootEnforcementActive       = $false
        $script:RebootPending             = $false
        $script:RebootLoopLatched         = $false
        $script:RebootKind                = ''
        $script:RebootRequestedBy         = ''
        $resumedThisRun = $false

        $src = Get-EnforcementSnippet -StartAnchor '# Resume/override classification:' -EndAnchor '# Publish Context + wipe the inbox'
        . ([scriptblock]::Create($src))

        [pscustomobject]@{
            EnforcementId         = $script:RebootEnforcementId
            EnforcementActive     = $script:RebootEnforcementActive
            CountIncoming     = $script:RebootCountIncoming
            LoopLatchedIncoming = $script:RebootLoopLatchedIncoming
            ResumedThisRun    = $resumedThisRun
            RestartStatePath  = $restartStatePath
            StaleSentinelPath = $staleSentinelPath
        }
    }

    function script:Invoke-RealFragmentLoopGate {
        <#
        Dot-sources the real fragment-loop break-check (~L535) and the real cap/latch
        request-detection gate (~L661-683) inside an actual foreach over the supplied fragment
        names. The ONLY test-authored logic here is the bare foreach iteration + a visited-list
        accumulator; every break/latch/pending DECISION comes from the real dot-sourced source.
        Read-DscRebootRequests is mocked via a mutable cell updated once per iteration -- never
        re-registered mid-loop. The scoped RegistryRoot points to the isolated test drive.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSReviewUnusedParameter', '',
            Justification = '$configVersion/$runId are referenced by name from the real Invoke-Enforcement.ps1 source text dot-sourced via $gateSb ([scriptblock]::Create); PSSA cannot follow usage inside a runtime-built scriptblock.'
        )]
        param(
            [Parameter(Mandatory)][string[]]$FragmentNames,
            [int]$RebootCap = 10,
            [int]$RebootCountIncoming = 0,
            [bool]$RebootLoopLatchedIncoming = $false,
            [string]$ImmediateOnFragment = '',
            [switch]$EventualInInbox,
            [string]$EnforcementId = 'enforcement-1',
            [string]$configVersion = '1.0.0',
            [string]$runId = 'run-1'
        )
        $script:RebootPending             = $false
        $script:RebootLoopLatched         = $false
        $script:RebootKind                = ''
        $script:RebootRequestedBy         = ''
        $script:RebootEnforcementActive       = $false
        $script:RebootEnforcementId           = $EnforcementId
        $script:RebootCountIncoming       = $RebootCountIncoming
        $script:RebootLoopLatchedIncoming = $RebootLoopLatchedIncoming
        $script:RebootCap                 = $RebootCap
        $RegistryRoot = $script:regRoot

        $breakSb = [scriptblock]::Create((Get-EnforcementSnippet -StartAnchor 'if ($script:RebootPending) { break }'))
        $gateSb  = [scriptblock]::Create((Get-EnforcementSnippet -StartAnchor '# Read the reboot-request inbox for a committed Immediate request' -EndAnchor '$testResult = $testInvocation.Native'))

        $mockCell = @{ Response = @() }
        Mock Read-DscRebootRequests { return $mockCell.Response }

        $visited = New-Object 'System.Collections.Generic.List[string]'
        foreach ($fragmentName in $FragmentNames) {
            . $breakSb
            if ($script:RebootPending) { break }
            $visited.Add($fragmentName) | Out-Null
            $mockCell.Response = @(
                if ($fragmentName -eq $ImmediateOnFragment) {
                    [pscustomobject]@{ Kind = 'Immediate'; RequestedBy = 'TestRequester' }
                }
                if ($EventualInInbox) {
                    [pscustomobject]@{ Kind = 'Eventual'; RequestedBy = 'EventualRequester'; RequesterId = 'EventualRequester' }
                }
            )
            . $gateSb
        }

        [pscustomobject]@{
            Visited           = @($visited.ToArray())
            RebootPending     = $script:RebootPending
            RebootLoopLatched = $script:RebootLoopLatched
        }
    }

    function script:Invoke-RealOutcomeOverride {
        <#
        Dot-sources the real 2-line outcome-derivation override + exit-code force
        (Invoke-Enforcement.ps1 ~L1293-1300). Pre-set $outcome/$exitCode to the caller's chosen
        pre-override values; returns the post-override values.
        #>
        param(
            [Parameter(Mandatory)][string]$outcome,
            [Parameter(Mandatory)][int]$exitCode,
            [bool]$RebootLoopLatched = $false,
            [bool]$RebootPending = $false
        )
        $script:RebootLoopLatched = $RebootLoopLatched
        $script:RebootPending     = $RebootPending
        $src = Get-EnforcementSnippet -StartAnchor '# Reboot/latch override:' -EndAnchor '$errorMessage = '
        . ([scriptblock]::Create($src))
        [pscustomobject]@{ Outcome = $outcome; ExitCode = $exitCode }
    }

    function script:Invoke-RealTerminalLatchBranch {
        <#
        Dot-sources the real terminal latch/terminal-success-retire branch
        (Invoke-Enforcement.ps1 ~L1395-1403). Both Invoke-OrchestratorRebootLatch and
        Remove-DscRestartState are pure-file-I/O real module functions (no -RegistryRoot), so no
        mocking is needed -- $restartStatePath just points at a TestDrive file.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSReviewUnusedParameter', '',
            Justification = '$restartStatePath/$outcome/$configVersion are referenced by name from the real Invoke-Enforcement.ps1 source text dot-sourced via [scriptblock]::Create($src); PSSA cannot follow usage inside a runtime-built scriptblock.'
        )]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseDeclaredVarsMoreThanAssignments', '',
            Justification = '$resumedThisRun is referenced by name from the dot-sourced retire branch, not by any statement PSSA can see.'
        )]
        param(
            [Parameter(Mandatory)][string]$restartStatePath,
            [Parameter(Mandatory)][string]$outcome,
            [bool]$RebootLoopLatched = $false,
            [bool]$RebootEnforcementActive = $false,
            [bool]$ResumedThisRun = $false,
            [string]$EnforcementId = 'enforcement-1',
            [string]$configVersion = '1.0.0',
            [int]$RebootCountIncoming = 0
        )
        $script:RebootLoopLatched   = $RebootLoopLatched
        $script:RebootEnforcementActive = $RebootEnforcementActive
        $resumedThisRun = $ResumedThisRun
        $script:RebootEnforcementId     = $EnforcementId
        $script:RebootCountIncoming = $RebootCountIncoming
        $src = Get-EnforcementSnippet -StartAnchor 'if ($script:RebootLoopLatched) {' -EndAnchor 'Write-RunSummary @runSummaryDefaults -Timestamp $runTimestamp -Outcome $outcome'
        . ([scriptblock]::Create($src))
    }

    function script:New-FragmentYamlFixture {
        <#
        Writes a minimal, real, valid fragment YAML that Get-DeclaredResources (Dsc.YamlLines.psm1)
        can actually parse -- used so the unreached-fragment-accounting test exercises the real
        Get-DeclaredResources call, not a mock standing in for it.
        #>
        param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][int]$ResourceCount)
        $lines = New-Object 'System.Collections.Generic.List[string]'
        $lines.Add('resources:')
        for ($i = 1; $i -le $ResourceCount; $i++) {
            $lines.Add("  - name: Res$i")
            $lines.Add('    type: TestModule/TestResource')
        }
        Set-Content -LiteralPath $Path -Value $lines -Encoding utf8 -Force
    }

    function script:Invoke-RealUnreachedFragmentAccounting {
        <#
        Dot-sources the real post-loop unreached-fragment accounting block
        (Invoke-Enforcement.ps1 ~L1241-1266): for an actual-reboot early break, every declared
        resource in every fragment after the break point is folded in as 'unevaluated' so the
        5-bucket invariant still covers every declared resource, not just visited ones. Fragments'
        -Path point at real YAML fixtures (New-FragmentYamlFixture) so Get-DeclaredResources runs
        for real -- not mocked across the Dsc.YamlLines/Dsc.JsonLog module boundary.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSReviewUnusedParameter', '',
            Justification = '$fragments/$fragmentLoopIndex/$resourcesLog are referenced by name from the real Invoke-Enforcement.ps1 source text dot-sourced via [scriptblock]::Create($src); PSSA cannot follow usage inside a runtime-built scriptblock.'
        )]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseDeclaredVarsMoreThanAssignments', '',
            Justification = '$runId/$group/$role/$configurationHash/$configVersion/$RunTrigger/$resourcesSchemaVersion are referenced by name from the real dot-sourced snippet, not by any statement PSSA can see.'
        )]
        param(
            [Parameter(Mandatory)][object[]]$fragments,
            [Parameter(Mandatory)][int]$fragmentLoopIndex,
            [Parameter(Mandatory)][string]$resourcesLog,
            [bool]$RebootPending = $true
        )
        $script:RebootPending = $RebootPending
        $runId = 'run-1'; $group = 'pool-1'; $role = 'svc-1'; $configVersion = '1.0.0'
        $configurationHash = $null
        $RunTrigger = 'scheduled'; $resourcesSchemaVersion = '3.0'
        $aggTotalReal = 0; $aggUnevaluated = 0

        # End anchor stops at the Eventual gate so this harness runs ONLY the unreached-accounting
        # block -- the Eventual block now lives between it and $cappedNonCompliant.
        $src = Get-EnforcementSnippet -StartAnchor '# Actual-reboot path only: the early break above left later' -EndAnchor '# Eventual reboot (coalesced end-of-run):'
        . ([scriptblock]::Create($src))

        [pscustomobject]@{ AggTotalReal = $aggTotalReal; AggUnevaluated = $aggUnevaluated }
    }

    function script:Invoke-RealPostLoopEventualGate {
        <#
        Dot-sources the real post-loop Eventual coalesced-reboot gate
        (Invoke-Enforcement.ps1 ~L1268-1290): after a complete fragment walk (no Immediate break),
        a committed Eventual request reboots ONCE now under the same cap/latch gate as Immediate.
        Read-DscRebootRequests is mocked read-only via a cell returning the supplied committed
        request list on every call.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseDeclaredVarsMoreThanAssignments', '',
            Justification = '$configVersion/$runId/$mockCell are referenced only from the real dot-sourced snippet or the mock scriptblock, not by any statement PSSA can see.'
        )]
        param(
            [object[]]$Requests = @(),
            [int]$RebootCap = 10,
            [int]$RebootCountIncoming = 0,
            [bool]$RebootLoopLatchedIncoming = $false,
            [string]$EnforcementId = 'enforcement-1'
        )
        $script:RebootPending             = $false
        $script:RebootLoopLatched         = $false
        $script:RebootKind                = ''
        $script:RebootRequestedBy         = ''
        $script:RebootEnforcementActive   = $false
        $script:RebootEnforcementId       = $EnforcementId
        $script:RebootCountIncoming       = $RebootCountIncoming
        $script:RebootLoopLatchedIncoming = $RebootLoopLatchedIncoming
        $script:RebootCap                 = $RebootCap
        $configVersion = '1.0.0'; $runId = 'run-1'

        $mockCell = @{ Response = @($Requests) }
        $RegistryRoot = $script:regRoot
        Mock Read-DscRebootRequests { return $mockCell.Response }

        $src = Get-EnforcementSnippet -StartAnchor '# Eventual reboot (coalesced end-of-run):' -EndAnchor '$cappedNonCompliant = @($aggNonCompliantResources.ToArray()'
        . ([scriptblock]::Create($src))

        [pscustomobject]@{
            RebootPending     = $script:RebootPending
            RebootLoopLatched = $script:RebootLoopLatched
            RebootKind        = $script:RebootKind
            RebootRequestedBy = $script:RebootRequestedBy
        }
    }
}

Describe 'Registry inbox reader (Read/Clear-DscRebootRequests) -- reads the Orchestrator Request-DscReboot wire format' {

    BeforeEach {
        $script:regRoot = New-RegRoot
    }

    It 'a request with Complete=1 and matching Context is returned by Read-DscRebootRequests' {
        Publish-DscRebootContext -EnforcementId 'lin-1' -ConfigVersion '1.0.0' -RunId 'run-1' -RegistryRoot $script:regRoot
        $null = Request-DscReboot -Kind Immediate -RequestedBy 'Mod1' -RegistryRoot $script:regRoot

        $rows = @(Read-DscRebootRequests -EnforcementId 'lin-1' -ConfigVersion '1.0.0' -RunId 'run-1' -RegistryRoot $script:regRoot)
        $rows.Count | Should -Be 1
        $rows[0].Kind | Should -Be 'Immediate'
        $rows[0].RequestedBy | Should -Be 'Mod1'
        $rows[0].EnforcementId | Should -Be 'lin-1'
        $rows[0].ConfigVersion | Should -Be '1.0.0'
        $rows[0].RunId | Should -Be 'run-1'
    }

    It 'a torn write (no Complete property at all) is invisible -- the commit fence' {
        $requestKey = Join-Path (Join-Path $script:regRoot 'Requests') 'TornMod'
        New-Item -Path $requestKey -Force | Out-Null
        Set-ItemProperty -LiteralPath $requestKey -Name 'Kind' -Value 'Immediate' -Type String -Force
        Set-ItemProperty -LiteralPath $requestKey -Name 'EnforcementId' -Value 'lin-1' -Type String -Force
        Set-ItemProperty -LiteralPath $requestKey -Name 'ConfigVersion' -Value '1.0.0' -Type String -Force

        $rows = @(Read-DscRebootRequests -EnforcementId 'lin-1' -ConfigVersion '1.0.0' -RegistryRoot $script:regRoot)
        $rows.Count | Should -Be 0
    }

    It 'a request stamped for a different EnforcementId is ignored even with Complete=1' {
        Publish-DscRebootContext -EnforcementId 'lin-stale' -ConfigVersion '1.0.0' -RunId 'run-stale' -RegistryRoot $script:regRoot
        $null = Request-DscReboot -Kind Immediate -RequestedBy 'Mod1' -RegistryRoot $script:regRoot

        $rows = @(Read-DscRebootRequests -EnforcementId 'lin-current' -ConfigVersion '1.0.0' -RegistryRoot $script:regRoot)
        $rows.Count | Should -Be 0
    }

    It 'Clear-DscRebootRequests deletes every subkey under Requests' {
        Publish-DscRebootContext -EnforcementId 'lin-1' -ConfigVersion '1.0.0' -RunId 'run-1' -RegistryRoot $script:regRoot
        $null = Request-DscReboot -Kind Immediate -RequestedBy 'Mod1' -RegistryRoot $script:regRoot
        $null = Request-DscReboot -Kind Eventual -RequestedBy 'Mod2' -RegistryRoot $script:regRoot

        Clear-DscRebootRequests -RegistryRoot $script:regRoot

        $rows = @(Read-DscRebootRequests -EnforcementId 'lin-1' -ConfigVersion '1.0.0' -RegistryRoot $script:regRoot)
        $rows.Count | Should -Be 0
    }

    Context 'RunId-mismatch filtering (real filter semantics: only filters when BOTH sides are non-empty and differ)' {

        It 'a request stamped with a different non-empty RunId than the caller is filtered out' {
            Publish-DscRebootContext -EnforcementId 'lin-1' -ConfigVersion '1.0.0' -RunId 'run-A' -RegistryRoot $script:regRoot
            $null = Request-DscReboot -Kind Immediate -RequestedBy 'Mod1' -RegistryRoot $script:regRoot

            $rows = @(Read-DscRebootRequests -EnforcementId 'lin-1' -ConfigVersion '1.0.0' -RunId 'run-B' -RegistryRoot $script:regRoot)
            $rows.Count | Should -Be 0
        }

        It 'a request stamped with the SAME RunId as the caller is returned' {
            Publish-DscRebootContext -EnforcementId 'lin-1' -ConfigVersion '1.0.0' -RunId 'run-A' -RegistryRoot $script:regRoot
            $null = Request-DscReboot -Kind Immediate -RequestedBy 'Mod1' -RegistryRoot $script:regRoot

            $rows = @(Read-DscRebootRequests -EnforcementId 'lin-1' -ConfigVersion '1.0.0' -RunId 'run-A' -RegistryRoot $script:regRoot)
            $rows.Count | Should -Be 1
        }

        It 'a request with an EMPTY stored RunId is still returned even when the caller passes a non-empty RunId (defensive case)' {
            # Context not published before the request -> the stamped RunId is ''.
            $requestKey = Join-Path (Join-Path $script:regRoot 'Requests') 'Mod1'
            New-Item -Path $requestKey -Force | Out-Null
            Set-ItemProperty -LiteralPath $requestKey -Name 'Kind' -Value 'Immediate' -Type String -Force
            Set-ItemProperty -LiteralPath $requestKey -Name 'RequestedBy' -Value 'Mod1' -Type String -Force
            Set-ItemProperty -LiteralPath $requestKey -Name 'EnforcementId' -Value 'lin-1' -Type String -Force
            Set-ItemProperty -LiteralPath $requestKey -Name 'ConfigVersion' -Value '1.0.0' -Type String -Force
            Set-ItemProperty -LiteralPath $requestKey -Name 'RunId' -Value '' -Type String -Force
            Set-ItemProperty -LiteralPath $requestKey -Name 'Complete' -Value 1 -Type DWord -Force

            $rows = @(Read-DscRebootRequests -EnforcementId 'lin-1' -ConfigVersion '1.0.0' -RunId 'run-A' -RegistryRoot $script:regRoot)
            $rows.Count | Should -Be 1
        }
    }
}

Describe 'Get-CanonicalBootId' {

    It 'rounds to whole seconds and serializes in round-trip (o) UTC format' {
        $boot = Get-CanonicalBootId -BootTimeUtc ([datetime]::Parse('2026-01-01T12:30:45.789Z').ToUniversalTime())
        $boot | Should -Be '2026-01-01T12:30:45.0000000Z'
    }

    It 'two BootTimeUtc values differing only by sub-second precision canonicalize to the SAME id' {
        $a = Get-CanonicalBootId -BootTimeUtc ([datetime]::Parse('2026-01-01T12:30:45.001Z').ToUniversalTime())
        $b = Get-CanonicalBootId -BootTimeUtc ([datetime]::Parse('2026-01-01T12:30:45.987Z').ToUniversalTime())
        $a | Should -Be $b
    }

    It 'two BootTimeUtc values one whole second apart canonicalize to DIFFERENT ids' {
        $a = Get-CanonicalBootId -BootTimeUtc ([datetime]::Parse('2026-01-01T12:30:45.000Z').ToUniversalTime())
        $b = Get-CanonicalBootId -BootTimeUtc ([datetime]::Parse('2026-01-01T12:30:46.000Z').ToUniversalTime())
        $a | Should -Not -Be $b
    }
}

Describe 'Test-OrchestratorRebootResume -- reboot-resume override classification matrix' {

    BeforeEach {
        $script:statePath = Join-Path $TestDrive ("restart-state-{0}.json" -f ([Guid]::NewGuid().ToString('N')))
    }

    It 'row: no restart-state file -> Override=false, Reason=no_state' {
        $r = Test-OrchestratorRebootResume -Path $script:statePath -ConfigVersion '1.0.0' -CurrentBootId 'boot-1'
        $r.Override | Should -BeFalse
        $r.Reason | Should -Be 'no_state'
    }

    It 'row: reboot_pending=false (already consumed/never set) -> Override=false, Reason=not_pending' {
        Write-RestartState -Path $script:statePath -RebootPending $false -ConfigVersion '1.0.0' -PreRebootBootId 'boot-old'
        $r = Test-OrchestratorRebootResume -Path $script:statePath -ConfigVersion '1.0.0' -CurrentBootId 'boot-new'
        $r.Override | Should -BeFalse
        $r.Reason | Should -Be 'not_pending'
    }

    It 'row: config_version mismatch -> Override=false, Reason=config_mismatch (even though reboot_pending=true)' {
        Write-RestartState -Path $script:statePath -RebootPending $true -ConfigVersion '1.0.0' -PreRebootBootId 'boot-old'
        $r = Test-OrchestratorRebootResume -Path $script:statePath -ConfigVersion '2.0.0' -CurrentBootId 'boot-new'
        $r.Override | Should -BeFalse
        $r.Reason | Should -Be 'config_mismatch'
    }

    It 'row: same boot id (cap-hit / redeploy-without-reboot / same-boot rerun) -> Override=false, Reason=same_boot' {
        Write-RestartState -Path $script:statePath -RebootPending $true -ConfigVersion '1.0.0' -PreRebootBootId 'boot-same'
        $r = Test-OrchestratorRebootResume -Path $script:statePath -ConfigVersion '1.0.0' -CurrentBootId 'boot-same'
        $r.Override | Should -BeFalse
        $r.Reason | Should -Be 'same_boot'
    }

    It 'a CONSUMED override never re-fires on a later crash in the resumed run (predicate 2 blocks it)' {
        Write-RestartState -Path $script:statePath -RebootPending $true -ConfigVersion '1.0.0' -PreRebootBootId 'boot-old' -RebootCount 2
        $first = Test-OrchestratorRebootResume -Path $script:statePath -ConfigVersion '1.0.0' -CurrentBootId 'boot-new'
        $first.Override | Should -BeTrue
        $first.Reason | Should -Be 'override'

        # Simulate a crash in the resumed run: re-evaluate against the now-consumed state.
        $second = Test-OrchestratorRebootResume -Path $script:statePath -ConfigVersion '1.0.0' -CurrentBootId 'boot-new'
        $second.Override | Should -BeFalse
        $second.Reason | Should -Be 'not_pending'
    }

    It 'row: a genuine override (different boot id, pending, matching config) -> Override=true, Reason=override, AND atomically consumes (reboot_pending rewritten false) -- distinguishes override from every aborted row above' {
        Write-RestartState -Path $script:statePath -RebootPending $true -ConfigVersion '1.0.0' -PreRebootBootId 'boot-old' -RebootCount 3 -RebootKind 'Eventual' -RebootRequestedBy 'ModX'
        $r = Test-OrchestratorRebootResume -Path $script:statePath -ConfigVersion '1.0.0' -CurrentBootId 'boot-new'

        $r.Override | Should -BeTrue
        $r.Reason | Should -Be 'override'
        $r.RebootCount | Should -Be 3
        $r.RebootKind | Should -Be 'Eventual'
        $r.RebootRequestedBy | Should -Be 'ModX'

        # The consume is real and durable, not just an in-memory flag on the return object.
        $onDisk = Get-Content -LiteralPath $script:statePath -Raw | ConvertFrom-Json
        $onDisk.reboot_pending | Should -BeFalse
        $onDisk.reboot_count | Should -Be 3
        Test-Path -LiteralPath "$script:statePath.tmp" | Should -BeFalse
    }

    It 'a corrupt/unparseable restart-state.json is treated as absent, never throws, Reason=no_state' {
        Set-Content -LiteralPath $script:statePath -Value '{ this is not valid json' -Encoding utf8
        $threw = $false
        try {
            $r = Test-OrchestratorRebootResume -Path $script:statePath -ConfigVersion '1.0.0' -CurrentBootId 'boot-1'
        } catch {
            $threw = $true
        }
        $threw | Should -BeFalse
        $r.Override | Should -BeFalse
        $r.Reason | Should -Be 'no_state'
    }

    It 'a restart-state round-tripped through JSON (pre_reboot_boot_id auto-coerced to [datetime] by ConvertFrom-Json) still correctly classifies same-boot as NOT an override' {
        # Regression pin for the timestamp-canonicalization fix: without it, the
        # boot-id comparison silently breaks across a JSON round-trip and same-boot incorrectly
        # overrides every time.
        $bootId = (Get-CanonicalBootId -BootTimeUtc ([datetime]'2026-03-15T09:00:00Z'))
        Write-RestartState -Path $script:statePath -RebootPending $true -ConfigVersion '1.0.0' -PreRebootBootId $bootId
        $r = Test-OrchestratorRebootResume -Path $script:statePath -ConfigVersion '1.0.0' -CurrentBootId $bootId
        $r.Override | Should -BeFalse
        $r.Reason | Should -Be 'same_boot'
    }
}

Describe 'Invoke-OrchestratorRebootFinalize -- step ordering (real sequence, hashtable-captured checkpoint)' {

    BeforeEach {
        $script:dir = Join-Path $TestDrive ("finalize-order-{0}" -f ([Guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $script:dir -Force | Out-Null
        $script:statePath  = Join-Path $script:dir 'restart-state.json'
        $script:sentinelPath = Join-Path $script:dir 'sentinel.json'
        $script:ripPath    = Join-Path $script:dir '.reboot-in-progress.json'
        $script:runsLog    = Join-Path $script:dir 'runs.jsonl'
        $script:regRoot    = New-RegRoot
    }

    It 'restart-state -> registry cleared -> sentinel -> reboot-in-progress marker -> runs.jsonl row ALL exist (real values, checked from inside the rebooter) BEFORE the rebooter is invoked; bug fix: hashtable capture, not $script:rebooterCalled' {
        Publish-DscRebootContext -EnforcementId 'lin-1' -ConfigVersion '1.0.0' -RunId 'run-1' -RegistryRoot $script:regRoot
        $null = Request-DscReboot -Kind Immediate -RequestedBy 'Requester1' -RegistryRoot $script:regRoot

        $observed = @{ Called = $false; StateExists = $false; RequestsCleared = $false; SentinelExists = $false; RipExists = $false; RunsRowCount = 0; PendingTrue = $false }
        $rebooter = {
            $observed.Called          = $true
            $observed.StateExists     = Test-Path -LiteralPath $script:statePath
            $observed.RequestsCleared = (@(Read-DscRebootRequests -EnforcementId 'lin-1' -ConfigVersion '1.0.0' -RegistryRoot $script:regRoot)).Count -eq 0
            $observed.SentinelExists  = Test-Path -LiteralPath $script:sentinelPath
            $observed.RipExists       = Test-Path -LiteralPath $script:ripPath
            $rows = (Get-EmittedRows -Path $script:runsLog)
            $observed.RunsRowCount = $rows.Count
            if ($rows.Count -gt 0) {
                $observed.PendingTrue = ((Get-Content -LiteralPath $script:statePath -Raw | ConvertFrom-Json).reboot_pending) -eq $true
            }
        }

        $argsBag = New-FinalizeArgs -Path $script:statePath -RegistryRoot $script:regRoot -SentinelPath $script:sentinelPath `
            -RebootInProgressPath $script:ripPath -RunsLogPath $script:runsLog -EnforcementId 'lin-1' -RequestedBy 'Requester1' `
            -Rebooter $rebooter
        $null = Invoke-OrchestratorRebootFinalize @argsBag

        $observed.Called | Should -BeTrue
        $observed.StateExists | Should -BeTrue
        $observed.RequestsCleared | Should -BeTrue
        $observed.SentinelExists | Should -BeTrue
        $observed.RipExists | Should -BeTrue
        $observed.RunsRowCount | Should -Be 1
        $observed.PendingTrue | Should -BeTrue
    }

    It 'the restart-state write is durable: no leftover .tmp file, and the committed file is valid JSON with the expected fields, after the call returns' {
        $argsBag = New-FinalizeArgs -Path $script:statePath -RegistryRoot $script:regRoot -SentinelPath $script:sentinelPath `
            -RebootInProgressPath $script:ripPath -RunsLogPath $script:runsLog -EnforcementId 'lin-1' -RequestedBy 'Requester1' `
            -Rebooter { } -IncomingRebootCount 2

        $null = Invoke-OrchestratorRebootFinalize @argsBag

        Test-Path -LiteralPath "$script:statePath.tmp" | Should -BeFalse
        Test-Path -LiteralPath $script:statePath | Should -BeTrue
        $onDisk = Get-Content -LiteralPath $script:statePath -Raw | ConvertFrom-Json
        $onDisk.enforcement_id | Should -Be 'lin-1'
        # reboot_count is computed internally as IncomingRebootCount + 1.
        $onDisk.reboot_count | Should -Be 3
    }

    It 'the reboot_pending runs.jsonl row carries the full 5-bucket invariant (total = compliant + non_compliant + failed + skipped + unevaluated) plus reboot_count and enforcement_id; reboot_kind/reboot_requested_by stay in restart-state only' {
        $summaryArgs = New-RebootRunSummaryArgs -Overrides @{
            TotalResources = 12; CompliantResources = 7; NonCompliantCount = 2; FailedCount = 1; SkippedCount = 1; UnevaluatedCount = 1
            EnforcementId = 'enf-9'
        }
        $argsBag = New-FinalizeArgs -Path $script:statePath -RegistryRoot $script:regRoot -SentinelPath $script:sentinelPath `
            -RebootInProgressPath $script:ripPath -RunsLogPath $script:runsLog -EnforcementId 'enf-9' -ConfigVersion '3.2.1' `
            -RequestedBy 'ModuleZ' -Kind Eventual -IncomingRebootCount 4 -RunSummaryArgs $summaryArgs -Rebooter { }

        $null = Invoke-OrchestratorRebootFinalize @argsBag

        $rows = (Get-EmittedRows -Path $script:runsLog)
        $pendingRow = $rows | Where-Object { $_.outcome -eq 'reboot_pending' } | Select-Object -First 1
        $pendingRow | Should -Not -BeNullOrEmpty
        ($pendingRow.total_resources) | Should -Be (
            $pendingRow.compliant_resources + $pendingRow.non_compliant_count + $pendingRow.failed_count +
            $pendingRow.skipped_count + $pendingRow.unevaluated_count
        )
        $pendingRow.total_resources | Should -Be 12
        $pendingRow.compliant_resources | Should -Be 7
        $pendingRow.non_compliant_count | Should -Be 2
        $pendingRow.failed_count | Should -Be 1
        $pendingRow.skipped_count | Should -Be 1
        $pendingRow.unevaluated_count | Should -Be 1
        $pendingRow.reboot_count | Should -Be 5
        $pendingRow.config_version | Should -Be '3.2.1'
        $pendingRow.enforcement_id | Should -Be 'enf-9'
        @($pendingRow.PSObject.Properties.Name) | Should -Not -Contain 'reboot_kind'
        @($pendingRow.PSObject.Properties.Name) | Should -Not -Contain 'reboot_requested_by'
    }

    It 'crash-critical step ordering is pinned via -StepRecorder: restart-state-commit is first (precedes every other step), and summary precedes rebooter' {
        # The prior tests could only observe that all steps complete before the rebooter fires, not
        # their relative order among themselves. A reorder that moved the restart-state commit later
        # (e.g. behind the registry clear or the summary append) would silently break the
        # resume-safety invariant on a mid-finalize crash; this test fails immediately if that ever
        # happens.
        $recorded = New-Object 'System.Collections.Generic.List[string]'
        $recorder = { param($Step) $recorded.Add($Step) | Out-Null }

        $argsBag = New-FinalizeArgs -Path $script:statePath -RegistryRoot $script:regRoot -SentinelPath $script:sentinelPath `
            -RebootInProgressPath $script:ripPath -RunsLogPath $script:runsLog -EnforcementId 'lin-order' -RequestedBy 'Requester1' `
            -Rebooter { }
        $argsBag.StepRecorder = $recorder

        $null = Invoke-OrchestratorRebootFinalize @argsBag

        $recorded | Should -Contain 'restart-state-commit'
        $recorded | Should -Contain 'clear-requests'
        $recorded | Should -Contain 'sentinel-rewrite'
        $recorded | Should -Contain 'reboot-in-progress'
        $recorded | Should -Contain 'summary'
        $recorded | Should -Contain 'rebooter'

        $commitIndex  = $recorded.IndexOf('restart-state-commit')
        $summaryIndex = $recorded.IndexOf('summary')
        $rebooterIndex = $recorded.IndexOf('rebooter')

        foreach ($laterStep in @('clear-requests', 'sentinel-rewrite', 'reboot-in-progress', 'summary', 'rebooter')) {
            $commitIndex | Should -BeLessThan ($recorded.IndexOf($laterStep))
        }
        $summaryIndex | Should -BeLessThan $rebooterIndex
    }
}

Describe 'Invoke-OrchestratorRebootFinalize -- rebooter return/throw is uniformly the failure path (no observable "success" return is possible in-process)' {

    BeforeEach {
        $script:dir = Join-Path $TestDrive ("finalize-fail-{0}" -f ([Guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $script:dir -Force | Out-Null
        $script:statePath  = Join-Path $script:dir 'restart-state.json'
        $script:sentinelPath = Join-Path $script:dir 'sentinel.json'
        $script:ripPath    = Join-Path $script:dir '.reboot-in-progress.json'
        $script:runsLog    = Join-Path $script:dir 'runs.jsonl'
        $script:regRoot    = New-RegRoot
    }

    function script:Invoke-FinalizeAndCaptureExit {
        # Bug fix: hashtable capture (not $script:exitCode) + explicitly discard the function's own
        # return value so it can never leak into the caller's assignment.
        param([hashtable]$ArgsBag)
        $capture = @{ ExitCode = $null }
        $exitSeam = { param($Code) $capture.ExitCode = $Code }
        $ArgsBag.Exit = $exitSeam
        $null = Invoke-OrchestratorRebootFinalize @ArgsBag
        return $capture.ExitCode
    }

    It 'rebooter RETURNS without terminating the process -> explicit failure path: restart-state rewritten non-pending, Exit invoked with 1' {
        $argsBag = New-FinalizeArgs -Path $script:statePath -RegistryRoot $script:regRoot -SentinelPath $script:sentinelPath `
            -RebootInProgressPath $script:ripPath -RunsLogPath $script:runsLog -Rebooter { 'returned' }

        $exitCode = Invoke-FinalizeAndCaptureExit -ArgsBag $argsBag

        $exitCode | Should -Be 1
        (Get-Content -LiteralPath $script:statePath -Raw | ConvertFrom-Json).reboot_pending | Should -BeFalse
    }

    It 'rebooter THROWS -> explicit failure path: restart-state rewritten non-pending, Exit invoked with 1, error message captured' {
        $argsBag = New-FinalizeArgs -Path $script:statePath -RegistryRoot $script:regRoot -SentinelPath $script:sentinelPath `
            -RebootInProgressPath $script:ripPath -RunsLogPath $script:runsLog -Rebooter { throw 'Restart-Computer access denied' }

        $exitCode = Invoke-FinalizeAndCaptureExit -ArgsBag $argsBag

        $exitCode | Should -Be 1
        (Get-Content -LiteralPath $script:statePath -Raw | ConvertFrom-Json).reboot_pending | Should -BeFalse
    }

    It 'APPENDS a corrective terminal row (never overwrites the reboot_pending row): runs.jsonl has both, same run_id, corrective row outcome=remediation_failed' {
        $argsBag = New-FinalizeArgs -Path $script:statePath -RegistryRoot $script:regRoot -SentinelPath $script:sentinelPath `
            -RebootInProgressPath $script:ripPath -RunsLogPath $script:runsLog -RunId 'run-append-1' -Rebooter { 'returned' }

        $null = Invoke-FinalizeAndCaptureExit -ArgsBag $argsBag

        $rows = (Get-EmittedRows -Path $script:runsLog -RunId 'run-append-1')
        $rows.Count | Should -Be 2
        @($rows | Select-Object -ExpandProperty run_id -Unique).Count | Should -Be 1
        $rows[0].outcome | Should -Be 'reboot_pending'
        $rows[1].outcome | Should -Be 'remediation_failed'
        $rows[1].exit_code | Should -Be 1
    }

    It 'the corrective row carries a strictly-later timestamp than the pending row, even when the injected Clock does not advance (forced +1ms determinism)' {
        $fixedNow = [datetime]'2026-04-01T00:00:00Z'
        $clock = { $fixedNow }
        $argsBag = New-FinalizeArgs -Path $script:statePath -RegistryRoot $script:regRoot -SentinelPath $script:sentinelPath `
            -RebootInProgressPath $script:ripPath -RunsLogPath $script:runsLog -RunId 'run-clock-1' -Rebooter { 'returned' } -Clock $clock

        $null = Invoke-FinalizeAndCaptureExit -ArgsBag $argsBag

        $rows = (Get-EmittedRows -Path $script:runsLog -RunId 'run-clock-1')
        $rows.Count | Should -Be 2
        ([datetime]$rows[1].TimeGenerated) | Should -BeGreaterThan ([datetime]$rows[0].TimeGenerated)
    }

    It 'the error message on the corrective row reflects the actual thrown exception text, not a generic placeholder' {
        $argsBag = New-FinalizeArgs -Path $script:statePath -RegistryRoot $script:regRoot -SentinelPath $script:sentinelPath `
            -RebootInProgressPath $script:ripPath -RunsLogPath $script:runsLog -RunId 'run-err-1' -Rebooter { throw 'disk full' }

        $null = Invoke-FinalizeAndCaptureExit -ArgsBag $argsBag

        $rows = (Get-EmittedRows -Path $script:runsLog -RunId 'run-err-1')
        $rows[1].error | Should -Match 'disk full'
    }
}

Describe 'Invoke-OrchestratorRebootFinalize -- requesters[] enforcement continuity across reboots' {

    BeforeEach {
        $script:dir = Join-Path $TestDrive ("finalize-enforcement-{0}" -f ([Guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $script:dir -Force | Out-Null
        $script:statePath  = Join-Path $script:dir 'restart-state.json'
        $script:sentinelPath = Join-Path $script:dir 'sentinel.json'
        $script:ripPath    = Join-Path $script:dir '.reboot-in-progress.json'
        $script:runsLog    = Join-Path $script:dir 'runs.jsonl'
        $script:regRoot    = New-RegRoot
    }

    It 'a FIRST reboot in an enforcement effort mints a single requesters[] entry with request_count=1 for the real requester (not a tautological pass-then-assert)' {
        $argsBag = New-FinalizeArgs -Path $script:statePath -RegistryRoot $script:regRoot -SentinelPath $script:sentinelPath `
            -RebootInProgressPath $script:ripPath -RunsLogPath $script:runsLog -RequestedBy 'FirstRequester' -Kind Immediate `
            -IncomingRebootCount 0 -Rebooter { }

        $null = Invoke-OrchestratorRebootFinalize @argsBag

        $state = Get-Content -LiteralPath $script:statePath -Raw | ConvertFrom-Json
        @($state.requesters).Count | Should -Be 1
        $state.requesters[0].requester_id | Should -Be 'FirstRequester'
        $state.requesters[0].request_count | Should -Be 1
        $state.reboot_count | Should -Be 1
    }

    It 'a SECOND reboot by the SAME requester in the same enforcement increments that requester''s request_count to 2 and preserves a co-requester untouched' {
        Write-RestartState -Path $script:statePath -EnforcementId 'lin-multi' -RebootPending $false -RebootCount 1 -Requesters @(
            [ordered]@{ requester_id = 'RequesterA'; kind = 'Immediate'; request_count = 1; last_requested_at = '2026-01-01T00:00:00Z' },
            [ordered]@{ requester_id = 'RequesterB'; kind = 'Eventual'; request_count = 1; last_requested_at = '2026-01-01T00:00:00Z' }
        )

        $argsBag = New-FinalizeArgs -Path $script:statePath -RegistryRoot $script:regRoot -SentinelPath $script:sentinelPath `
            -RebootInProgressPath $script:ripPath -RunsLogPath $script:runsLog -EnforcementId 'lin-multi' -RequestedBy 'RequesterA' `
            -Kind Immediate -IncomingRebootCount 1 -Rebooter { }

        $null = Invoke-OrchestratorRebootFinalize @argsBag

        $state = Get-Content -LiteralPath $script:statePath -Raw | ConvertFrom-Json
        @($state.requesters).Count | Should -Be 2
        $state.reboot_count | Should -Be 2
        ($state.requesters | Where-Object { $_.requester_id -eq 'RequesterA' }).request_count | Should -Be 2
        # The co-requester's own count must be left exactly as it was -- not bumped, not dropped.
        ($state.requesters | Where-Object { $_.requester_id -eq 'RequesterB' }).request_count | Should -Be 1
    }

    It 'a SECOND reboot by a DIFFERENT (new) requester in the same enforcement appends a fresh requesters[] entry alongside the existing one' {
        Write-RestartState -Path $script:statePath -EnforcementId 'lin-multi2' -RebootPending $false -RebootCount 1 -Requesters @(
            [ordered]@{ requester_id = 'RequesterA'; kind = 'Immediate'; request_count = 1; last_requested_at = '2026-01-01T00:00:00Z' }
        )

        $argsBag = New-FinalizeArgs -Path $script:statePath -RegistryRoot $script:regRoot -SentinelPath $script:sentinelPath `
            -RebootInProgressPath $script:ripPath -RunsLogPath $script:runsLog -EnforcementId 'lin-multi2' -RequestedBy 'RequesterC' `
            -Kind Eventual -IncomingRebootCount 1 -Rebooter { }

        $null = Invoke-OrchestratorRebootFinalize @argsBag

        $state = Get-Content -LiteralPath $script:statePath -Raw | ConvertFrom-Json
        @($state.requesters).Count | Should -Be 2
        ($state.requesters | Where-Object { $_.requester_id -eq 'RequesterA' }).request_count | Should -Be 1
        ($state.requesters | Where-Object { $_.requester_id -eq 'RequesterC' }).request_count | Should -Be 1
    }
}

Describe 'Resume + stale-sentinel classification (real dot-sourced Invoke-Enforcement.ps1 block, ~L307-403)' {

    BeforeEach {
        $script:dir = Join-Path $TestDrive ("resume-{0}" -f ([Guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $script:dir -Force | Out-Null
        $script:runsLog = Join-Path $script:dir 'runs.jsonl'
        Mock Get-CanonicalBootId { 'boot-current' }
    }

    It 'writes the originating configuration hash into a new run sentinel' {
        $hash = ('a' * 64) -join ''

        Update-RunSentinel -LogDir $script:dir -RunId 'starting-run' `
            -StartedAt ([datetime]'2026-09-24T12:00:00Z') -Phase 'startup' -ConfigurationHash $hash

        $sentinel = Get-Content -LiteralPath (Join-Path $script:dir '.in-progress.json') -Raw |
            ConvertFrom-Json
        $sentinel.configuration_hash | Should -Be $hash
    }

    It 'fresh host, no restart-state at all: mints a new GUID enforcement, no override, no aborted row, no stale sentinel handling' {
        $r = Invoke-RealResumeClassification -LogDir $script:dir -configVersion '1.0.0' -runsLog $script:runsLog
        $r.EnforcementId | Should -Not -BeNullOrEmpty
        [Guid]::TryParse($r.EnforcementId, [ref]([Guid]::Empty)) | Should -BeTrue
        $r.EnforcementActive | Should -BeFalse
        $r.ResumedThisRun | Should -BeFalse
        (Get-EmittedRows -Path $script:runsLog).Count | Should -Be 0
    }

    It 'Get-CanonicalBootId throwing (CIM failure) is swallowed -- falls back to a fresh enforcement, no override, no crash, even with a live restart-state present' {
        Write-RestartState -Path (Join-Path $script:dir 'restart-state.json') -EnforcementId 'lin-cim-fail' -ConfigVersion '1.0.0' -RebootPending $true -PreRebootBootId 'boot-old' -RebootCount 3
        Mock Get-CanonicalBootId { throw 'CIM call failed: Win32_OperatingSystem unreachable' }

        $threw = $false
        $r = $null
        try {
            $r = Invoke-RealResumeClassification -LogDir $script:dir -configVersion '1.0.0' -runsLog $script:runsLog
        } catch {
            $threw = $true
        }

        $threw | Should -BeFalse
        $r.EnforcementActive | Should -BeFalse
        $r.EnforcementId | Should -Not -Be 'lin-cim-fail'
        [Guid]::TryParse($r.EnforcementId, [ref]([Guid]::Empty)) | Should -BeTrue
        $r.ResumedThisRun | Should -BeFalse
        $r.CountIncoming | Should -Be 0
    }

    It 'a valid reboot override (different boot id) suppresses the aborted tombstone for our own clean reboot -- real dot-sourced block, not a harness reimplementation' {
        Write-RestartState -Path (Join-Path $script:dir 'restart-state.json') -EnforcementId 'lin-real' -ConfigVersion '1.0.0' -RebootPending $true -PreRebootBootId 'boot-old' -RebootCount 5
        $sentinelPath = Join-Path $script:dir '.in-progress.json'
        ([ordered]@{ schema_version = '1.0'; run_id = 'prior-run'; started_at = '2026-01-01T00:00:00Z'; phase = 'fragments'; phase_at = '2026-01-01T00:00:05Z' } | ConvertTo-Json -Compress) |
            Set-Content -LiteralPath $sentinelPath -Encoding utf8

        $r = Invoke-RealResumeClassification -LogDir $script:dir -configVersion '1.0.0' -runsLog $script:runsLog

        $r.ResumedThisRun | Should -BeTrue
        $r.EnforcementId | Should -Be 'lin-real'
        $r.EnforcementActive | Should -BeTrue
        $r.CountIncoming | Should -Be 5
        # No 'aborted' tombstone row for our own clean reboot.
        (Get-EmittedRows -Path $script:runsLog) | Where-Object { $_.outcome -eq 'aborted' } | Should -BeNullOrEmpty
        # The override consumed the sentinel (stale-sentinel block never re-processes it after resume).
        Test-Path -LiteralPath $sentinelPath | Should -BeFalse
    }

    It 'NO valid override + a stale sentinel present -> writes a real "aborted" row to runs.jsonl and deletes the sentinel' {
        $staleHash = ('a' * 64) -join ''
        $currentHash = ('b' * 64) -join ''
        $sentinelPath = Join-Path $script:dir '.in-progress.json'
        ([ordered]@{
            schema_version     = '1.0'
            run_id             = 'crashed-run'
            started_at         = '2026-01-01T00:00:00Z'
            phase              = 'fragments'
            phase_at           = '2026-01-01T00:00:05Z'
            configuration_hash = $staleHash
        } | ConvertTo-Json -Compress) |
            Set-Content -LiteralPath $sentinelPath -Encoding utf8

        $r = Invoke-RealResumeClassification -LogDir $script:dir -configVersion '1.0.0' `
            -runsLog $script:runsLog -configurationHash $currentHash

        $r.ResumedThisRun | Should -BeFalse
        $rows = (Get-EmittedRows -Path $script:runsLog)
        $rows.Count | Should -Be 1
        $rows[0].outcome | Should -Be 'aborted'
        $rows[0].run_id | Should -Be 'crashed-run'
        $rows[0].configuration_hash | Should -Be $staleHash
        # No active enforcement at all in this scenario -- reboot_count stays 0, not carried over from
        # some stale prior value. enforcement_id is still a freshly minted GUID -- every run belongs to
        # some enforcement effort even if this one never reboots.
        $rows[0].reboot_count | Should -Be 0
        $rows[0].enforcement_id | Should -Not -BeNullOrEmpty
        [Guid]::TryParse($rows[0].enforcement_id, [ref]([Guid]::Empty)) | Should -BeTrue
        Test-Path -LiteralPath $sentinelPath | Should -BeFalse
    }

    It 'emits a null hash for a legacy stale sentinel even when the current package has a hash' {
        $currentHash = ('b' * 64) -join ''
        $sentinelPath = Join-Path $script:dir '.in-progress.json'
        ([ordered]@{
            schema_version = '1.0'
            run_id         = 'legacy-crashed-run'
            started_at     = '2026-01-01T00:00:00Z'
            phase          = 'fragments'
            phase_at       = '2026-01-01T00:00:05Z'
        } | ConvertTo-Json -Compress) |
            Set-Content -LiteralPath $sentinelPath -Encoding utf8

        $null = Invoke-RealResumeClassification -LogDir $script:dir -configVersion '1.0.0' `
            -runsLog $script:runsLog -configurationHash $currentHash

        $rows = Get-EmittedRows -Path $script:runsLog
        $rows.Count | Should -Be 1
        $rows[0].run_id | Should -Be 'legacy-crashed-run'
        $rows[0].configuration_hash | Should -BeNullOrEmpty
    }

    It 'a stale sentinel present TOGETHER WITH a carried-forward same-boot enforcement threads the REAL reboot_count and enforcement_id onto the aborted row (not 0 / not a fresh GUID)' {
        Write-RestartState -Path (Join-Path $script:dir 'restart-state.json') -EnforcementId 'lin-carried-stale' -ConfigVersion '1.0.0' -RebootPending $true -PreRebootBootId 'boot-current' -RebootCount 4
        $sentinelPath = Join-Path $script:dir '.in-progress.json'
        ([ordered]@{ schema_version = '1.0'; run_id = 'crashed-run-2'; started_at = '2026-01-01T00:00:00Z'; phase = 'fragments'; phase_at = '2026-01-01T00:00:05Z' } | ConvertTo-Json -Compress) |
            Set-Content -LiteralPath $sentinelPath -Encoding utf8

        $r = Invoke-RealResumeClassification -LogDir $script:dir -configVersion '1.0.0' -runsLog $script:runsLog

        # Same boot id -> no override; the existing enforcement is carried forward (not resumed, not fresh).
        $r.ResumedThisRun | Should -BeFalse
        $r.EnforcementActive | Should -BeTrue
        $r.EnforcementId | Should -Be 'lin-carried-stale'
        $r.CountIncoming | Should -Be 4

        $rows = (Get-EmittedRows -Path $script:runsLog)
        $rows.Count | Should -Be 1
        $rows[0].outcome | Should -Be 'aborted'
        $rows[0].reboot_count | Should -Be 4
        $rows[0].enforcement_id | Should -Be 'lin-carried-stale'
        Test-Path -LiteralPath $sentinelPath | Should -BeFalse
    }

    It 'a live (non-consumed, non-latched) enforcement at the SAME boot id (same-boot rerun) carries the existing enforcement/count forward rather than overriding or minting fresh' {
        Write-RestartState -Path (Join-Path $script:dir 'restart-state.json') -EnforcementId 'lin-carry' -ConfigVersion '1.0.0' -RebootPending $true -PreRebootBootId 'boot-current' -RebootCount 7

        $r = Invoke-RealResumeClassification -LogDir $script:dir -configVersion '1.0.0' -runsLog $script:runsLog

        $r.ResumedThisRun | Should -BeFalse
        $r.EnforcementActive | Should -BeTrue
        $r.EnforcementId | Should -Be 'lin-carry'
        $r.CountIncoming | Should -Be 7
    }

    It 'a config_version CHANGE since the enforcement was written retires it (deletes restart-state) and mints a fresh enforcement -- no override' {
        $statePath = Join-Path $script:dir 'restart-state.json'
        Write-RestartState -Path $statePath -EnforcementId 'lin-old-config' -ConfigVersion '1.0.0' -RebootPending $true -PreRebootBootId 'boot-old' -RebootCount 2

        $r = Invoke-RealResumeClassification -LogDir $script:dir -configVersion '2.0.0' -runsLog $script:runsLog

        $r.ResumedThisRun | Should -BeFalse
        $r.EnforcementActive | Should -BeFalse
        $r.EnforcementId | Should -Not -Be 'lin-old-config'
        Test-Path -LiteralPath $statePath | Should -BeFalse
    }

    It 'a LATCHED enforcement at the same config carries forward with LoopLatchedIncoming=true (so the cap/latch gate ignores further requests this run too)' {
        Write-RestartState -Path (Join-Path $script:dir 'restart-state.json') -EnforcementId 'lin-latched' -ConfigVersion '1.0.0' -RebootPending $false -LoopLatched $true -PreRebootBootId 'boot-current' -RebootCount 10

        $r = Invoke-RealResumeClassification -LogDir $script:dir -configVersion '1.0.0' -runsLog $script:runsLog

        $r.EnforcementActive | Should -BeTrue
        $r.EnforcementId | Should -Be 'lin-latched'
        $r.LoopLatchedIncoming | Should -BeTrue
        $r.CountIncoming | Should -Be 10
    }

    It 'a SPENT (consumed: non-pending, non-latched) enforcement at the same config is NOT carried forward -- it mints a fresh enforcement_id so consecutive non-terminal runs stop sharing one id (the stuck-remediation_failed prod bug)' {
        Write-RestartState -Path (Join-Path $script:dir 'restart-state.json') -EnforcementId 'lin-spent' -ConfigVersion '1.0.0' -RebootPending $false -LoopLatched $false -PreRebootBootId 'boot-current' -RebootCount 1

        $r = Invoke-RealResumeClassification -LogDir $script:dir -configVersion '1.0.0' -runsLog $script:runsLog

        $r.ResumedThisRun | Should -BeFalse
        $r.EnforcementActive | Should -BeFalse
        $r.EnforcementId | Should -Not -Be 'lin-spent'
        [Guid]::TryParse($r.EnforcementId, [ref]([Guid]::Empty)) | Should -BeTrue
        $r.CountIncoming | Should -Be 0
    }
}

Describe 'Cap + latch decided AT REQUEST-DETECTION TIME (real dot-sourced break-check + gate, Invoke-Enforcement.ps1 ~L535 / ~L661-683)' {

    It 'reboot_count=9 (next would be 10, the cap): an Immediate request on fragment 2 of 4 sets RebootPending and BREAKS the loop -- fragments 3/4 never visited' {
        $r = Invoke-RealFragmentLoopGate -FragmentNames @('Frag1', 'Frag2', 'Frag3', 'Frag4') -RebootCap 10 -RebootCountIncoming 9 -ImmediateOnFragment 'Frag2'

        $r.RebootPending | Should -BeTrue
        $r.RebootLoopLatched | Should -BeFalse
        $r.Visited | Should -Be @('Frag1', 'Frag2')
    }

    It 'reboot_count=10 (AT the cap): an Immediate request on fragment 2 of 4 LATCHES (never breaks) -- all 4 fragments are visited' {
        $r = Invoke-RealFragmentLoopGate -FragmentNames @('Frag1', 'Frag2', 'Frag3', 'Frag4') -RebootCap 10 -RebootCountIncoming 10 -ImmediateOnFragment 'Frag2'

        $r.RebootPending | Should -BeFalse
        $r.RebootLoopLatched | Should -BeTrue
        $r.Visited | Should -Be @('Frag1', 'Frag2', 'Frag3', 'Frag4')
    }

    It 'an incoming latch (carried forward from a prior capped run) ignores a fresh Immediate request entirely -- never breaks, never re-latches via the count path, all fragments visited' {
        $r = Invoke-RealFragmentLoopGate -FragmentNames @('Frag1', 'Frag2', 'Frag3') -RebootCap 10 -RebootCountIncoming 3 -RebootLoopLatchedIncoming $true -ImmediateOnFragment 'Frag1'

        $r.RebootPending | Should -BeFalse
        $r.RebootLoopLatched | Should -BeTrue
        $r.Visited | Should -Be @('Frag1', 'Frag2', 'Frag3')
    }

    It 'no Immediate request anywhere: no break, no latch, no pending -- every fragment runs to completion' {
        $r = Invoke-RealFragmentLoopGate -FragmentNames @('Frag1', 'Frag2', 'Frag3') -RebootCap 10 -RebootCountIncoming 0 -ImmediateOnFragment ''

        $r.RebootPending | Should -BeFalse
        $r.RebootLoopLatched | Should -BeFalse
        $r.Visited | Should -Be @('Frag1', 'Frag2', 'Frag3')
    }

    It 'reboot_count exactly at the boundary (9 -> 10 is allowed, NOT capped): the request is honored as a real pending reboot, not retired' {
        $r = Invoke-RealFragmentLoopGate -FragmentNames @('Frag1', 'Frag2') -RebootCap 10 -RebootCountIncoming 9 -ImmediateOnFragment 'Frag1'
        $r.RebootPending | Should -BeTrue
        $r.RebootLoopLatched | Should -BeFalse
    }
}

Describe 'Outcome derivation override + exit-code force (real dot-sourced ~L1293-1300)' {

    It 'RebootLoopLatched -> outcome forced to reboot_loop_detected, overriding any underlying 7-way outcome' {
        $r = Invoke-RealOutcomeOverride -outcome 'compliant' -exitCode 0 -RebootLoopLatched $true
        $r.Outcome | Should -Be 'reboot_loop_detected'
    }

    It 'RebootLoopLatched -> exit code is forced nonzero even if the underlying run computed exitCode=0 (so naive exit-code monitors catch a latched host too)' {
        $r = Invoke-RealOutcomeOverride -outcome 'compliant' -exitCode 0 -RebootLoopLatched $true
        $r.ExitCode | Should -Be 1
    }

    It 'RebootPending (not latched) -> outcome forced to reboot_pending' {
        $r = Invoke-RealOutcomeOverride -outcome 'remediated' -exitCode 0 -RebootPending $true
        $r.Outcome | Should -Be 'reboot_pending'
    }

    It 'RebootLoopLatched takes priority over RebootPending when (defensively) both are somehow set' {
        $r = Invoke-RealOutcomeOverride -outcome 'compliant' -exitCode 0 -RebootLoopLatched $true -RebootPending $true
        $r.Outcome | Should -Be 'reboot_loop_detected'
    }

    It 'neither latched nor pending -> the underlying 7-way outcome and exit code pass through UNCHANGED' {
        $r = Invoke-RealOutcomeOverride -outcome 'drift_persisted' -exitCode 1
        $r.Outcome | Should -Be 'drift_persisted'
        $r.ExitCode | Should -Be 1

        $r2 = Invoke-RealOutcomeOverride -outcome 'compliant' -exitCode 0
        $r2.ExitCode | Should -Be 0
    }
}

Describe 'Terminal latch / resumed-effort-retires-restart-state, any outcome (real dot-sourced ~L1419-1424)' {

    BeforeEach {
        $script:statePath = Join-Path $TestDrive ("terminal-{0}.json" -f ([Guid]::NewGuid().ToString('N')))
    }

    It 'RebootLoopLatched=true -> Invoke-OrchestratorRebootLatch retires the enforcement (reboot_pending=false, loop_latched=true) regardless of outcome' {
        Write-RestartState -Path $script:statePath -EnforcementId 'lin-cap' -ConfigVersion '1.0.0' -RebootPending $false -RebootCount 10

        Invoke-RealTerminalLatchBranch -restartStatePath $script:statePath -outcome 'reboot_loop_detected' -RebootLoopLatched $true -EnforcementId 'lin-cap' -RebootCountIncoming 10

        $state = Get-Content -LiteralPath $script:statePath -Raw | ConvertFrom-Json
        $state.loop_latched | Should -BeTrue
        $state.reboot_pending | Should -BeFalse
        $state.reboot_count | Should -Be 10
    }

    It 'a RESUMED effort finishing without another reboot deletes the restart-state -- any outcome (compliant)' {
        Write-RestartState -Path $script:statePath -EnforcementId 'lin-done' -ConfigVersion '1.0.0' -RebootPending $false -RebootCount 4

        Invoke-RealTerminalLatchBranch -restartStatePath $script:statePath -outcome 'compliant' -ResumedThisRun $true -EnforcementId 'lin-done' -RebootCountIncoming 4

        Test-Path -LiteralPath $script:statePath | Should -BeFalse
    }

    It 'a RESUMED effort that ends NON-compliant (remediation_failed) STILL deletes the restart-state -- reboot bookkeeping is not tied to enforcement compliance (the stuck-host bug)' {
        Write-RestartState -Path $script:statePath -EnforcementId 'lin-stuck' -ConfigVersion '1.0.0' -RebootPending $false -RebootCount 1

        Invoke-RealTerminalLatchBranch -restartStatePath $script:statePath -outcome 'remediation_failed' -ResumedThisRun $true -EnforcementId 'lin-stuck' -RebootCountIncoming 1

        Test-Path -LiteralPath $script:statePath | Should -BeFalse
    }

    It 'a run that did NOT resume a reboot (resumedThisRun=false) does NOT delete the restart-state -- a still-pending or latched effort is preserved' {
        Write-RestartState -Path $script:statePath -EnforcementId 'lin-keep' -ConfigVersion '1.0.0' -RebootPending $false -RebootCount 1

        Invoke-RealTerminalLatchBranch -restartStatePath $script:statePath -outcome 'compliant' -ResumedThisRun $false

        Test-Path -LiteralPath $script:statePath | Should -BeTrue
    }
}

Describe 'Unreached-fragment accounting on an actual-reboot early break (real dot-sourced ~L1241-1266) -- closes the no-early-break / 5-bucket invariant gap' {

    It 'an early break after fragment index 0 of 3 folds the 2 UNRUN fragments worth of declared resources into total/unevaluated, not the visited one' {
        $frag1Path = Join-Path $TestDrive 'frag1.dsc.yaml'
        $frag2Path = Join-Path $TestDrive 'frag2.dsc.yaml'
        $frag3Path = Join-Path $TestDrive 'frag3.dsc.yaml'
        New-FragmentYamlFixture -Path $frag1Path -ResourceCount 2
        New-FragmentYamlFixture -Path $frag2Path -ResourceCount 2
        New-FragmentYamlFixture -Path $frag3Path -ResourceCount 2
        $fragments = @(
            [pscustomobject]@{ Name = 'Frag1'; Path = $frag1Path },
            [pscustomobject]@{ Name = 'Frag2'; Path = $frag2Path },
            [pscustomobject]@{ Name = 'Frag3'; Path = $frag3Path }
        )
        $resourcesLog = Join-Path $TestDrive ("resources-{0}.jsonl" -f ([Guid]::NewGuid().ToString('N')))

        $r = Invoke-RealUnreachedFragmentAccounting -fragments $fragments -fragmentLoopIndex 0 -resourcesLog $resourcesLog -RebootPending $true

        # 2 unrun fragments * 2 declared resources each = 4.
        $r.AggTotalReal | Should -Be 4
        $r.AggUnevaluated | Should -Be 4
        $rows = @(Get-Content -LiteralPath $resourcesLog | ForEach-Object { $_ | ConvertFrom-Json })
        $rows.Count | Should -Be 4
        @($rows | Select-Object -ExpandProperty fragment -Unique) | Should -Be @('Frag2', 'Frag3')
        @($rows | Where-Object { $_.result -ne 'unevaluated' }) | Should -BeNullOrEmpty
    }

    It 'when RebootPending is false (no break occurred), the accounting block is a no-op -- no rows emitted at all' {
        $fragments = @(
            [pscustomobject]@{ Name = 'Frag1'; Path = 'C:\fake\frag1.dsc.yaml' },
            [pscustomobject]@{ Name = 'Frag2'; Path = 'C:\fake\frag2.dsc.yaml' }
        )
        $resourcesLog = Join-Path $TestDrive ("resources-noop-{0}.jsonl" -f ([Guid]::NewGuid().ToString('N')))

        $r = Invoke-RealUnreachedFragmentAccounting -fragments $fragments -fragmentLoopIndex 1 -resourcesLog $resourcesLog -RebootPending $false

        $r.AggTotalReal | Should -Be 0
        $r.AggUnevaluated | Should -Be 0
        Test-Path -LiteralPath $resourcesLog | Should -BeFalse
    }

    It 'a break on the LAST fragment leaves nothing unrun -- zero rows emitted' {
        $fragments = @(
            [pscustomobject]@{ Name = 'Frag1'; Path = 'C:\fake\frag1.dsc.yaml' },
            [pscustomobject]@{ Name = 'Frag2'; Path = 'C:\fake\frag2.dsc.yaml' }
        )
        $resourcesLog = Join-Path $TestDrive ("resources-last-{0}.jsonl" -f ([Guid]::NewGuid().ToString('N')))

        $r = Invoke-RealUnreachedFragmentAccounting -fragments $fragments -fragmentLoopIndex 1 -resourcesLog $resourcesLog -RebootPending $true

        $r.AggTotalReal | Should -Be 0
        $r.AggUnevaluated | Should -Be 0
    }
}

Describe 'Post-loop Eventual coalesced reboot (real dot-sourced ~L1268-1290) -- reboot ONCE at end of run, same cap/latch gate as Immediate' {

    It 'a single committed Eventual request promotes to a pending coalesced reboot: RebootPending, not latched, Kind=Eventual, requester carried' {
        $req = [pscustomobject]@{ Kind = 'Eventual'; RequestedBy = 'ModuleA'; RequesterId = 'ModuleA'; EnforcementId = 'enforcement-1'; ConfigVersion = '1.0.0'; RunId = 'run-1' }
        $r = Invoke-RealPostLoopEventualGate -Requests @($req)

        $r.RebootPending | Should -BeTrue
        $r.RebootLoopLatched | Should -BeFalse
        $r.RebootKind | Should -Be 'Eventual'
        $r.RebootRequestedBy | Should -Be 'ModuleA'
    }

    It 'an empty inbox is a no-op: nothing promotes, no reboot state mutates' {
        $r = Invoke-RealPostLoopEventualGate -Requests @()

        $r.RebootPending | Should -BeFalse
        $r.RebootLoopLatched | Should -BeFalse
        $r.RebootKind | Should -Be ''
        $r.RebootRequestedBy | Should -Be ''
    }

    It 'an Eventual request whose next count would exceed the cap LATCHES instead of rebooting: loop_latched, not pending' {
        $req = [pscustomobject]@{ Kind = 'Eventual'; RequestedBy = 'ModuleA'; RequesterId = 'ModuleA'; EnforcementId = 'enforcement-1'; ConfigVersion = '1.0.0'; RunId = 'run-1' }
        $r = Invoke-RealPostLoopEventualGate -Requests @($req) -RebootCap 10 -RebootCountIncoming 10

        $r.RebootLoopLatched | Should -BeTrue
        $r.RebootPending | Should -BeFalse
    }

    It 'an Eventual request under an already-carried incoming latch stays latched (never re-promotes to pending)' {
        $req = [pscustomobject]@{ Kind = 'Eventual'; RequestedBy = 'ModuleA'; RequesterId = 'ModuleA'; EnforcementId = 'enforcement-1'; ConfigVersion = '1.0.0'; RunId = 'run-1' }
        $r = Invoke-RealPostLoopEventualGate -Requests @($req) -RebootCap 10 -RebootCountIncoming 3 -RebootLoopLatchedIncoming $true

        $r.RebootLoopLatched | Should -BeTrue
        $r.RebootPending | Should -BeFalse
    }

    It 'two Eventual requests returned in reverse RequesterId order select the sort-first requester (Alpha) -- proves the real Sort-Object, not mock order' {
        $reqZeta  = [pscustomobject]@{ Kind = 'Eventual'; RequestedBy = 'ZetaModule';  RequesterId = 'Zeta';  EnforcementId = 'enforcement-1'; ConfigVersion = '1.0.0'; RunId = 'run-1' }
        $reqAlpha = [pscustomobject]@{ Kind = 'Eventual'; RequestedBy = 'AlphaModule'; RequesterId = 'Alpha'; EnforcementId = 'enforcement-1'; ConfigVersion = '1.0.0'; RunId = 'run-1' }
        $r = Invoke-RealPostLoopEventualGate -Requests @($reqZeta, $reqAlpha)

        $r.RebootRequestedBy | Should -Be 'AlphaModule'
        $r.RebootPending | Should -BeTrue
    }

    It 'only non-Eventual (Immediate) requests at the post-loop read: the Eventual gate ignores them (the mid-loop gate owns Immediate)' {
        $req = [pscustomobject]@{ Kind = 'Immediate'; RequestedBy = 'ModuleI'; RequesterId = 'ModuleI'; EnforcementId = 'enforcement-1'; ConfigVersion = '1.0.0'; RunId = 'run-1' }
        $r = Invoke-RealPostLoopEventualGate -Requests @($req)

        $r.RebootPending | Should -BeFalse
        $r.RebootLoopLatched | Should -BeFalse
        $r.RebootKind | Should -Be ''
    }

    It 'end-to-end: an Eventual request in the inbox during the fragment walk does NOT break the loop -- all fragments run, no mid-loop pending set' {
        $r = Invoke-RealFragmentLoopGate -FragmentNames @('Frag1', 'Frag2', 'Frag3') -RebootCap 10 -RebootCountIncoming 0 -ImmediateOnFragment '' -EventualInInbox

        $r.Visited | Should -Be @('Frag1', 'Frag2', 'Frag3')
        $r.RebootPending | Should -BeFalse
        $r.RebootLoopLatched | Should -BeFalse
    }
}

Describe 'RED-LINE happy-path parity: a normal run with NO reboot involvement touches NOTHING reboot-related' {

    BeforeEach {
        $script:dir = Join-Path $TestDrive ("redline-{0}" -f ([Guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $script:dir -Force | Out-Null
        $script:statePath = Join-Path $script:dir 'restart-state.json'
        $script:ripPath   = Join-Path $script:dir '.reboot-in-progress.json'
        $script:runsLog   = Join-Path $script:dir 'runs.jsonl'
        $script:regRoot   = New-RegRoot
    }

    It 'no module ever requests a reboot: Publish-DscRebootContext + Clear-DscRebootRequests + Test-OrchestratorRebootResume (real calls) leave no restart-state, no marker, no inbox entries, and calling Write-RunSummary without -EnforcementId/-RebootCount falls back to their empty/0 defaults' {
        # Real sequence a clean run takes, with no Request-DscReboot call anywhere.
        $bootId = Get-CanonicalBootId -BootTimeUtc ([datetime]'2026-05-01T00:00:00Z')
        $resume = Test-OrchestratorRebootResume -Path $script:statePath -ConfigVersion '1.0.0' -CurrentBootId $bootId
        $resume.Override | Should -BeFalse
        $resume.Reason | Should -Be 'no_state'

        Publish-DscRebootContext -EnforcementId ([Guid]::NewGuid().ToString()) -ConfigVersion '1.0.0' -RunId 'run-clean' -RegistryRoot $script:regRoot
        Clear-DscRebootRequests -RegistryRoot $script:regRoot

        Write-RunSummary -Path $script:runsLog -Timestamp ([DateTime]::UtcNow.ToString('o')) -ConfigVersion '1.0.0' -RunId 'run-clean' `
            -SchemaVersion '3.0' -Group 'pool-1' -Role 'svc-1' -DscExeVersion '1.0.0' -Mode 'enforce' -Trigger 'scheduled' `
            -Outcome 'compliant' -TotalResources 5 -CompliantResources 5 -NonCompliantCount 0 -HadErrors $false `
            -TestDuration 'PT1S' -SetDuration 'PT0S' -VerifyDuration 'PT1S' -TotalDuration 'PT2S' -ExitCode 0 -ErrorMessage ''

        # No reboot artifact of any kind was created.
        Test-Path -LiteralPath $script:statePath | Should -BeFalse
        Test-Path -LiteralPath $script:ripPath | Should -BeFalse
        $inboxRows = @(Read-DscRebootRequests -EnforcementId 'anything' -ConfigVersion '1.0.0' -RegistryRoot $script:regRoot)
        $inboxRows.Count | Should -Be 0

        $rows = (Get-EmittedRows -Path $script:runsLog)
        $rows.Count | Should -Be 1
        $rows[0].outcome | Should -Be 'compliant'
        # This call omits -EnforcementId/-RebootCount, exercising Write-RunSummary's own fallback
        # defaults; in production Invoke-Enforcement.ps1 always mints and passes an enforcement_id,
        # so every real run carries one. reboot_kind/reboot_requested_by remain state-machine-only.
        $rows[0].reboot_count | Should -Be 0
        $rows[0].enforcement_id | Should -BeNullOrEmpty
        @($rows[0].PSObject.Properties.Name) | Should -Contain 'enforcement_id'
        @($rows[0].PSObject.Properties.Name) | Should -Not -Contain 'reboot_kind'
        @($rows[0].PSObject.Properties.Name) | Should -Not -Contain 'reboot_requested_by'
    }
}

Describe 'Reboot request contract documentation' {
    It 'documents the registry inbox and commit marker' {
        $contract = Get-Content -LiteralPath $script:RebootContractPath -Raw
        $contract | Should -Match 'HKLM:\\SOFTWARE\\DscOrchestrator\\Reboot'
        $contract | Should -Match 'Complete.*last'
    }
}
