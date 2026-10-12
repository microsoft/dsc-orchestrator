# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Set-StrictMode -Version Latest

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ContractRoot = Join-Path $script:RepoRoot 'src\core\contracts'
    $script:ConfigPath = Join-Path $script:RepoRoot 'tests\fixtures\dsc-orchestrator.config.json'

    Import-Module (Join-Path $script:RepoRoot 'src\core\shared\Dsc.OrchestratorConfig.psm1') -Force
    Import-Module (Join-Path $script:RepoRoot 'src\core\shared\Dsc.JsonSchema.psm1') -Force

    function script:New-SamplePackageManifest {
        [pscustomobject]@{
            schemaVersion     = '1.0'
            name              = 'basic-sample'
            version           = '1.0.0'
            configurationHash = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
            target            = [pscustomobject]@{
                os           = 'windows'
                architecture = 'x64'
            }
            runtime           = [pscustomobject]@{
                dscVersion        = '3.2.0'
                powerShellVersion = '7.6.2'
            }
            resourceModules   = @()
            agentModules      = @(
                [pscustomobject]@{
                    name    = 'DscOrchestrator.Reboot'
                    version = '1.0.0'
                }
            )
            fragments         = @(
                [pscustomobject]@{
                    name          = 'baseline'
                    path          = 'configs/baseline/baseline.dsc.yaml'
                    resourceCount = 1
                    resources     = @('RegistryValue')
                }
            )
        }
    }
}

Describe 'Orchestrator JSON contract schemas' {
    It 'accepts the checked-in authoring configuration' {
        $config = Get-Content -LiteralPath $script:ConfigPath -Raw | ConvertFrom-Json
        $errors = @(Test-OrchestratorJsonSchema -Value $config `
            -SchemaPath (Join-Path $script:ContractRoot 'dsc-orchestrator-config.schema.json'))

        $errors | Should -BeNullOrEmpty
        $config = Read-DscOrchestratorConfig -Path $script:ConfigPath
        $config.Name | Should -Be 'sample-configuration'
        $config.Group | Should -Be 'sample-group'
        $config.Role | Should -Be 'sample-role'
    }

    It 'rejects authoring configurations with invalid field types before composition' {
        $config = Get-Content -LiteralPath $script:ConfigPath -Raw | ConvertFrom-Json
        $config.name = 17
        $path = Join-Path $TestDrive 'invalid-dsc-orchestrator.config.json'
        $config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path

        {
            Read-DscOrchestratorConfig -Path $path
        } | Should -Throw '*$.name must be string; found integer.*'
    }

    It 'rejects empty or whitespace-only group and role metadata' {
        foreach ($field in 'group', 'role') {
            $config = Get-Content -LiteralPath $script:ConfigPath -Raw | ConvertFrom-Json
            $config.$field = '   '
            $path = Join-Path $TestDrive ("invalid-{0}.json" -f $field)
            $config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path

            { Read-DscOrchestratorConfig -Path $path } | Should -Throw
        }
    }

    It 'accepts a package manifest that matches the adapter-facing contract' {
        $manifest = New-SamplePackageManifest
        $errors = @(Test-OrchestratorJsonSchema -Value $manifest `
            -SchemaPath (Join-Path $script:ContractRoot 'package-manifest.schema.json'))

        $errors | Should -BeNullOrEmpty
    }

    It 'rejects package manifests that target a different operating system' {
        $manifest = New-SamplePackageManifest
        $manifest.target.os = 'linux'
        $errors = @(Test-OrchestratorJsonSchema -Value $manifest `
            -SchemaPath (Join-Path $script:ContractRoot 'package-manifest.schema.json'))

        $errors | Should -Contain "$.target.os must equal 'windows'."
        {
            Assert-OrchestratorJsonSchema -Value $manifest `
                -SchemaPath (Join-Path $script:ContractRoot 'package-manifest.schema.json') `
                -Subject 'Package manifest'
        } | Should -Throw '*Package manifest does not conform to JSON Schema*'
    }
}
