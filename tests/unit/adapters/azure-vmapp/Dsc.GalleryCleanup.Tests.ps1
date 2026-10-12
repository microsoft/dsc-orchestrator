# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..'))
    $script:AdapterRoot = Join-Path $script:RepoRoot 'src\adapters\delivery\azure-vmapp'
    $script:CleanupScript = Join-Path $script:AdapterRoot 'Remove-OldDscV3GalleryVersions.ps1'
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
        param([string]$Name)
        [pscustomobject]@{
            Name = $Name
            Id = "/subscriptions/test-sub/resourceGroups/gallery-rg/providers/Microsoft.Compute/galleries/gallery/applications/sample-agent/versions/$Name"
        }
    }

    function New-TestVm {
        param([string]$Name, [string[]]$ReferenceIds = @())
        $galleryApplications = @(
            $ReferenceIds | ForEach-Object {
                [pscustomobject]@{ PackageReferenceId = $_ }
            }
        )
        [pscustomobject]@{
            Name = $Name
            ApplicationProfile = [pscustomobject]@{ GalleryApplications = $galleryApplications }
        }
    }

    function Invoke-Cleanup {
        param(
            [hashtable]$Overrides = @{},
            [switch]$CaptureOutput
        )

        $parameters = @{
            GalleryName = 'gallery'
            GalleryResourceGroup = 'gallery-rg'
            ApplicationName = 'sample-agent'
            VMResourceGroupName = 'workload-rg'
        }
        foreach ($key in $Overrides.Keys) {
            $parameters[$key] = $Overrides[$key]
        }

        if ($CaptureOutput) {
            return @(& $script:CleanupScript @parameters 3>&1 6>&1)
        }
        & $script:CleanupScript @parameters | Out-Null
    }
}

Describe 'Remove-OldDscV3GalleryVersions' {
    BeforeEach {
        Mock Get-AzContext { New-TestContext }
        Mock Get-AzGalleryApplication { New-TestApplication }
        Mock Get-AzGalleryApplicationVersion {
            @(
                (New-TestVersion '1.0.0'),
                (New-TestVersion '1.0.1'),
                (New-TestVersion '1.0.2'),
                (New-TestVersion '1.0.3')
            )
        }
        Mock Get-AzVM -ParameterFilter { -not $Name } {
            [pscustomobject]@{ Name = 'vm01' }
        }
        Mock Get-AzVM -ParameterFilter { $Name } {
            New-TestVm -Name $Name
        }
        Mock Remove-AzGalleryApplicationVersion { }
    }

    It 'retains the newest two semantic versions and deletes only older unassigned versions' {
        Invoke-Cleanup

        Should -Invoke Remove-AzGalleryApplicationVersion -Times 1 -Exactly -ParameterFilter { $Name -eq '1.0.0' }
        Should -Invoke Remove-AzGalleryApplicationVersion -Times 1 -Exactly -ParameterFilter { $Name -eq '1.0.1' }
        Should -Invoke Remove-AzGalleryApplicationVersion -Times 0 -Exactly -ParameterFilter { $Name -in @('1.0.2', '1.0.3') }
    }

    It 'retains an assigned version even when it is older than the newest two' {
        $assignedId = '/subscriptions/test-sub/resourceGroups/gallery-rg/providers/Microsoft.Compute/galleries/gallery/applications/sample-agent/versions/1.0.0'
        Mock Get-AzVM -ParameterFilter { $Name } {
            New-TestVm -Name $Name -ReferenceIds @($assignedId)
        }

        Invoke-Cleanup

        Should -Invoke Remove-AzGalleryApplicationVersion -Times 0 -Exactly -ParameterFilter { $Name -eq '1.0.0' }
        Should -Invoke Remove-AzGalleryApplicationVersion -Times 1 -Exactly -ParameterFilter { $Name -eq '1.0.1' }
    }

    It 'logs and skips successfully when there are no target VMs' {
        Mock Get-AzVM -ParameterFilter { -not $Name } { @() }
        $output = Invoke-Cleanup -CaptureOutput
        $text = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine

        $text | Should -Match 'zero VMs; skipping prune'
        Should -Invoke Remove-AzGalleryApplicationVersion -Times 0 -Exactly
    }

    It 'fails closed and deletes nothing when a VM assignment cannot be read' {
        Mock Get-AzVM -ParameterFilter { $Name } {
            throw 'simulated VM read failure'
        }

        { Invoke-Cleanup } | Should -Not -Throw
        Should -Invoke Remove-AzGalleryApplicationVersion -Times 0 -Exactly
    }

    It 'does not enumerate VMs when the named gallery application is absent' {
        Mock Get-AzGalleryApplication { @() }

        { Invoke-Cleanup } | Should -Not -Throw
        Should -Invoke Get-AzVM -Times 0 -Exactly
        Should -Invoke Remove-AzGalleryApplicationVersion -Times 0 -Exactly
    }
}
