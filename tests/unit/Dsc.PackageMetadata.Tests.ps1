# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Set-StrictMode -Version Latest

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot 'src\core\package\Modules\Dsc.PackageMetadata.psm1') -Force
}

Describe 'Package metadata sidecar' {
    It 'uses the metadata sidecar generator in the package builder' {
        $builderPath = Join-Path $script:RepoRoot 'src\core\package\New-DSCv3Package.ps1'
        $source = Get-Content -LiteralPath $builderPath -Raw

        $source | Should -Match 'ConvertTo-DscPackageMetadata -PackageManifest \$packageManifest -PreparedManifest \$preparedManifest'
    }

    It 'writes the package configuration hash and configured group and role' {
        $packageManifest = [ordered]@{
            name              = 'sample-configuration'
            version           = '1.2.3'
            configurationHash = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        }
        $preparedManifest = [pscustomobject]@{
            group = 'sample-group'
            role  = 'sample-role'
        }

        $metadata = ConvertTo-DscPackageMetadata -PackageManifest $packageManifest -PreparedManifest $preparedManifest
        $path = Join-Path $TestDrive 'metadata.json'
        [System.IO.File]::WriteAllText($path, ($metadata | ConvertTo-Json -Depth 5))
        $read = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json

        $read.configuration_name | Should -Be 'sample-configuration'
        $read.configuration_version | Should -Be '1.2.3'
        $read.configuration_hash | Should -Be 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        $read.group | Should -Be 'sample-group'
        $read.role | Should -Be 'sample-role'
    }

    It 'omits group and role when they were not configured' {
        $packageManifest = [ordered]@{
            name              = 'sample-configuration'
            version           = '1.2.3'
            configurationHash = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
        }
        $preparedManifest = [pscustomobject]@{}

        $metadata = ConvertTo-DscPackageMetadata -PackageManifest $packageManifest -PreparedManifest $preparedManifest

        $metadata.Contains('group') | Should -BeFalse
        $metadata.Contains('role') | Should -BeFalse
    }
}
