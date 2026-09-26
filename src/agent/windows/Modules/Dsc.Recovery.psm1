<#
.SYNOPSIS
    Strip-and-retry convergence loop for DSCv3 enforcement (always on).
.DESCRIPTION
    DSCv3 has no continue-on-error: one resource that aborts a `dsc config` phase loses enforcement
    for every sibling in the fragment (PowerShell/DSC#656, open). Invoke-FragmentConvergence contains
    that when the failure is attributable to a single wrapper (named by Find-DscErrorSignal): it strips
    the culprit + its reverse-dependsOn closure and restarts at test against the survivors, until a
    clean converge, a terminal drift, or a guard trips.

    Real dsc execution is injected as -TestInvoker / -SetInvoker / -VerifyInvoker, so the strip/
    classify/restart logic is file-free and unit-testable. The happy path (clean pass-1 test) is the
    same single test as today; multi-pass cost is paid only when a phase actually aborts.

    Terminal drift (clean verify still shows drift -- a lying setter) is NOT strippable: report once
    and stop. Attribution is unreliable for pre-resource parse/schema failures (empty ResourceName);
    the loop bails to today's behavior on an empty/unchanged culprit or an emptied keep-set.

================================ REMOVAL RUNBOOK ================================
    Remove this layer when dsc ships continue-on-error (PowerShell/DSC#656):
      1. Delete this file (Dsc.Recovery.psm1).
      2. Dsc.Toolkit.psd1: drop the module from NestedModules and Invoke-FragmentConvergence
         from FunctionsToExport.
      3. Invoke-Enforcement.ps1: collapse the single Invoke-FragmentConvergence call back to a linear
         test -> (targeted) set -> verify run once each -- the injected -SetInvoker/-VerifyInvoker
         closures become direct Invoke-DscSet / Invoke-DscTestJson calls, and the strip/restart goes
         away (no phase aborts the fragment any more). Keep the single final-state emit block.
      4. Optionally delete New-StrippedConfigExcludingResources (+ export); keep
         New-FilteredConfigForResources (targeted set) -- it is needed independently of recovery.
      5. Verify Invoke-Enforcement.ps1 parses and the 4-bucket invariant still holds.
================================================================================
.NOTES
    Always on: the happy path remains a single test + one targeted set + one verify per fragment.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'


function script:Write-OptionalReasonDiagnostic {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object]$Text)

    try {
        Write-NativeStderr $Text
    } catch {
        # A failed diagnostic write cannot be allowed to fail convergence; swallow it.
        $null = $_
    }
}


function Invoke-FragmentConvergence {
    <#
    .SYNOPSIS
        Converges one fragment (test -> targeted set -> verify), stripping an attributable abort's
        culprit + reverse-dependsOn closure and restarting at test. Returns the final-pass state.
    .DESCRIPTION
        Pass 1 runs the original config; a clean test with no drift returns immediately (one
        Invoke-DscTestJson). On drift it runs a targeted set then verify. On an attributable abort at
        any phase it strips the culprit + closure and restarts at test against the survivors, up to
        MaxPasses; the abort -> classify -> strip-or-bail decision lives once in Step-ConvergenceAbort.

        Terminal drift (clean verify still shows drift -- a lying setter) returns
        Outcome='drift_persisted' without restarting. It bails (Recovered=$false, Outcome='bail') on
        an empty culprit (unattributable), an already-quarantined culprit (no_shrink), an emptied or
        failed strip (fully_stripped / strip_failed), or MaxPasses.

        Set rows are buffered by the set invoker and returned (FinalSetRows), so an intermediate
        (stripped) pass's rows are discarded on restart and only the final set's are carried out.
    .PARAMETER DscExePath
        Full path to dsc.exe (forwarded to the invokers).
    .PARAMETER ConfigFilePath
        Full path to the fragment's *.dsc.yaml.
    .PARAMETER MaxPasses
        Hard cap on convergence passes (default 10, ceiling 50). Bounds the failure path.
    .PARAMETER EnableSet
        When $false (AuditOnly / WhatIf), the loop still strips test aborts but reports observed drift
        without running set/verify (Outcome='converged', Phase='test', FinalVerify=$null).
    .PARAMETER TestInvoker
        Scriptblock (DscExePath, ConfigFilePath) -> Invoke-DscTestJson-shaped object. Injectable for tests.
    .PARAMETER SetInvoker
        Scriptblock (DscExePath, ConfigFilePath, ParsedTest) -> Invoke-DscSet-shaped object
        (.Native/.Parsed/.Errored/.Aborted/.Unreached/.BufferedRows). No safe default -- must be injected.
    .PARAMETER VerifyInvoker
        Scriptblock (DscExePath, ConfigFilePath) -> Invoke-DscTestJson-shaped object. Injectable for tests.
    .PARAMETER TestGetInvoker
        Scriptblock (DscExePath, ConfigFilePath, string[] DriftedNames) -> parsed get envelope or $null.
        Runs after a clean drifted TEST and BEFORE set, so test-phase rows are enriched with the state
        TEST observed rather than post-remediation state. Defaults to a no-op returning $null.
    .OUTPUTS
        [pscustomobject] with TestInvocation (== FinalTest), EffectiveConfigPath/IsTemp,
        QuarantinedResources, Culprits, CulpritDetails ({Name,Type,Excerpt,ExitCode,Phase} per named culprit),
        PassCount, Recovered, BailReason, Phase ('test'|'set'|'verify'), FinalTest, FinalVerify (null
        if no set ran), TestGet (pre-set get envelope for reasons, null when unavailable), SetErrored,
        FinalSetRows (the final set's buffered rows), and Outcome
        ('converged'|'drift_persisted'|'bail').
    .EXAMPLE
        $rec = Invoke-FragmentConvergence -DscExePath $dscExe -ConfigFilePath $configFile `
            -SetInvoker $setClosure -VerifyInvoker $verifyClosure
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$DscExePath,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ConfigFilePath,
        [Parameter()][ValidateRange(1, 50)][int]$MaxPasses = 10,
        [Parameter()][bool]$EnableSet = $true,
        [Parameter()][ValidateNotNull()][scriptblock]$TestInvoker = ${function:Invoke-DscTestJson},
        # No safe default: a bare Invoke-DscSet would set with no abort detection and no telemetry.
        # The enforcement body and every unit test inject a real seam; the default just fails loud.
        [Parameter()][ValidateNotNull()][scriptblock]$SetInvoker = {
            throw 'Invoke-FragmentConvergence: inject a -SetInvoker; the default provides no set-phase recovery.'
        },
        [Parameter()][ValidateNotNull()][scriptblock]$VerifyInvoker = ${function:Invoke-DscTestJson},
        # Default is a no-op so existing callers retain their prior behavior.
        [Parameter()][ValidateNotNull()][scriptblock]$TestGetInvoker = { $null }
    )

    # One mutable state bag so the abort gate and result builder share it without 3x copy-paste.
    $ctx = @{
        Effective          = $ConfigFilePath
        IsTemp             = $false
        # Ordered, de-duplicated quarantine set (culprits + their reverse-dependsOn closures).
        Quarantine         = New-Object System.Collections.Generic.List[string]
        QuarantineSeen     = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        # Attributed culprits only (the named failing wrappers, not their stripped dependents).
        Culprits           = New-Object System.Collections.Generic.List[string]
        # Per-culprit forensics captured from the pass that NAMED the culprit, de-duplicated.
        CulpritDetails     = New-Object System.Collections.Generic.List[object]
        CulpritDetailsSeen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        Pass               = 0
        MaxPasses          = $MaxPasses
        # Final-pass invocations + set outputs; reset each pass so a restart discards the aborted set.
        LastTest           = $null
        LastTestGet        = $null
        LastVerify         = $null
        LastSetErrored     = @()
        LastSetRows        = @()
    }

    while ($true) {
        $ctx.Pass++
        # Reset per-pass set/verify state: on a strip/restart the aborted pass's set rows are dropped.
        $ctx.LastTestGet    = $null
        $ctx.LastVerify     = $null
        $ctx.LastSetErrored = @()
        $ctx.LastSetRows    = @()

        # ---- TEST ----
        $ctx.LastTest = & $TestInvoker $DscExePath $ctx.Effective
        if (-not (Test-CleanInvocation -Invocation $ctx.LastTest)) {
            $gate = Step-ConvergenceAbort -Ctx $ctx -Phase 'test' -Invocation $ctx.LastTest
            if ($gate.Continue) { continue }
            return $gate.Result
        }

        # Direct assignment preserves the helper's ,$array idiom (count 0 means no drift).
        $drifted = Get-DriftedTopLevelResourceNames -ParsedTest $ctx.LastTest.Parsed

        # Reason harvest belongs HERE -- after a clean drifted test, before any set. Running it after
        # convergence enriched non_compliant test rows with post-remediation state, so the reason
        # described the fixed resource while the verdict described the drifted one (ADO 16372772).
        # Harvested even when set is disabled (AuditOnly/WhatIf), which observes drift but never fixes it.
        # A throwing callback is caught below and yields no reasons: harvest failures cannot block the
        # set that follows. The callback runs synchronously, so a hung get is bounded only by the
        # scheduled task's ExecutionTimeLimit, not by this function.
        if ($drifted.Count -gt 0) {
            try {
                $ctx.LastTestGet = & $TestGetInvoker $DscExePath $ctx.Effective $drifted
            } catch {
                $ctx.LastTestGet = $null
                Write-OptionalReasonDiagnostic "[recovery] pre-set reason get threw: $($_.Exception.Message). Continuing without harvested reasons.`n"
            }
        }

        if ($drifted.Count -eq 0 -or -not $EnableSet) {
            # Converged: no drift, or drift observed while set is disabled (AuditOnly/WhatIf).
            return (New-ConvergenceResult -Ctx $ctx -Phase 'test' -Outcome 'converged')
        }

        # ---- SET (targeted: the drifted subset of effective) ----
        $set = & $SetInvoker $DscExePath $ctx.Effective $ctx.LastTest.Parsed
        $ctx.LastSetErrored = @($set.Errored)
        $ctx.LastSetRows    = @($set.BufferedRows)
        if ($set.Aborted) {
            $gate = Step-ConvergenceAbort -Ctx $ctx -Phase 'set' -Invocation $set
            if ($gate.Continue) { continue }
            return $gate.Result
        }

        # ---- VERIFY (re-test effective) ----
        $ctx.LastVerify = & $VerifyInvoker $DscExePath $ctx.Effective
        if (-not (Test-CleanInvocation -Invocation $ctx.LastVerify)) {
            $gate = Step-ConvergenceAbort -Ctx $ctx -Phase 'verify' -Invocation $ctx.LastVerify
            if ($gate.Continue) { continue }
            return $gate.Result
        }

        $verifyDrift = Get-DriftedTopLevelResourceNames -ParsedTest $ctx.LastVerify.Parsed
        if ($verifyDrift.Count -gt 0) {
            # Terminal: clean verify still shows drift (lying setter) -- not strippable, report and stop.
            return (New-ConvergenceResult -Ctx $ctx -Phase 'verify' -Outcome 'drift_persisted')
        }
        return (New-ConvergenceResult -Ctx $ctx -Phase 'verify' -Outcome 'converged')
    }
}


function script:Test-CleanInvocation {
    # A test/verify invocation is clean iff it parsed, exited 0, and reported no errors.
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Invocation)
    $parsed = $Invocation.Parsed
    return ($null -ne $parsed -and [int]$Invocation.Native.ExitCode -eq 0 -and -not $parsed.HadErrors)
}


function script:Add-CulpritDetail {
    # Capture per-culprit forensics (first-error-wins per resource name) for telemetry parity.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Ctx,
        [Parameter(Mandatory)][object]$Signal,
        [Parameter(Mandatory)][int]$Exit,
        [Parameter(Mandatory)][ValidateSet('test','set','verify')][string]$Phase
    )
    $culprit = [string]$Signal.ResourceName
    if ([string]::IsNullOrWhiteSpace($culprit)) { return }
    if (-not $Ctx.CulpritDetailsSeen.Add($culprit)) { return }
    $Ctx.CulpritDetails.Add([pscustomobject]@{
        Name     = $culprit
        Type     = [string]$Signal.ResourceType
        Excerpt  = [string]$Signal.Excerpt
        ExitCode = $Exit
        Phase    = $Phase
    }) | Out-Null
}


function script:Step-ConvergenceAbort {
    # The one abort -> classify -> strip/bail gate, parameterized by phase. Returns
    # @{ Continue = <restart at test?>; Result = <bail result to return, or $null> }.
    # On STRIP it mutates $Ctx (quarantine/culprits/culpritDetails/Effective/IsTemp) and signals
    # Continue=$true. On a guard trip it returns Continue=$false plus the fully-built bail result.
    # ClassifyAbort order (preserved): max_passes -> unattributable -> no_shrink -> strip.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Ctx,
        [Parameter(Mandatory)][ValidateSet('test', 'set', 'verify')][string]$Phase,
        [Parameter(Mandatory)][object]$Invocation
    )

    $signal  = Find-DscErrorSignal -Stderr $Invocation.Native.Stderr
    $culprit = [string]$signal.ResourceName
    $exit    = [int]$Invocation.Native.ExitCode

    if ($Ctx.Pass -ge $Ctx.MaxPasses) {
        # Capture pass N's culprit for telemetry even though we won't strip it.
        Add-CulpritDetail -Ctx $Ctx -Signal $signal -Exit $exit -Phase $Phase
        return @{ Continue = $false; Result = (New-ConvergenceResult -Ctx $Ctx -Phase $Phase -Outcome 'bail' -BailReason 'max_passes') }
    }
    if ([string]::IsNullOrWhiteSpace($culprit)) {
        # No activity event -> unattributable (parse/schema failure, mode b). Do NOT strip blind.
        return @{ Continue = $false; Result = (New-ConvergenceResult -Ctx $Ctx -Phase $Phase -Outcome 'bail' -BailReason 'unattributable') }
    }
    if ($Ctx.QuarantineSeen.Contains($culprit)) {
        # Same resource failing after being stripped -> environmental, not the resource.
        return @{ Continue = $false; Result = (New-ConvergenceResult -Ctx $Ctx -Phase $Phase -Outcome 'bail' -BailReason 'no_shrink') }
    }

    try {
        $stripped = New-StrippedConfigExcludingResources -SourcePath $Ctx.Effective -ExcludeResourceNames @($culprit)
    } catch {
        $reason = if ($_.Exception.Message -match 'leaves no resources') { 'fully_stripped' } else { 'strip_failed' }
        Write-NativeStderr "[recovery] strip failed on pass $($Ctx.Pass) (culprit '$culprit'): $($_.Exception.Message)`n"
        return @{ Continue = $false; Result = (New-ConvergenceResult -Ctx $Ctx -Phase $Phase -Outcome 'bail' -BailReason $reason) }
    }

    $Ctx.Culprits.Add($culprit)
    Add-CulpritDetail -Ctx $Ctx -Signal $signal -Exit $exit -Phase $Phase
    foreach ($name in $stripped.ExcludedNames) {
        if ($Ctx.QuarantineSeen.Add([string]$name)) { $Ctx.Quarantine.Add([string]$name) }
    }

    # Overwrite-per-pass: only one recovery temp exists at a time.
    if ($Ctx.IsTemp -and (Test-Path -LiteralPath $Ctx.Effective)) {
        Remove-Item -LiteralPath $Ctx.Effective -Force -ErrorAction SilentlyContinue
    }
    $Ctx.Effective = $stripped.Path
    $Ctx.IsTemp    = $true
    Write-NativeStderr ("[recovery] pass {0}: stripped '{1}' (+{2} dependent(s)) on {3} abort; restarting at test on {4} surviving wrapper(s).`n" -f `
        $Ctx.Pass, $culprit, ([Math]::Max(0, $stripped.ExcludedNames.Count - 1)), $Phase, $stripped.KeptNames.Count)
    return @{ Continue = $true; Result = $null }
}


function script:New-ConvergenceResult {
    # The one result builder for every return site. Reads the final-pass state from $Ctx so the
    # converged / drift_persisted / bail shapes never diverge. Bails also surface the reason to stderr.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Ctx,
        [Parameter(Mandatory)][ValidateSet('test', 'set', 'verify')][string]$Phase,
        [Parameter(Mandatory)][ValidateSet('converged', 'drift_persisted', 'bail')][string]$Outcome,
        [Parameter()][string]$BailReason = ''
    )
    if ($Outcome -eq 'bail') {
        Write-NativeStderr "[recovery] bail after $($Ctx.Pass) pass(es): ${BailReason}. Falling back to standard fragment-failure handling.`n"
    }
    return [pscustomobject]@{
        TestInvocation        = $Ctx.LastTest
        EffectiveConfigPath   = $Ctx.Effective
        EffectiveConfigIsTemp = $Ctx.IsTemp
        QuarantinedResources  = @($Ctx.Quarantine.ToArray())
        Culprits              = @($Ctx.Culprits.ToArray())
        CulpritDetails        = @($Ctx.CulpritDetails.ToArray())
        PassCount             = $Ctx.Pass
        Recovered             = ($Outcome -ne 'bail' -and $Ctx.Quarantine.Count -gt 0)
        BailReason            = $BailReason
        Phase                 = $Phase
        FinalTest             = $Ctx.LastTest
        TestGet               = $Ctx.LastTestGet
        FinalVerify           = $Ctx.LastVerify
        SetErrored            = @($Ctx.LastSetErrored)
        FinalSetRows          = @($Ctx.LastSetRows)
        Outcome               = $Outcome
    }
}


Export-ModuleMember -Function Invoke-FragmentConvergence
