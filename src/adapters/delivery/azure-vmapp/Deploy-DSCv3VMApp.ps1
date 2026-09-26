#Requires -Version 5.1

<#
.SYNOPSIS
    Attaches or replaces a VM Application version on selected VMs in a resource group.

.DESCRIPTION
    Typed Az.Compute model objects ([PSApplicationProfile]/[PSVMGalleryApplication]) avoid
    hashtable coercion bugs across Az.Compute versions. Order calculation uses Max+1 for new
    apps, preserves original Order when replacing. Exact prefix match ($id -eq $base or
    $id.StartsWith("$base/")) prevents '/apps/foo' from matching '/apps/foo-bar'. Az.Compute
    model types are resolved after an Az.Compute cmdlet is invoked. ShouldProcess on all
    mutations supports -WhatIf/-Confirm.

    Use an Az.Compute version that supports VM Application profile updates.

.PARAMETER ResourceGroupName
    Resource group containing target VMs.

.PARAMETER VMNames
    Optional explicit VM names within ResourceGroupName. When omitted, all VMs in the
    resource group are targeted.

.PARAMETER VMAppVersionResourceId
    Full ARM id of gallery-application-version:
    /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Compute/galleries/{gal}/applications/{app}/versions/{ver}

.PARAMETER SubscriptionId
    Optional. Current Az context must match; never switched silently.

.EXAMPLE
    $version = .\Get-DSCv3LatestVMAppVersion.ps1 -GalleryName gallery -GalleryResourceGroup gallery-rg -ApplicationName sample-app
    .\Deploy-DSCv3VMApp.ps1 -ResourceGroupName workload-rg -VMNames @('vm01', 'vm02') `
        -VMAppVersionResourceId $version.VMAppVersionId -WhatIf
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]]$VMNames,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\.Compute/galleries/[^/]+/applications/[^/]+/versions/\d+\.\d+\.\d+$')]
    [string]$VMAppVersionResourceId,

    [Parameter()]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
# Non-interactive callers can't answer ShouldProcess prompts. -WhatIf still works; this suppresses confirms.
$ConfirmPreference = 'None'

$ApplicationBaseId = $VMAppVersionResourceId -replace '/versions/[^/]+$', ''

if ($VMAppVersionResourceId -notmatch '^/subscriptions/(?<sub>[^/]+)/resourceGroups/(?<rg>[^/]+)/providers/Microsoft\.Compute/galleries/(?<gal>[^/]+)/applications/(?<app>[^/]+)/versions/(?<ver>[^/]+)$') {
    throw "VMAppVersionResourceId failed structural parsing after ValidatePattern passed. Value: $VMAppVersionResourceId"
}
$galRgName = $Matches.rg
$galName   = $Matches.gal
$galAppName = $Matches.app
$galVerName = $Matches.ver

. "$PSScriptRoot/Assert-AzContext.ps1"
Import-Module (Join-Path $PSScriptRoot 'Modules\Dsc.DeployResilience.psm1') -Force -DisableNameChecking

function ConvertTo-VMGalleryApplication {
    <#
    .SYNOPSIS
        Returns typed PSVMGalleryApplication. TreatFailureAsDeploymentFailure=$true
        so bad DSCv3 payloads fail VM deployment instead of silently succeeding.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)][string]$PackageReferenceId,
        [Parameter(Mandatory = $true)][int]   $Order
    )

    $applicationType = 'Microsoft.Azure.Commands.Compute.Automation.Models.PSVMGalleryApplication' -as [type]
    if ($null -eq $applicationType) {
        throw 'Az.Compute VM Application types are unavailable. Ensure Az.Compute is imported before updating VMs.'
    }

    $app = [System.Activator]::CreateInstance($applicationType)
    $app.PackageReferenceId              = $PackageReferenceId
    $app.Order                           = $Order
    $app.TreatFailureAsDeploymentFailure = $true
    return $app
}

function Get-MaxOrder {
    <#
    .SYNOPSIS
        Returns largest Order from VMGalleryApplications or 0 if empty. StrictMode-safe.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter()]
        [AllowNull()]
        $Apps
    )

    if ($null -eq $Apps) { return 0 }

    $orders = @()
    foreach ($a in $Apps) {
        if ($null -ne $a -and $a.PSObject.Properties.Name -contains 'Order' -and $null -ne $a.Order) {
            $orders += [int]$a.Order
        }
    }
    if ($orders.Count -eq 0) { return 0 }
    return ($orders | Measure-Object -Maximum).Maximum
}

function ConvertTo-VMGalleryApplicationProfile {
    <#
    .SYNOPSIS
        Rebuilds ApplicationProfile: removes existing app matching base id (exact or /-prefixed),
        preserves Order, appends new version.
    .OUTPUTS
        An Az.Compute PSApplicationProfile object.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$ExistingProfile,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$NewPackageReferenceId,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ApplicationBaseId
    )

    $preserved = [System.Collections.Generic.List[object]]::new()
    $replacedOrder = $null

    $existingApps = $null
    if ($null -ne $ExistingProfile -and $ExistingProfile.PSObject.Properties.Name -contains 'GalleryApplications') {
        $existingApps = $ExistingProfile.GalleryApplications
    }

    if ($null -ne $existingApps) {
        foreach ($app in $existingApps) {
            if ($null -eq $app -or [string]::IsNullOrEmpty($app.PackageReferenceId)) { continue }

            $id = $app.PackageReferenceId
            $isSameApp = ($id -eq $ApplicationBaseId) -or
                         $id.StartsWith("$ApplicationBaseId/", [System.StringComparison]::OrdinalIgnoreCase)

            if ($isSameApp) {
                # Preserve Order so replacement keeps rollout sequence slot.
                if ($app.PSObject.Properties.Name -contains 'Order' -and $null -ne $app.Order) {
                    $replacedOrder = [int]$app.Order
                }
                continue
            }
            $preserved.Add($app)
        }
    }

    $newOrder = if ($null -ne $replacedOrder) { $replacedOrder } else { (Get-MaxOrder -Apps $preserved) + 1 }
    $newApp   = ConvertTo-VMGalleryApplication -PackageReferenceId $NewPackageReferenceId -Order $newOrder
    $preserved.Add($newApp)

    $applicationType = 'Microsoft.Azure.Commands.Compute.Automation.Models.PSVMGalleryApplication' -as [type]
    $profileType = 'Microsoft.Azure.Commands.Compute.Automation.Models.PSApplicationProfile' -as [type]
    if ($null -eq $applicationType -or $null -eq $profileType) {
        throw 'Az.Compute VM Application types are unavailable. Ensure Az.Compute is imported before updating VMs.'
    }

    $galleryApplicationsType = [System.Collections.Generic.List``1].MakeGenericType($applicationType)
    $galleryApplications = [System.Activator]::CreateInstance($galleryApplicationsType)
    foreach ($app in $preserved) {
        $galleryApplications.Add($app)
    }

    $appProfile = [System.Activator]::CreateInstance($profileType)
    $appProfile.GalleryApplications = $galleryApplications
    return $appProfile
}

function Start-VMUpdateJob {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The entry point gates initial updates with ShouldProcess; recovery retries are part of that approved operation.'
    )]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [object]$VM
    )

    $updateParameters = @{
        ResourceGroupName = $ResourceGroupName
        VM                = $VM
        AsJob             = $true
        ErrorAction       = 'Stop'
    }

    # Az's -AsJob can block waiting for input when called with ConfirmPreference='None' from a ShouldProcess script.
    & {
        $ConfirmPreference = 'High'
        Update-AzVM @updateParameters
    }
}

function Complete-VMUpdateRound {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Jobs,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Activity
    )

    if ($Jobs.Count -eq 0) { return }

    $failures = [System.Collections.Generic.List[object]]::new()
    try {
        Write-Information "Waiting for $($Jobs.Count) parallel $Activity job(s); reporting each as it finishes..."
        $pending = @($Jobs)
        $done = 0
        while ($pending.Count -gt 0) {
            $null = Wait-Job -Job $pending -Any
            $stillPending = @()
            foreach ($job in $pending) {
                if ($job.State -eq 'Running' -or $job.State -eq 'NotStarted') {
                    $stillPending += $job
                    continue
                }
                $done++
                $status = if (Test-DeploymentJobStateSuccessful -State $job.State) {
                    'succeeded'
                } else {
                    ([string]$job.State).ToLower()
                }
                Write-Information ("  [{0}/{1}] {2}: {3}" -f $done, $Jobs.Count, $job.VmName, $status)
            }
            $pending = @($stillPending)
        }

        foreach ($job in $Jobs) {
            $jobErrors = @()
            $receiveError = $null
            try { $null = Receive-Job -Job $job -ErrorAction SilentlyContinue -ErrorVariable jobErrors }
            catch { $receiveError = $_.Exception.Message }

            if (Test-DeploymentJobStateSuccessful -State $job.State) { continue }

            $childJobs = @($job.ChildJobs)
            $reason = if ($receiveError) { $receiveError }
                elseif (@($jobErrors).Count -gt 0) { (@($jobErrors) | ForEach-Object { $_.ToString() }) -join ' | ' }
                elseif ($childJobs.Count -gt 0 -and $null -ne $childJobs[0].JobStateInfo.Reason) { $childJobs[0].JobStateInfo.Reason.Message }
                elseif ($null -ne $job.JobStateInfo.Reason) { $job.JobStateInfo.Reason.Message }
                else { "no failure detail available; ChildJobs.Count=$($childJobs.Count)" }
            $failures.Add([pscustomobject]@{ VmName = [string]$job.VmName; Error = "State=$($job.State): $reason" })
        }
    }
    finally {
        foreach ($job in $Jobs) { $null = Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
    }

    return @($failures)
}

Write-Information "=== Deploy-DSCv3VMApp ==="
Write-Information ("ResourceGroupName      : {0}" -f $ResourceGroupName)
if ($PSBoundParameters.ContainsKey('VMNames')) {
    Write-Information ("VMNames               : {0}" -f ($VMNames -join ', '))
}
Write-Information ("VMAppVersionResourceId : {0}" -f $VMAppVersionResourceId)
Write-Information ("ApplicationBaseId      : {0}" -f $ApplicationBaseId)

$ctx = Assert-AzContext -ExpectedSubscriptionId $SubscriptionId
Write-Verbose "Az context OK (subscription=$($ctx.Subscription.Id), account=$($ctx.Account.Id))."

try {
    $null = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction Stop
}
catch {
    throw "Resource group '$ResourceGroupName' not found (or identity '$($ctx.Account.Id)' lacks read access) in subscription '$($ctx.Subscription.Id)': $($_.Exception.Message)"
}

$vms = @()
if ($PSBoundParameters.ContainsKey('VMNames')) {
    $seenVmNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($vmName in $VMNames) {
        if ([string]::IsNullOrWhiteSpace($vmName)) {
            throw 'VMNames must not contain null, empty, or whitespace-only entries.'
        }
        if (-not $seenVmNames.Add($vmName)) {
            throw "VMNames contains duplicate entry '$vmName'."
        }

        try {
            $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $vmName -ErrorAction Stop
        }
        catch {
            throw "Failed to retrieve requested VM '$vmName' in resource group '$ResourceGroupName': $($_.Exception.Message)"
        }
        if ($null -eq $vm) {
            throw "Requested VM '$vmName' was not found in resource group '$ResourceGroupName'."
        }
        $vms += $vm
    }
}
else {
    try {
        $vmsResult = Get-AzVM -ResourceGroupName $ResourceGroupName -ErrorAction Stop
        if ($null -ne $vmsResult) { $vms = @($vmsResult) }
    }
    catch {
        throw "Failed to enumerate VMs in resource group '$ResourceGroupName' (identity '$($ctx.Account.Id)'): $($_.Exception.Message)"
    }
}

Write-Information "Found $($vms.Count) VM(s) in '$ResourceGroupName'."
if ($vms.Count -eq 0) {
    Write-Information "No target VMs found in resource group '$ResourceGroupName'; skipping VM Application assignment."
    return [pscustomobject]@{
        ResourceGroupName      = $ResourceGroupName
        VMAppVersionResourceId = $VMAppVersionResourceId
        VmCount                = 0
        VMNames                = @()
        Skipped                = $true
    }
}

# Gallery version existence check prevents most silent VM extension failures.
try {
    $null = Get-AzGalleryApplicationVersion `
        -ResourceGroupName      $galRgName `
        -GalleryName            $galName `
        -GalleryApplicationName $galAppName `
        -Name                   $galVerName `
        -ErrorAction            Stop
}
catch {
    throw "Gallery application version '$VMAppVersionResourceId' not found (or not readable by '$($ctx.Account.Id)'). Publish the version first, or verify the identity has 'Reader' on gallery '$galName' in resource group '$galRgName'. Original error: $($_.Exception.Message)"
}

# Update-AzVM blocks until VM Application extension finishes (~15-30 min). Run as jobs for concurrency.
# @() wrap: with 1 VM, foreach returns a scalar Job; $jobs.Count would fail under StrictMode.
$jobs = @(foreach ($vmSummary in $vms) {
    $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $vmSummary.Name -ErrorAction Stop
    $vm.ApplicationProfile = ConvertTo-VMGalleryApplicationProfile `
        -ExistingProfile       $vm.ApplicationProfile `
        -NewPackageReferenceId $VMAppVersionResourceId `
        -ApplicationBaseId     $ApplicationBaseId

    if (-not $PSCmdlet.ShouldProcess("VM '$($vm.Name)' in RG '$ResourceGroupName'", "Attach gallery-application-version '$galAppName/$galVerName'")) { continue }

    Start-VMUpdateJob -ResourceGroupName $ResourceGroupName -VM $vm |
        Add-Member -PassThru -NotePropertyName VmName -NotePropertyValue $vm.Name
})

$unresolvedDeployments = @(Complete-VMUpdateRound -Jobs $jobs -Activity 'initial VM update' |
    ForEach-Object { [pscustomobject]@{ VmName = $_.VmName; InitialError = $_.Error } }
)

$failures = @()
if ($unresolvedDeployments.Count -gt 0) {
    Write-Warning "$($unresolvedDeployments.Count) initial VM update job(s) did not complete; starting recovery."

    $verifyApplied = {
        param($VmName)
        Test-DscV3VMAppApplied `
            -ResourceGroupName $ResourceGroupName `
            -VmName $VmName `
            -TargetApplicationName $galAppName `
            -TargetVersion $galVerName
    }.GetNewClosure()

    $updateApplicationProfile = ${function:ConvertTo-VMGalleryApplicationProfile}
    $completeVMUpdateRound = ${function:Complete-VMUpdateRound}
    $updateVMs = {
        param([string[]]$VmNames, [int]$Retry)

        $retryJobs = [System.Collections.Generic.List[object]]::new()
        $roundResults = [System.Collections.Generic.List[object]]::new()
        foreach ($vmName in $VmNames) {
            try {
                $retryVm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $vmName -ErrorAction Stop
                $retryVm.ApplicationProfile = & $updateApplicationProfile `
                    -ExistingProfile       $retryVm.ApplicationProfile `
                    -NewPackageReferenceId $VMAppVersionResourceId `
                    -ApplicationBaseId     $ApplicationBaseId

                $retryJob = Start-VMUpdateJob -ResourceGroupName $ResourceGroupName -VM $retryVm |
                    Add-Member -PassThru -NotePropertyName VmName -NotePropertyValue $vmName
                $retryJobs.Add($retryJob)
            }
            catch {
                $errorText = $_.Exception.Message
                Write-Warning "  Retry round $Retry could not start Update-AzVM for VM '$vmName': $errorText"
                $roundResults.Add([pscustomobject]@{ VmName = $vmName; Error = $errorText })
            }
        }

        foreach ($result in @(& $completeVMUpdateRound -Jobs @($retryJobs) -Activity "retry round $Retry VM update")) {
            Write-Warning "  Retry round $Retry Update-AzVM for VM '$($result.VmName)' did not complete: $($result.Error)"
            $roundResults.Add($result)
        }

        return @($roundResults)
    }.GetNewClosure()

    $failures = @(Resolve-FailedVMDeployment `
        -Failures $unresolvedDeployments `
        -VerifyApplied $verifyApplied `
        -UpdateVMs $updateVMs)
}

if ($failures.Count -gt 0) {
    throw ("DSCv3 deploy failed on {0} of {1} VM(s):`n  - {2}" -f $failures.Count, $jobs.Count, ($failures -join "`n  - "))
}

Write-Information "=== Deploy complete ==="
Write-Information ("VMs updated  : {0}" -f $jobs.Count)

[pscustomobject]@{
    ResourceGroupName      = $ResourceGroupName
    VMAppVersionResourceId = $VMAppVersionResourceId
    VmCount                = $jobs.Count
    VMNames                = @($vms | ForEach-Object { [string]$_.Name })
    Skipped                = $false
}
