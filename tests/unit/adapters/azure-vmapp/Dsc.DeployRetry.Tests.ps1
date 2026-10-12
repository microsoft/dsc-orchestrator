# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..'))
    $script:DeployScript = Join-Path $script:RepoRoot 'src\adapters\delivery\azure-vmapp\Deploy-DSCv3VMApp.ps1'
    $script:VersionResourceId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/gallery-rg/providers/Microsoft.Compute/galleries/gallery/applications/sample-agent/versions/1.4.0'

    $applicationTypeName = 'Microsoft.Azure.Commands.Compute.Automation.Models.PSVMGalleryApplication'
    $profileTypeName = 'Microsoft.Azure.Commands.Compute.Automation.Models.PSApplicationProfile'
    $loadedTypes = @(
        foreach ($assembly in [System.AppDomain]::CurrentDomain.GetAssemblies()) {
            foreach ($typeName in @($applicationTypeName, $profileTypeName)) {
                $type = $assembly.GetType($typeName, $false, $false)
                if ($null -ne $type) { $type.FullName }
            }
        }
    )

    if ($loadedTypes.Count -eq 0) {
        Add-Type -TypeDefinition @'
namespace Microsoft.Azure.Commands.Compute.Automation.Models
{
    public class PSVMGalleryApplication
    {
        public string PackageReferenceId { get; set; }
        public int Order { get; set; }
        public bool TreatFailureAsDeploymentFailure { get; set; }
    }

    public class PSApplicationProfile
    {
        public System.Collections.Generic.List<PSVMGalleryApplication> GalleryApplications { get; set; }
    }
}
'@
    }
    elseif ($loadedTypes.Count -ne 2) {
        throw 'The test host loaded only one of the required Az.Compute VM Application model types.'
    }
}

Describe 'Deploy-DSCv3VMApp recovery retry' {
    BeforeEach {
        $script:DeploymentState = [pscustomobject]@{
            UpdateCalls = [System.Collections.Generic.List[object]]::new()
            StatusReads = 0
            RetryDelays = [System.Collections.Generic.List[int]]::new()
        }
        $state = $script:DeploymentState
        $versionResourceId = $script:VersionResourceId
        $script:OriginalGlobalRetryState = Get-Variable -Name __DscDeployRetryTestState -Scope Global -ErrorAction SilentlyContinue
        Set-Variable -Name __DscDeployRetryTestState -Scope Global -Value $state -Force
        $script:OriginalGlobalGetAzVM = Get-Item -Path Function:\global:Get-AzVM -ErrorAction SilentlyContinue
        $script:OriginalGlobalStartSleep = Get-Item -Path Function:\global:Start-Sleep -ErrorAction SilentlyContinue

        Mock Get-AzContext {
            [pscustomobject]@{
                Subscription = [pscustomobject]@{ Id = '11111111-1111-1111-1111-111111111111' }
                Account = [pscustomobject]@{ Id = 'test-identity' }
            }
        }
        Mock Get-AzResourceGroup { [pscustomobject]@{ ResourceGroupName = 'workload-rg' } }
        $galleryVersionMock = {
            [pscustomobject]@{ Name = '1.4.0'; Id = $versionResourceId }
        }.GetNewClosure()
        Mock Get-AzGalleryApplicationVersion -MockWith $galleryVersionMock
        $getAzVmMock = {
            [CmdletBinding()]
            param(
                [string]$ResourceGroupName,
                [string]$Name,
                [switch]$Status
            )

            if ($Status) {
                $state.StatusReads++
                $message = if ($state.UpdateCalls.Count -ge 2) {
                    'Enable succeeded: { "CurrentState": [ { "applicationName": "sample-agent", "version": "1.4.0", "result": "Update SUCCESS" } ] }'
                } else {
                    'Enable succeeded: { "CurrentState": [] }'
                }
                return [pscustomobject]@{
                    Extensions = @(
                        [pscustomobject]@{
                            Type = 'Microsoft.CPlat.Core.VMApplicationManagerWindows'
                            Name = 'VMAppExtension'
                            Statuses = @([pscustomobject]@{
                                Code = 'ProvisioningState/succeeded'
                                Message = $message
                            })
                        }
                    )
                }
            }

            if ([string]::IsNullOrEmpty($Name)) {
                return [pscustomobject]@{ Name = 'vm01'; ApplicationProfile = $null }
            }
            return [pscustomobject]@{ Name = $Name; ApplicationProfile = $null }
        }.GetNewClosure()
        Set-Item -Path Function:\global:Get-AzVM -Value $getAzVmMock -Force
        $startSleepMock = {
            [CmdletBinding()]
            param([Parameter(Mandatory = $true)][int]$Seconds)
            $global:__DscDeployRetryTestState.RetryDelays.Add($Seconds)
        }
        Set-Item -Path Function:\global:Start-Sleep -Value $startSleepMock -Force

        Mock Update-AzVM {
            $testState = $global:__DscDeployRetryTestState
            $jobState = if ($testState.UpdateCalls.Count -eq 0) { 'Failed' } else { 'Completed' }
            $testState.UpdateCalls.Add([pscustomobject]@{
                State = $jobState
                AsJob = [bool]$AsJob
                ConfirmPreference = [string]$ConfirmPreference
                VmName = [string]$VM.Name
            })
            if ($jobState -eq 'Failed') {
                Start-Job -ScriptBlock { throw 'simulated initial update failure' }
            } else {
                Start-Job -ScriptBlock { 'simulated retry success' }
            }
        }
    }

    AfterEach {
        if ($null -eq $script:OriginalGlobalGetAzVM) {
            Remove-Item -Path Function:\global:Get-AzVM -ErrorAction SilentlyContinue
        }
        else {
            Set-Item -Path Function:\global:Get-AzVM -Value $script:OriginalGlobalGetAzVM.ScriptBlock -Force
        }
        if ($null -eq $script:OriginalGlobalStartSleep) {
            Remove-Item -Path Function:\global:Start-Sleep -ErrorAction SilentlyContinue
        }
        else {
            Set-Item -Path Function:\global:Start-Sleep -Value $script:OriginalGlobalStartSleep.ScriptBlock -Force
        }
        if ($null -eq $script:OriginalGlobalRetryState) {
            Remove-Variable -Name __DscDeployRetryTestState -Scope Global -Force -ErrorAction SilentlyContinue
        }
        else {
            Set-Variable -Name __DscDeployRetryTestState -Scope Global -Value $script:OriginalGlobalRetryState.Value -Force
        }
    }

    It 'runs the captured update helper in the resilience retry closure after an initial job fails' {
        (Get-Command Get-AzVM -ErrorAction Stop).CommandType | Should -Be 'Function'

        $deployError = $null
        $deployOutput = @()
        $state = $script:DeploymentState
        try {
            $deployOutput = @(
                & $script:DeployScript `
                    -ResourceGroupName 'workload-rg' `
                    -VMAppVersionResourceId $script:VersionResourceId `
                    -Confirm:$false *>&1
            )
        }
        catch {
            $deployError = $_.Exception.Message
        }

        $deployError | Should -BeNullOrEmpty
        $deployResult = @(
            $deployOutput | Where-Object {
                $_.PSObject.Properties.Name -contains 'VmCount' -and
                $_.PSObject.Properties.Name -contains 'Skipped'
            }
        )
        $deployResult | Should -HaveCount 1
        $deployResult[0].VmCount | Should -Be 1
        $deployResult[0].Skipped | Should -BeFalse

        @($state.UpdateCalls) | Should -HaveCount 2
        $state.UpdateCalls[0].State | Should -Be 'Failed'
        $state.UpdateCalls[1].State | Should -Be 'Completed'
        foreach ($call in $state.UpdateCalls) {
            $call.AsJob | Should -BeTrue
            $call.ConfirmPreference | Should -Be 'High'
        }
        $state.StatusReads | Should -Be 2
        @($state.RetryDelays) | Should -HaveCount 1
        $state.RetryDelays[0] | Should -Be 15

        $diagnostics = @(
            $deployOutput | ForEach-Object {
                if ($_ -is [System.Management.Automation.InformationRecord]) {
                    [string]$_.MessageData
                } else {
                    [string]$_
                }
            }
        ) -join "`n"
        $diagnostics | Should -Not -Match 'Start-VMUpdateJob.{0,100}not recognized'
        Should -Invoke Update-AzVM -Times 2 -Exactly -ParameterFilter { $AsJob }
    }
}
