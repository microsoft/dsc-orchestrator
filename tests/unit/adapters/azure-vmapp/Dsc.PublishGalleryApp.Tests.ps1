# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..'))
    $script:GalleryAppModule = Join-Path $script:RepoRoot 'src\adapters\delivery\azure-vmapp\Modules\Dsc.Publish.GalleryApp.psm1'
    Import-Module $script:GalleryAppModule -Force -DisableNameChecking
}

Describe 'New-DscV3GalleryApplicationVersion' {
    BeforeEach {
        Mock New-AzGalleryApplicationVersion -ModuleName Dsc.Publish.GalleryApp { }
    }

    It 'tags new versions for page-blob replication when -Tag is available' {
        Mock Get-Command -ModuleName Dsc.Publish.GalleryApp {
            if ($Name -eq 'New-AzGalleryApplicationVersion') {
                return [pscustomobject]@{
                    Parameters = @{
                        Tag = $null
                    }
                }
            }

            return $null
        }

        New-DscV3GalleryApplicationVersion `
            -GalleryName 'gallery' `
            -ResourceGroupName 'gallery-rg' `
            -ApplicationName 'sample-agent' `
            -Version '1.4.0' `
            -Location 'eastus' `
            -BlobUri 'https://storage.blob.core.windows.net/packages/package.zip' `
            -PackageFileName 'package.zip' `
            -DscRoot 'C:\ProgramData\DscOrchestrator' `
            -TargetRegions @('eastus') `
            -Confirm:$false | Out-Null

        Should -Invoke New-AzGalleryApplicationVersion -ModuleName Dsc.Publish.GalleryApp -Times 1 -Exactly -ParameterFilter {
            $Tag['EnableBlockBlobToPageBlobReplication'] -ceq 'True'
        }
    }

    It 'warns that versions count against UnmanagedStorageAccountCount when -Tag is unavailable' {
        Mock Get-Command -ModuleName Dsc.Publish.GalleryApp {
            if ($Name -eq 'New-AzGalleryApplicationVersion') {
                return [pscustomobject]@{
                    Parameters = @{}
                }
            }

            return $null
        }

        $warnings = @()
        New-DscV3GalleryApplicationVersion `
            -GalleryName 'gallery' `
            -ResourceGroupName 'gallery-rg' `
            -ApplicationName 'sample-agent' `
            -Version '1.4.0' `
            -Location 'eastus' `
            -BlobUri 'https://storage.blob.core.windows.net/packages/package.zip' `
            -PackageFileName 'package.zip' `
            -DscRoot 'C:\ProgramData\DscOrchestrator' `
            -TargetRegions @('eastus') `
            -WarningVariable warnings `
            -Confirm:$false | Out-Null

        $warningText = ($warnings | ForEach-Object { $_.ToString() }) -join ' '
        $warningText | Should -Match 'New-AzGalleryApplicationVersion does not expose -Tag'
        $warningText | Should -Match 'UnmanagedStorageAccountCount'
        Should -Invoke New-AzGalleryApplicationVersion -ModuleName Dsc.Publish.GalleryApp -Times 1 -Exactly
    }
}
