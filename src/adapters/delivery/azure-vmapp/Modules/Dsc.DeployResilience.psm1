<#
.SYNOPSIS
    Post-deploy resilience helpers for Deploy-DSCv3VMApp: confirm a VM Application actually applied,
    and retry unresolved VM deployments in fleet-wide rounds before giving up.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-DeploymentJobStateSuccessful {
    <#
    .SYNOPSIS
        Returns $true only for the exact successful deployment job state.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$State
    )

    return [string]::Equals($State, 'Completed', [System.StringComparison]::Ordinal)
}

function Test-VmAppStatusMessage {
    <#
    .SYNOPSIS
        Tests whether one CurrentState entry confirms the exact target application and version.
    .DESCRIPTION
        Accepts only the VM Application prefix and an exact Install SUCCESS or Update SUCCESS result.
    #>
    [OutputType([bool])]
    param(
        [string]$Message,
        [string]$TargetApplicationName,
        [string]$TargetVersion
    )

    if ([string]::IsNullOrWhiteSpace($Message)) { return $false }

    $prefix = 'Enable succeeded: '
    if (-not $Message.StartsWith($prefix, [System.StringComparison]::Ordinal)) { return $false }
    $json = $Message.Substring($prefix.Length)
    if ([string]::IsNullOrWhiteSpace($json)) { return $false }

    try { $state = $json | ConvertFrom-Json -ErrorAction Stop }
    catch { return $false }

    if (-not $state.PSObject.Properties['CurrentState']) { return $false }
    $entries = @($state.CurrentState)
    $matchingEntries = @($entries | Where-Object {
        $null -ne $_ -and
        $_.PSObject.Properties['applicationName'] -and
        $_.PSObject.Properties['version'] -and
        $_.PSObject.Properties['result'] -and
        [string]$_.applicationName -eq $TargetApplicationName -and
        [string]$_.version -eq $TargetVersion -and
        [string]$_.result -in @('Install SUCCESS', 'Update SUCCESS')
    })

    return $matchingEntries.Count -eq 1
}

function Test-DscV3VMAppApplied {
    <#
    .SYNOPSIS
        Tests whether the VM Application extension confirms the target version.
    .DESCRIPTION
        Re-checks instance view after an unresolved Update-AzVM job. The provider is injectable.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$ResourceGroupName,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$VmName,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$TargetApplicationName,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$TargetVersion,
        [ValidateNotNull()][scriptblock]$InstanceViewProvider = {
            param($Rg, $Name) Get-AzVM -ResourceGroupName $Rg -Name $Name -Status -ErrorAction Stop
        }
    )

    try { $iv = & $InstanceViewProvider $ResourceGroupName $VmName }
    catch { return $false }

    # Any unexpected shape counts as "not confirmed applied" rather than aborting the orchestrator.
    try {
        if ($null -eq $iv -or $null -eq $iv.Extensions) { return $false }
        foreach ($ext in @($iv.Extensions)) {
            $isVmApp = ([string]$ext.Type -match 'VMApplicationManagerWindows') -or ([string]$ext.Name -eq 'VMAppExtension')
            if (-not $isVmApp -or $null -eq $ext.Statuses) { continue }
            foreach ($status in @($ext.Statuses | Where-Object { $_.Code -eq 'ProvisioningState/succeeded' })) {
                if (Test-VmAppStatusMessage -Message ([string]$status.Message) `
                        -TargetApplicationName $TargetApplicationName -TargetVersion $TargetVersion) {
                    return $true
                }
            }
        }
    }
    catch { return $false }
    return $false
}

function Resolve-FailedVMDeployment {
    <#
    .SYNOPSIS
        Recovers unresolved VM deployments in fleet-wide concurrent retry rounds.
    .DESCRIPTION
        Re-verifies first, then runs the unresolved fleet through fixed 15s and 30s retry rounds.
        VerifyApplied, UpdateVMs, and Delay remain injectable for deterministic tests.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Failures,
        [Parameter(Mandatory = $true)][ValidateNotNull()][scriptblock]$VerifyApplied,
        [Parameter(Mandatory = $true)][ValidateNotNull()][scriptblock]$UpdateVMs,
        [ValidateNotNull()][scriptblock]$Delay = { param($Seconds) Start-Sleep -Seconds $Seconds }
    )

    $unresolved = [System.Collections.Generic.List[object]]::new()
    $retryDiagnostics = @{}
    foreach ($failure in @($Failures)) {
        if ($null -eq $failure -or
            -not $failure.PSObject.Properties['VmName'] -or
            [string]::IsNullOrWhiteSpace([string]$failure.VmName) -or
            -not $failure.PSObject.Properties['InitialError']) {
            throw 'Each failure must provide non-empty VmName and InitialError properties.'
        }
        $unresolved.Add($failure)
        $retryDiagnostics[[string]$failure.VmName] = [System.Collections.Generic.List[string]]::new()
    }

    $remaining = [System.Collections.Generic.List[object]]::new()
    foreach ($failure in $unresolved) {
        $applied = $false
        try { $applied = [bool](& $VerifyApplied ([string]$failure.VmName)) }
        catch { Write-Warning "  Verification for VM '$($failure.VmName)' errored: $($_.Exception.Message)" }

        if ($applied) {
            Write-Information "  VM '$($failure.VmName)' is confirmed applied; no retry required."
        } else {
            $remaining.Add($failure)
        }
    }
    $unresolved = $remaining

    $retryDelays = @(15, 30)
    $retry = 0
    foreach ($wait in $retryDelays) {
        if ($unresolved.Count -eq 0) { break }
        $retry++
        $vmNames = @($unresolved | ForEach-Object { [string]$_.VmName })
        Write-Information ("Retry round {0}/{1}: updating {2} unresolved VM(s) in {3}s..." -f
            $retry, $retryDelays.Count, $vmNames.Count, $wait)
        & $Delay $wait

        try {
            $roundResults = @(& $UpdateVMs $vmNames $retry)
            foreach ($result in $roundResults) {
                if ($null -eq $result -or
                    -not $result.PSObject.Properties['VmName'] -or
                    -not $result.PSObject.Properties['Error']) {
                    continue
                }
                $resultVmName = [string]$result.VmName
                if ($retryDiagnostics.ContainsKey($resultVmName)) {
                    $retryDiagnostics[$resultVmName].Add("retry $retry`: $([string]$result.Error)")
                }
            }
        }
        catch {
            $batchError = $_.Exception.Message
            Write-Warning "  Retry round $retry failed before all updates completed: $batchError"
            foreach ($vmName in $vmNames) {
                $retryDiagnostics[$vmName].Add("retry $retry batch error: $batchError")
            }
        }

        $remaining = [System.Collections.Generic.List[object]]::new()
        foreach ($failure in $unresolved) {
            $applied = $false
            try { $applied = [bool](& $VerifyApplied ([string]$failure.VmName)) }
            catch { Write-Warning "  Verification for VM '$($failure.VmName)' errored: $($_.Exception.Message)" }

            if ($applied) {
                Write-Information "  VM '$($failure.VmName)' confirmed applied after retry round $retry."
            } else {
                $remaining.Add($failure)
            }
        }
        $unresolved = $remaining
    }

    foreach ($failure in $unresolved) {
        $details = @($retryDiagnostics[[string]$failure.VmName])
        $retryDetail = if ($details.Count -gt 0) { "; retry details: $($details -join ' | ')" } else { '' }
        "VM '$($failure.VmName)': $($failure.InitialError) (still not confirmed applied after $($retryDelays.Count) Update-AzVM retries$retryDetail)"
    }
}

Export-ModuleMember -Function Test-DeploymentJobStateSuccessful, Test-DscV3VMAppApplied, Resolve-FailedVMDeployment
