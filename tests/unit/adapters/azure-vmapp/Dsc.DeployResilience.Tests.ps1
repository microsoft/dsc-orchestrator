#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..'))
    $script:AdapterRoot = Join-Path $script:RepoRoot 'src\adapters\delivery\azure-vmapp'
    Import-Module (Join-Path $script:AdapterRoot 'Modules\Dsc.DeployResilience.psm1') -Force

    function New-TestExtension {
        param(
            [string]$Type = 'Microsoft.CPlat.Core.VMApplicationManagerWindows',
            [string]$Name = 'VMAppExtension',
            [string]$Code = 'ProvisioningState/succeeded',
            [string]$Message
        )

        [pscustomobject]@{
            Type = $Type
            Name = $Name
            Statuses = @([pscustomobject]@{ Code = $Code; Message = $Message })
        }
    }

    function New-TestInstanceView {
        param($Extensions)
        [pscustomobject]@{ Extensions = $Extensions }
    }

    function Invoke-TestApplied {
        param(
            [Parameter(Mandatory = $true)]$InstanceView,
            [string]$ApplicationName = 'sample-agent',
            [string]$TargetVersion = '1.0.15'
        )

        $provider = { $InstanceView }.GetNewClosure()
        Test-DscV3VMAppApplied `
            -ResourceGroupName 'workload-rg' `
            -VmName 'vm01' `
            -TargetApplicationName $ApplicationName `
            -TargetVersion $TargetVersion `
            -InstanceViewProvider $provider
    }
}

Describe 'VM Application deployment resilience' {
    It 'accepts only a completed deployment job state' {
        Test-DeploymentJobStateSuccessful -State 'Completed' | Should -BeTrue
        Test-DeploymentJobStateSuccessful -State 'Failed' | Should -BeFalse
        Test-DeploymentJobStateSuccessful -State 'Succeeded' | Should -BeFalse
    }

    It 'confirms the exact application and version from the extension status' {
        $message = 'Enable succeeded: { "CurrentState": [ { "applicationName": "sample-agent", "version": "1.0.15", "result": "Update SUCCESS" } ] }'
        $view = New-TestInstanceView -Extensions @(New-TestExtension -Message $message)

        Invoke-TestApplied -InstanceView $view | Should -BeTrue
    }

    It 'rejects failed, ambiguous, and malformed extension statuses' {
        $failed = New-TestInstanceView -Extensions @(
            New-TestExtension -Code 'ProvisioningState/failed' -Message 'Enable succeeded: { "CurrentState": [] }'
        )
        $malformed = New-TestInstanceView -Extensions @(
            New-TestExtension -Message 'not a VM Application status'
        )
        $duplicateMessage = 'Enable succeeded: { "CurrentState": [ { "applicationName": "sample-agent", "version": "1.0.15", "result": "Install SUCCESS" }, { "applicationName": "sample-agent", "version": "1.0.15", "result": "Update SUCCESS" } ] }'
        $duplicate = New-TestInstanceView -Extensions @(
            New-TestExtension -Message $duplicateMessage
        )

        Invoke-TestApplied -InstanceView $failed | Should -BeFalse
        Invoke-TestApplied -InstanceView $malformed | Should -BeFalse
        Invoke-TestApplied -InstanceView $duplicate | Should -BeFalse
    }

    It 'treats instance-view provider failures as unconfirmed application state' {
        Test-DscV3VMAppApplied `
            -ResourceGroupName 'workload-rg' `
            -VmName 'vm01' `
            -TargetApplicationName 'sample-agent' `
            -TargetVersion '1.0.15' `
            -InstanceViewProvider { throw 'simulated read failure' } | Should -BeFalse
    }

    It 'retries unresolved VMs in rounds and stops retrying after confirmation' {
        $state = @{ VerifyCount = 0; Events = [System.Collections.Generic.List[string]]::new() }
        $verify = {
            param($VmName)
            $state.VerifyCount++
            $state.Events.Add("verify:$VmName")
            return $state.VerifyCount -ge 2
        }.GetNewClosure()
        $update = {
            param($VmNames, $Retry)
            $state.Events.Add("update:$Retry")
        }.GetNewClosure()
        $delay = {
            param($Seconds)
            $state.Events.Add("delay:$Seconds")
        }.GetNewClosure()

        $failures = @(
            [pscustomobject]@{ VmName = 'vm01'; InitialError = 'initial update failed' }
        )
        $result = @(Resolve-FailedVMDeployment -Failures $failures -VerifyApplied $verify -UpdateVMs $update -Delay $delay)

        $result | Should -BeNullOrEmpty
        ($state.Events -join '|') | Should -Be 'verify:vm01|delay:15|update:1|verify:vm01'
    }

    It 'returns initial and retry diagnostics when both retry rounds remain unresolved' {
        $failure = [pscustomobject]@{ VmName = 'vm02'; InitialError = 'initial failure' }
        $update = {
            param($VmNames, $Retry)
            [pscustomobject]@{ VmName = $VmNames[0]; Error = "retry-$Retry failure" }
        }

        $result = @(Resolve-FailedVMDeployment -Failures @($failure) -VerifyApplied { $false } -UpdateVMs $update -Delay { })

        $result | Should -HaveCount 1
        $result[0] | Should -BeLike '*initial failure*retry 1: retry-1 failure*retry 2: retry-2 failure*'
    }

    It 'does not call retry providers for an empty failure set' {
        $result = @(Resolve-FailedVMDeployment `
            -Failures @() `
            -VerifyApplied { throw 'unexpected verify' } `
            -UpdateVMs { throw 'unexpected update' } `
            -Delay { throw 'unexpected delay' })

        $result | Should -BeNullOrEmpty
    }
}
