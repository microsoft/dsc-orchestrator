# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..'))
    $script:AdapterRoot = Join-Path $script:RepoRoot 'src\adapters\delivery\azure-vmapp'
    $script:ReadLatestScript = Join-Path $script:AdapterRoot 'Get-DSCv3LatestVMAppVersion.ps1'
    $script:ApplicationName = 'sample-agent'
    $script:OriginalTfBuild = $env:TF_BUILD

    function New-TestContext {
        [pscustomobject]@{
            Subscription = [pscustomobject]@{ Id = 'test-sub' }
            Account = [pscustomobject]@{ Id = 'test-identity' }
        }
    }

    function New-TestApplication {
        [pscustomobject]@{
            Id = '/subscriptions/test-sub/resourceGroups/gallery-rg/providers/Microsoft.Compute/galleries/gallery/applications/sample-agent'
            Name = 'sample-agent'
        }
    }

    function New-TestVersion {
        param(
            [string]$Name,
            [string]$ProvisioningState = 'Succeeded',
            [switch]$OmitProvisioningState
        )
        $properties = [ordered]@{
            Name = $Name
            Id = "/subscriptions/test-sub/resourceGroups/gallery-rg/providers/Microsoft.Compute/galleries/gallery/applications/sample-agent/versions/$Name"
        }
        if (-not $OmitProvisioningState) {
            $properties.ProvisioningState = $ProvisioningState
        }
        [pscustomobject]$properties
    }

    function Invoke-Latest {
        param(
            [hashtable]$Overrides = @{},
            [switch]$CaptureStreams
        )

        $parameters = @{
            GalleryName = 'gallery'
            GalleryResourceGroup = 'gallery-rg'
            ApplicationName = $script:ApplicationName
        }
        foreach ($key in $Overrides.Keys) {
            $parameters[$key] = $Overrides[$key]
        }

        if ($CaptureStreams) {
            return @(& $script:ReadLatestScript @parameters 3>&1 6>&1)
        }
        & $script:ReadLatestScript @parameters
    }
}

AfterAll {
    $env:TF_BUILD = $script:OriginalTfBuild
}

Describe 'Get-DSCv3LatestVMAppVersion' {
    BeforeEach {
        $env:TF_BUILD = ''
        Mock Get-AzContext { New-TestContext }
        Mock Get-AzGalleryApplication { New-TestApplication }
        Mock Get-AzGalleryApplicationVersion {
            @(
                (New-TestVersion '1.0.2'),
                (New-TestVersion '1.0.10'),
                (New-TestVersion '1.0.4'),
                (New-TestVersion 'latest')
            )
        }
    }

    It 'returns the highest semantic version as a neutral object' {
        $result = Invoke-Latest

        $result | Should -BeOfType ([pscustomobject])
        $result.ApplicationName | Should -Be 'sample-agent'
        $result.Version | Should -Be '1.0.10'
        $result.VMAppVersionId | Should -BeLike '*/versions/1.0.10'
    }

    It 'requires a caller Az context even when no expected subscription is supplied' {
        Mock Get-AzContext { $null }

        { Invoke-Latest } | Should -Throw -ExpectedMessage '*No Az context is available*'
        Should -Invoke Get-AzGalleryApplication -Times 0 -Exactly
    }

    It 'fails closed when the selected version is not ready' {
        Mock Get-AzGalleryApplicationVersion {
            @(
                (New-TestVersion '1.0.9'),
                (New-TestVersion -Name '1.0.10' -ProvisioningState 'Creating')
            )
        }

        { Invoke-Latest } | Should -Throw -ExpectedMessage '*version=''1.0.10''*ProvisioningState=''Creating''*'
    }

    It 'fails closed when the selected version has no provisioning state' {
        Mock Get-AzGalleryApplicationVersion {
            @(New-TestVersion -Name '1.1.0' -OmitProvisioningState)
        }

        { Invoke-Latest } | Should -Throw -ExpectedMessage '*ProvisioningState=''<missing>''*'
    }

    It 'reports a publish-first error when the application or its versions are missing' {
        Mock Get-AzGalleryApplication { @() }
        { Invoke-Latest } | Should -Throw -ExpectedMessage '*No VM Application version has been published*'

        Mock Get-AzGalleryApplication { New-TestApplication }
        Mock Get-AzGalleryApplicationVersion { @() }
        { Invoke-Latest } | Should -Throw -ExpectedMessage '*No VM Application version has been published*'
    }

    It 'emits Azure DevOps variables only when TF_BUILD is true' {
        $env:TF_BUILD = 'True'
        $output = @(Invoke-Latest -CaptureStreams)
        $successOutput = @(
            $output | Where-Object {
                $_ -isnot [System.Management.Automation.InformationRecord] -and
                $_ -isnot [System.Management.Automation.WarningRecord]
            }
        )
        $variableLines = @(
            $output | ForEach-Object {
                if ($_ -is [string] -and $_ -like '##vso*') {
                    $_
                }
                elseif ($_ -is [System.Management.Automation.InformationRecord] -and
                    [string]$_.MessageData -like '##vso*') {
                    [string]$_.MessageData
                }
            }
        )

        $successOutput | Should -HaveCount 1
        $successOutput[0].Version | Should -Be '1.0.10'
        $successOutput[0].VMAppVersionId | Should -BeLike '*/versions/1.0.10'
        $variableLines | Should -HaveCount 2
        $variableLines | Should -Contain '##vso[task.setvariable variable=VMAppVersionId;isOutput=true]/subscriptions/test-sub/resourceGroups/gallery-rg/providers/Microsoft.Compute/galleries/gallery/applications/sample-agent/versions/1.0.10'
        $variableLines | Should -Contain '##vso[task.setvariable variable=packageVersion;isOutput=true]1.0.10'
    }

    It 'returns one result object without Azure DevOps variables when TF_BUILD is unset' {
        $env:TF_BUILD = ''
        $output = @(Invoke-Latest -CaptureStreams)
        $successOutput = @(
            $output | Where-Object {
                $_ -isnot [System.Management.Automation.InformationRecord] -and
                $_ -isnot [System.Management.Automation.WarningRecord]
            }
        )
        $variableLines = @(
            $output | ForEach-Object {
                if ($_ -is [string] -and $_ -like '##vso*') {
                    $_
                }
                elseif ($_ -is [System.Management.Automation.InformationRecord] -and
                    [string]$_.MessageData -like '##vso*') {
                    [string]$_.MessageData
                }
            }
        )

        $successOutput | Should -HaveCount 1
        $successOutput[0].Version | Should -Be '1.0.10'
        $successOutput[0].VMAppVersionId | Should -BeLike '*/versions/1.0.10'
        $variableLines | Should -HaveCount 0
    }
}
