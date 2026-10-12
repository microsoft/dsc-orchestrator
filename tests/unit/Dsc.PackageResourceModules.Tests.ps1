# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Set-StrictMode -Version Latest

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:SaveResourceModulesScript = Join-Path $script:RepoRoot 'src\core\package\Save-DSCv3ResourceModules.ps1'
    Import-Module (Join-Path $script:RepoRoot 'src\core\package\Modules\Dsc.PackageResourceModules.psm1') -Force
    Import-Module (Join-Path $script:RepoRoot 'src\agent\windows\Modules\Dsc.Bootstrap.Staging.psm1') -DisableNameChecking -Force

    function New-TestOrchestratorConfig {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Root,

            [Parameter(Mandatory = $true)]
            [string]$ModuleVersion
        )

        New-Item -ItemType Directory -Path $Root -Force -ErrorAction Stop | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $Root 'fragment.dsc.yaml'), "resources:`n")
        $config = [ordered]@{
            schemaVersion = '1.0'
            name          = 'module-staging-test'
            version       = '1.0.0'
            fragments     = @(
                [ordered]@{
                    name = 'baseline'
                    path = 'fragment.dsc.yaml'
                }
            )
            modules       = @(
                [ordered]@{
                    name    = 'SomeModule'
                    version = $ModuleVersion
                }
            )
        }
        $configPath = Join-Path $Root 'dsc-orchestrator.config.json'
        [System.IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 8))
        return $configPath
    }

    function New-TestResourceModule {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Root,

            [Parameter(Mandatory = $true)]
            [string]$ModuleVersion
        )

        $moduleRoot = Join-Path $Root 'SomeModule'
        $versionRoot = Join-Path $moduleRoot $ModuleVersion
        New-Item -ItemType Directory -Path $versionRoot -Force -ErrorAction Stop | Out-Null
        [System.IO.File]::WriteAllText(
            (Join-Path $versionRoot 'SomeModule.psd1'),
            "@{ ModuleVersion = '$ModuleVersion' }"
        )
        return $versionRoot
    }
}

Describe 'DSCv3 resource-module packaging' {
    It 'passes module alignment when the resource module is declared' {
        $configPath = Join-Path $TestDrive 'aligned.dsc.yaml'
        [System.IO.File]::WriteAllText($configPath, "resources:`n  - name: item`n    type: SomeModule/Resource`n")

        {
            Test-DSCv3ModuleAlignment -ConfigPath $configPath -ModuleNames @('SomeModule')
        } | Should -Not -Throw
    }

    It 'fails module alignment when the resource module is missing' {
        $configPath = Join-Path $TestDrive 'unaligned.dsc.yaml'
        [System.IO.File]::WriteAllText($configPath, "resources:`n  - name: item`n    type: SomeModule/Resource`n")

        {
            Test-DSCv3ModuleAlignment -ConfigPath $configPath -ModuleNames @()
        } | Should -Throw '*not present in the staged module package*SomeModule*'
    }

    It 'resolves a four-part PSGallery folder for a three-part declaration' {
        Mock -CommandName Save-Module {
            $moduleName = [string]$Name
            $outputPath = [string]$Path
            $moduleRoot = Join-Path $outputPath $moduleName
            $versionRoot = Join-Path $moduleRoot '2.12.0.0'
            New-Item -ItemType Directory -Path $versionRoot -Force -ErrorAction Stop | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $versionRoot "$moduleName.psd1"), "@{ ModuleVersion = '2.12.0.0' }")
        }

        $testRoot = Join-Path $TestDrive 'remote-three-part'
        $configPath = New-TestOrchestratorConfig -Root $testRoot -ModuleVersion '2.12.0'
        $outputPath = Join-Path $testRoot 'staged'
        $stagedModules = @(& $script:SaveResourceModulesScript -ConfigPath $configPath -OutputPath $outputPath)

        $stagedModules.Count | Should -Be 1
        $stagedModules[0].Version | Should -Be '2.12.0.0'
        $stagedModules[0].ModulePath | Should -Be (Join-Path $outputPath 'SomeModule\2.12.0.0')
        Test-Path -LiteralPath $stagedModules[0].ModulePath -PathType Container | Should -BeTrue
        Should -Invoke -CommandName Save-Module -Exactly -Times 1
    }

    It 'resolves a three-part PSGallery folder for a four-part declaration' {
        Mock -CommandName Save-Module {
            $moduleName = [string]$Name
            $outputPath = [string]$Path
            $moduleRoot = Join-Path $outputPath $moduleName
            $versionRoot = Join-Path $moduleRoot '2.12.0'
            New-Item -ItemType Directory -Path $versionRoot -Force -ErrorAction Stop | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $versionRoot "$moduleName.psd1"), "@{ ModuleVersion = '2.12.0' }")
        }

        $testRoot = Join-Path $TestDrive 'remote-four-part'
        $configPath = New-TestOrchestratorConfig -Root $testRoot -ModuleVersion '2.12.0.0'
        $outputPath = Join-Path $testRoot 'staged'
        $stagedModules = @(& $script:SaveResourceModulesScript -ConfigPath $configPath -OutputPath $outputPath)

        $stagedModules.Count | Should -Be 1
        $stagedModules[0].Version | Should -Be '2.12.0'
        $stagedModules[0].ModulePath | Should -Be (Join-Path $outputPath 'SomeModule\2.12.0')
        Test-Path -LiteralPath $stagedModules[0].ModulePath -PathType Container | Should -BeTrue
        Should -Invoke -CommandName Save-Module -Exactly -Times 1
    }

    It 'resolves numerically equivalent folder names for local module trees' {
        foreach ($case in @(
                [pscustomobject]@{ Name = 'local-three-to-four'; Declared = '2.12.0'; Folder = '2.12.0.0' }
                [pscustomobject]@{ Name = 'local-four-to-three'; Declared = '2.12.0.0'; Folder = '2.12.0' }
            )) {
            $testRoot = Join-Path $TestDrive $case.Name
            $configPath = New-TestOrchestratorConfig -Root $testRoot -ModuleVersion $case.Declared
            $localPath = Join-Path $testRoot 'local'
            $null = New-TestResourceModule -Root $localPath -ModuleVersion $case.Folder
            $outputPath = Join-Path $testRoot 'staged'

            $stagedModules = @(
                & $script:SaveResourceModulesScript `
                    -ConfigPath $configPath `
                    -OutputPath $outputPath `
                    -LocalPath $localPath
            )

            $stagedModules.Count | Should -Be 1
            $stagedModules[0].Version | Should -Be $case.Folder
            $stagedModules[0].ModulePath | Should -Be (Join-Path $outputPath "SomeModule\$($case.Folder)")
            Test-Path -LiteralPath (Join-Path $stagedModules[0].ModulePath 'SomeModule.psd1') -PathType Leaf |
                Should -BeTrue
        }
    }

    It 'packages a local module in the versioned ZIP path consumed by the agent' {
        $testRoot = Join-Path $TestDrive 'package-layout'
        $configPath = New-TestOrchestratorConfig -Root $testRoot -ModuleVersion '2.12.0'
        $localPath = Join-Path $testRoot 'local'
        $null = New-TestResourceModule -Root $localPath -ModuleVersion '2.12.0.0'
        $stagingPath = Join-Path $testRoot 'staged'
        $stagedModules = @(
            & $script:SaveResourceModulesScript `
                -ConfigPath $configPath `
                -OutputPath $stagingPath `
                -LocalPath $localPath
        )

        $resolvedModules = @(
            Resolve-DSCv3ResourceModules `
                -ModulesPath $stagingPath `
                -ResourceModules @([pscustomobject]@{ name = 'SomeModule'; version = '2.12.0' })
        )
        $packageRoot = Join-Path $testRoot 'package'
        New-Item -ItemType Directory -Path $packageRoot -Force -ErrorAction Stop | Out-Null
        $packageModules = @(
            Copy-DSCv3ResourceModulesToPackage `
                -ResolvedModules $resolvedModules `
                -DestinationPath (Join-Path $packageRoot 'modules')
        )
        $packageManifest = [ordered]@{ resourceModules = $packageModules }
        [System.IO.File]::WriteAllText(
            (Join-Path $packageRoot 'manifest.json'),
            ($packageManifest | ConvertTo-Json -Depth 5)
        )
        $archivePath = Join-Path $testRoot 'package.zip'
        Compress-Archive -Path (Join-Path $packageRoot '*') -DestinationPath $archivePath -Force -ErrorAction Stop

        $archive = [System.IO.Compression.ZipFile]::OpenRead($archivePath)
        try {
            $entries = @($archive.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
            $manifestEntry = $archive.GetEntry('manifest.json')
            $reader = [System.IO.StreamReader]::new($manifestEntry.Open())
            try {
                $zippedManifest = $reader.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop
            }
            finally {
                $reader.Dispose()
            }
        }
        finally {
            $archive.Dispose()
        }

        $stagedModules[0].Version | Should -Be '2.12.0.0'
        $zippedManifest.resourceModules[0].version | Should -Be '2.12.0.0'
        $entries | Should -Contain 'modules/SomeModule/2.12.0.0/SomeModule.psd1'

        $agentModulePath = Join-Path (Join-Path $testRoot 'agent-modules') 'SomeModule\2.12.0.0\SomeModule.psd1'
        Sync-AllUsersModules `
            -SourceModulesPath (Join-Path $packageRoot 'modules') `
            -TargetModulesPath (Join-Path $testRoot 'agent-modules') `
            -Confirm:$false
        Test-Path -LiteralPath $agentModulePath -PathType Leaf | Should -BeTrue
    }
}
