#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Set-StrictMode -Version Latest

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ConfigPath = Join-Path $script:RepoRoot 'tests\fixtures\dsc-orchestrator.config.json'
    $script:ComposeRoot = Join-Path $script:RepoRoot 'src\core\compose'
    $script:ConfigModule = Join-Path $script:RepoRoot 'src\core\shared\Dsc.OrchestratorConfig.psm1'

    Import-Module $script:ConfigModule -Force
    Import-Module (Join-Path $script:ComposeRoot 'Modules\Dsc.Prepare.Parse.psm1') -Force
    Import-Module (Join-Path $script:ComposeRoot 'Modules\Dsc.Prepare.Emit.psm1') -Force
}

Describe 'Orchestrator configuration input' {
    It 'loads the documented name, version, fragments, modules, and scalar parameters' {
        $config = Read-DscOrchestratorConfig -Path $script:ConfigPath

        $config.SchemaVersion | Should -Be '1.0'
        $config.Name | Should -Be 'sample-configuration'
        $config.Version | Should -Be '1.2.3'
        $config.Group | Should -Be 'sample-group'
        $config.Role | Should -Be 'sample-role'
        $config.Fragments.Count | Should -Be 1
        $config.Fragments[0].Name | Should -Be 'baseline'
        $config.Modules[0].Name | Should -Be 'Example.Resources'
        $config.Modules[0].Version | Should -Be '1.0.0'
    }

    It 'allows existing configurations to omit group and role metadata' {
        $root = Join-Path $TestDrive 'config-without-metadata'
        $fragmentRoot = Join-Path $root 'fragments'
        New-Item -ItemType Directory -Path $fragmentRoot -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $fragmentRoot 'baseline.dsc.yaml') -Value 'resources: []'
        $configPath = Join-Path $root 'dsc-orchestrator.config.json'
        [ordered]@{
            schemaVersion = '1.0'
            name          = 'existing-configuration'
            version       = '1.0.0'
            fragments     = @([ordered]@{ name = 'baseline'; path = 'fragments/baseline.dsc.yaml' })
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath

        $config = Read-DscOrchestratorConfig -Path $configPath

        $config.Group | Should -BeNullOrEmpty
        $config.Role | Should -BeNullOrEmpty
    }

    It 'resolves reserved identity parameters and renders typed scalar values' {
        $config = Read-DscOrchestratorConfig -Path $script:ConfigPath
        $parameters = Get-RenderParameterMap `
            -Parameters $config.Parameters `
            -ConfigurationName $config.Name `
            -ConfigurationVersion $config.Version
        $rendered = Invoke-DSCv3ParameterRendering `
            -Content "name: '{{ ConfigurationName }}'`nenabled: {{ Enabled }}`npath: {{ RegistryPath }}" `
            -Path $script:ConfigPath `
            -ParameterMap $parameters

        $rendered | Should -Match "name: 'sample-configuration'"
        $rendered | Should -Match 'enabled: true'
        $rendered | Should -Match "path: 'HKLM:\\SOFTWARE\\Example\\Application'"
    }

    It 'composes the selected fragment and writes a hashed manifest' {
        $outputPath = Join-Path $TestDrive 'prepared'
        $result = & (Join-Path $script:ComposeRoot 'New-DSCv3PreparedFragments.ps1') `
            -ConfigPath $script:ConfigPath `
            -OutputPath $outputPath

        $result.Name | Should -Be 'sample-configuration'
        $result.Version | Should -Be '1.2.3'
        $result.ConfigurationHash | Should -Match '^[0-9a-f]{64}$'

        $manifest = Get-Content -LiteralPath (Join-Path $outputPath 'manifest.json') -Raw |
            ConvertFrom-Json
        $manifest.fragments.Count | Should -Be 1
        $manifest.fragments[0].name | Should -Be 'baseline'
        $manifest.group | Should -Be 'sample-group'
        $manifest.role | Should -Be 'sample-role'
        Test-Path -LiteralPath (Join-Path $outputPath 'configs\baseline\baseline.dsc.yaml') |
            Should -BeTrue
    }

    It 'does not delete stale fragment files from a reused output path' {
        $outputPath = Join-Path $TestDrive 'stale-output'
        $staleFragment = Join-Path $outputPath 'configs\old\old.dsc.yaml'
        New-Item -ItemType Directory -Path (Split-Path -Parent $staleFragment) -Force | Out-Null
        Set-Content -LiteralPath $staleFragment -Value 'resources: []'

        { & (Join-Path $script:ComposeRoot 'New-DSCv3PreparedFragments.ps1') `
                -ConfigPath $script:ConfigPath `
                -OutputPath $outputPath
        } | Should -Throw '*stale fragment*'
        Test-Path -LiteralPath $staleFragment | Should -BeTrue
    }

    It 'rejects fragment paths that escape the config directory' {
        $configPath = Join-Path $TestDrive 'dsc-orchestrator.config.json'
        Set-Content -LiteralPath $configPath -Encoding utf8 -Value @'
{
  "schemaVersion": "1.0",
  "name": "invalid-path",
  "version": "1.0.0",
  "fragments": [
    {
      "name": "outside",
      "path": "..\\outside.dsc.yaml"
    }
  ]
}
'@

        { Read-DscOrchestratorConfig -Path $configPath } | Should -Throw '*relative path*'
    }

    It 'stages the configured module version from a local source directory' {
        $sourceRoot = Join-Path $TestDrive 'module-source'
        $sourceVersion = Join-Path $sourceRoot 'Example.Resources\1.0.0'
        $outputPath = Join-Path $TestDrive 'staged-modules'
        New-Item -ItemType Directory -Path $sourceVersion -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $sourceVersion 'Example.Resources.psm1') -Value 'Export-ModuleMember'
        New-ModuleManifest `
            -Path (Join-Path $sourceVersion 'Example.Resources.psd1') `
            -RootModule 'Example.Resources.psm1' `
            -ModuleVersion '1.0.0' `
            -Guid ([guid]::NewGuid()) `
            -FunctionsToExport @()

        $staged = @(
            & (Join-Path $script:RepoRoot 'src\core\package\Save-DSCv3ResourceModules.ps1') `
                -ConfigPath $script:ConfigPath `
                -OutputPath $outputPath `
                -LocalPath $sourceRoot
        )

        $staged.Count | Should -Be 1
        $staged[0].Name | Should -Be 'Example.Resources'
        Test-Path -LiteralPath (Join-Path $outputPath 'Example.Resources\1.0.0\Example.Resources.psd1') |
            Should -BeTrue
    }
}
