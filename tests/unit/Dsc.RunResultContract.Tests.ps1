# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Set-StrictMode -Version Latest

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ContractRoot = Join-Path $script:RepoRoot 'src\core\contracts'
    $script:ModuleRoot = Join-Path $script:RepoRoot 'src\agent\windows\Modules'
    $script:SchemaPath = Join-Path $script:ContractRoot 'run-result.schema.json'

    Import-Module (Join-Path $script:RepoRoot 'src\core\shared\Dsc.JsonSchema.psm1') -Force
    Import-Module (Join-Path $script:ModuleRoot 'Dsc.HostContext.psm1') -Force
    Import-Module (Join-Path $script:ModuleRoot 'Dsc.ResultProjection.psm1') -Force
    Import-Module (Join-Path $script:ModuleRoot 'Dsc.Reasons.psm1') -Force
    Import-Module (Join-Path $script:ModuleRoot 'Dsc.Lifecycle.psm1') -Force
    Import-Module (Join-Path $script:ModuleRoot 'Dsc.JsonLog.psm1') -Force
}

Describe 'Run and resource JSONL contract' {
    It 'points aborted-run triage at local JSONL rather than a remote table' {
        $source = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'src\agent\windows\Invoke-Enforcement.ps1') -Raw

        $source | Should -Match 'Correlate by run_id with orphan records in the local resources\.jsonl stream\.'
    }

    It 'reads portable group and role metadata plus the package configuration hash' {
        $metadataPath = Join-Path $TestDrive 'metadata.json'
        Set-Content -LiteralPath $metadataPath -Value '{"group":"workload-a","role":"web-server","configuration_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'

        $metadata = Get-ConfigMetadata -Path $metadataPath

        $metadata.Group | Should -Be 'workload-a'
        $metadata.Role | Should -Be 'web-server'
        $metadata.ConfigurationHash | Should -Be 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    }

    It 'emits resource records conforming to schema 3.0 with portable context names' {
        $record = New-ResourceRecord `
            -SchemaVersion '3.0' `
            -RunId 'run-contract-test' `
            -Timestamp '2026-09-24T14:00:00.0000000Z' `
            -Computer 'host-contract-test' `
            -Group 'workload-a' `
            -Role 'web-server' `
            -ConfigVersion '1.0.0' `
            -ConfigurationHash 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' `
            -Trigger 'scheduled' `
            -Phase 'test' `
            -ResourceName 'RegistryValue' `
            -Action 'test' `
            -LifecycleEvent 'complete' `
            -DurationSource 'inherited_from_run'

        $errors = @(Test-OrchestratorJsonSchema -Value $record -SchemaPath $script:SchemaPath)

        $errors | Should -BeNullOrEmpty
        $record.schema_version | Should -Be '3.0'
        $record.group | Should -Be 'workload-a'
        $record.role | Should -Be 'web-server'
        $record.configuration_hash | Should -Be 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    }

    It 'emits run summaries conforming to schema 3.0' {
        $path = Join-Path $TestDrive 'runs.jsonl'
        Write-RunSummary `
            -Path $path `
            -Timestamp '2026-09-24T14:00:00.0000000Z' `
            -ConfigVersion '1.0.0' `
            -RunId 'run-contract-test' `
            -SchemaVersion '3.0' `
            -Group $null `
            -Role $null `
            -ConfigurationHash 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' `
            -DscExeVersion '3.2.0' `
            -Mode 'enforce' `
            -Trigger 'scheduled' `
            -Outcome 'compliant' `
            -TotalResources 1 `
            -CompliantResources 1 `
            -NonCompliantCount 0 `
            -HadErrors $false `
            -TestDuration 'PT1S' `
            -SetDuration 'PT0S' `
            -VerifyDuration 'PT1S' `
            -TotalDuration 'PT2S' `
            -ExitCode 0 `
            -ErrorMessage ''

        $record = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $errors = @(Test-OrchestratorJsonSchema -Value $record -SchemaPath $script:SchemaPath)

        $errors | Should -BeNullOrEmpty
        $record.schema_version | Should -Be '3.0'
        $record.group | Should -BeNullOrEmpty
        $record.role | Should -BeNullOrEmpty
        $record.configuration_hash | Should -Be 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    }
}
