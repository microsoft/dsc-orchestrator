#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pester v5 unit suite for Dsc.ConfigFilter.psm1 — the strip/filter blast-radius logic.
.DESCRIPTION
    Pure-logic coverage (no mocks) for the line-based YAML wrapper filtering that
    feeds the DSCv3 strip-and-retry recovery layer:
      - New-StrippedConfigExcludingResources (the reverse-dependsOn "blast-radius calculator")
      - Get-WrapperDependsOnNames            (dependsOn reference parser)
      - New-FilteredConfigForResources       (forward transitive dependsOn expansion)
      - Get-DriftedTopLevelResourceNames     (drift output -> wrapper names)

    See scripts/dscv3/tests/README.md for the CI invocation contract.
#>

BeforeAll {
    Set-StrictMode -Version Latest

    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ModuleRoot = Join-Path $script:RepoRoot 'src\agent\windows\Modules'
    # Get-DriftedTopLevelResourceNames depends on Get-NestedProperty + Get-PowerShellAdapterCompliance.
    Import-Module (Join-Path $script:ModuleRoot 'Dsc.ResultProjection.psm1') -Force
    Import-Module (Join-Path $script:ModuleRoot 'Dsc.ConfigFilter.psm1') -Force

    . (Join-Path $script:RepoRoot 'tests\fixtures\Dsc.ConfigFilter.Fixtures.ps1')

    # Splits a here-string YAML wrapper into a string[] for Get-WrapperDependsOnNames.
    function script:ToLines { param([string]$Text) return @($Text -split "`r?`n") }

    function script:New-FlowDependsOnConfig {
        param([Parameter(Mandatory)][string]$Path)

        $newline = [System.Environment]::NewLine
        $text = New-DscConfigText -Wrappers @(
            @{ Name = 'WrapperA' }
            @{ Name = 'WrapperB' }
            @{ Name = 'WrapperConsumer' }
        )
        $marker = '  - name: WrapperConsumer' + $newline + '    type: Microsoft.DSC/PowerShell' + $newline
        $dependencies = '    dependsOn: ["[resourceId(''Microsoft.DSC/PowerShell'', ''WrapperA'')]", "[resourceId(''Microsoft.DSC/PowerShell'', ''WrapperB'')]"]'
        $text = $text.Replace($marker, $marker + $dependencies + $newline)
        [System.IO.File]::WriteAllText($Path, $text, [System.Text.UTF8Encoding]::new($false))
        return $Path
    }

    # Tracks temp configs the New-* functions return so AfterEach can clean them
    # (the documented contract is: function returns the path, caller cleans).
    $script:TempArtifacts = New-Object System.Collections.Generic.List[string]
    function script:Track { param([string]$Path) $script:TempArtifacts.Add($Path); return $Path }
    function script:Clear-TempArtifacts {
        foreach ($p in $script:TempArtifacts) {
            if ($p -and (Test-Path -LiteralPath $p)) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
        }
        $script:TempArtifacts.Clear()
    }
}

Describe 'Get-WrapperDependsOnNames' {

    It 'parses inline flow array [A, B]' {
        $wrapper = @'
  - name: WrapperB
    type: Microsoft.DSC/PowerShell
    dependsOn: [WrapperA, WrapperC]
    properties:
      resources:
        - name: WrapperB-inner
          type: PSDscResources/Script
'@
        $names = Get-WrapperDependsOnNames -WrapperLines (ToLines $wrapper) -WrapperRootIndent 2
        $names | Should -Be @('WrapperA', 'WrapperC')
    }

    It 'parses a single inline resourceId item without splitting its arguments' {
        $wrapper = @'
  - name: WrapperB
    type: Microsoft.DSC/PowerShell
    dependsOn: ["[resourceId('Microsoft.DSC/PowerShell', 'WrapperA')]"]
    properties:
      resources:
        - name: WrapperB-inner
'@
        $names = Get-WrapperDependsOnNames -WrapperLines (ToLines $wrapper) -WrapperRootIndent 2
        $names | Should -Be @('WrapperA')
    }

    It 'parses every inline resourceId item in a flow list' {
        $wrapper = @'
  - name: WrapperC
    type: Microsoft.DSC/PowerShell
    dependsOn: ["[resourceId('Microsoft.DSC/PowerShell', 'WrapperA')]", "[resourceId('Microsoft.DSC/PowerShell', 'WrapperB')]"]
    properties:
      resources:
        - name: WrapperC-inner
'@
        $names = Get-WrapperDependsOnNames -WrapperLines (ToLines $wrapper) -WrapperRootIndent 2
        $names | Should -Be @('WrapperA', 'WrapperB')
    }

    It 'parses a block list' {
        $wrapper = @'
  - name: WrapperB
    type: Microsoft.DSC/PowerShell
    dependsOn:
      - WrapperA
      - WrapperC
    properties:
      resources:
        - name: WrapperB-inner
'@
        $names = Get-WrapperDependsOnNames -WrapperLines (ToLines $wrapper) -WrapperRootIndent 2
        $names | Should -Be @('WrapperA', 'WrapperC')
    }

    It 'parses all resourceId items in a block list' {
        $wrapper = @'
  - name: WrapperC
    type: Microsoft.DSC/PowerShell
    dependsOn:
      - "[resourceId('Microsoft.DSC/PowerShell', 'WrapperA')]"
      - "[resourceId('Microsoft.DSC/PowerShell', 'WrapperB')]"
    properties:
      resources:
        - name: WrapperC-inner
'@
        $names = Get-WrapperDependsOnNames -WrapperLines (ToLines $wrapper) -WrapperRootIndent 2
        $names | Should -Be @('WrapperA', 'WrapperB')
    }

    It 'parses a single scalar' {
        $wrapper = @'
  - name: WrapperB
    type: Microsoft.DSC/PowerShell
    dependsOn: WrapperA
    properties:
      resources:
        - name: WrapperB-inner
'@
        $names = Get-WrapperDependsOnNames -WrapperLines (ToLines $wrapper) -WrapperRootIndent 2
        $names | Should -Be @('WrapperA')
    }

    It 'resolves the [resourceId(Type, Name)] form to the bare wrapper name' {
        $wrapper = @'
  - name: WrapperB
    type: Microsoft.DSC/PowerShell
    dependsOn:
      - "[resourceId('Microsoft.DSC/PowerShell', 'WrapperA')]"
    properties:
      resources:
        - name: WrapperB-inner
'@
        $names = Get-WrapperDependsOnNames -WrapperLines (ToLines $wrapper) -WrapperRootIndent 2
        $names | Should -Be @('WrapperA')
    }

    It 'throws on a multi-line flow array' {
        $wrapper = @'
  - name: WrapperB
    type: Microsoft.DSC/PowerShell
    dependsOn: [
      WrapperA,
      WrapperC
    ]
    properties:
      resources:
        - name: WrapperB-inner
'@
        { Get-WrapperDependsOnNames -WrapperLines (ToLines $wrapper) -WrapperRootIndent 2 } |
            Should -Throw -ExpectedMessage '*multi-line flow dependsOn arrays are not supported*'
    }

    It 'does NOT false-positive on an inner properties.resources[].dependsOn' {
        $wrapper = @'
  - name: WrapperX
    type: Microsoft.DSC/PowerShell
    properties:
      resources:
        - name: WrapperX-inner
          type: PSDscResources/Script
          dependsOn:
            - "[resourceId('PSDscResources/Script', 'SomeInnerResource')]"
          properties:
            Ensure: Present
'@
        $names = Get-WrapperDependsOnNames -WrapperLines (ToLines $wrapper) -WrapperRootIndent 2
        @($names).Count | Should -Be 0
    }

    It 'returns an empty array when the wrapper has no dependsOn' {
        $wrapper = @'
  - name: WrapperA
    type: Microsoft.DSC/PowerShell
    properties:
      resources:
        - name: WrapperA-inner
          type: PSDscResources/Script
'@
        $names = Get-WrapperDependsOnNames -WrapperLines (ToLines $wrapper) -WrapperRootIndent 2
        @($names).Count | Should -Be 0
    }
}

Describe 'New-StrippedConfigExcludingResources' {

    AfterEach { Clear-TempArtifacts }

    It 'strips the full reverse-dependsOn closure of a linear chain (exclude A -> A,B,C) and keeps independents' {
        # Chain: B dependsOn A, C dependsOn B. D is independent.
        $cfg = Track (New-DscConfigFile -Path (Join-Path $TestDrive 'chain.yaml') -Wrappers @(
                @{ Name = 'WrapperA' }
                @{ Name = 'WrapperB'; DependsOn = @('WrapperA') }
                @{ Name = 'WrapperC'; DependsOn = @('WrapperB') }
                @{ Name = 'WrapperD' }
            ))

        $result = New-StrippedConfigExcludingResources -SourcePath $cfg -ExcludeResourceNames @('WrapperA')
        $null = Track $result.Path

        @($result.ExcludedNames) | Should -Be @('WrapperA', 'WrapperB', 'WrapperC')
        @($result.KeptNames) | Should -Be @('WrapperD')
        Assert-NoDanglingDependsOn -Path $result.Path
    }

    It 'strips a diamond branch (exclude B -> B,D) leaving the sibling arm intact' {
        # Diamond: B dependsOn A, C dependsOn A, D dependsOn B and C.
        $cfg = Track (New-DscConfigFile -Path (Join-Path $TestDrive 'diamond.yaml') -Wrappers @(
                @{ Name = 'WrapperA' }
                @{ Name = 'WrapperB'; DependsOn = @('WrapperA') }
                @{ Name = 'WrapperC'; DependsOn = @('WrapperA') }
                @{ Name = 'WrapperD'; DependsOn = @('WrapperB', 'WrapperC') }
            ))

        $result = New-StrippedConfigExcludingResources -SourcePath $cfg -ExcludeResourceNames @('WrapperB')
        $null = Track $result.Path

        @($result.ExcludedNames) | Sort-Object | Should -Be @('WrapperB', 'WrapperD')
        @($result.KeptNames) | Sort-Object | Should -Be @('WrapperA', 'WrapperC')
        Assert-NoDanglingDependsOn -Path $result.Path
    }

    It 'terminates on a dependsOn cycle (A and B depend on each other) and keeps the unrelated wrapper' {
        $cfg = Track (New-DscConfigFile -Path (Join-Path $TestDrive 'cycle.yaml') -Wrappers @(
                @{ Name = 'WrapperA'; DependsOn = @('WrapperB') }
                @{ Name = 'WrapperB'; DependsOn = @('WrapperA') }
                @{ Name = 'WrapperC' }
            ))

        $result = New-StrippedConfigExcludingResources -SourcePath $cfg -ExcludeResourceNames @('WrapperA')
        $null = Track $result.Path

        @($result.ExcludedNames) | Sort-Object | Should -Be @('WrapperA', 'WrapperB')
        @($result.KeptNames) | Should -Be @('WrapperC')
        Assert-NoDanglingDependsOn -Path $result.Path
    }

    It 'matches excluded names case-insensitively' {
        $cfg = Track (New-DscConfigFile -Path (Join-Path $TestDrive 'case.yaml') -Wrappers @(
                @{ Name = 'WrapperA' }
                @{ Name = 'WrapperB'; DependsOn = @('WrapperA') }
                @{ Name = 'WrapperC' }
            ))

        $result = New-StrippedConfigExcludingResources -SourcePath $cfg -ExcludeResourceNames @('wRaPpErA')
        $null = Track $result.Path

        @($result.ExcludedNames) | Sort-Object | Should -Be @('WrapperA', 'WrapperB')
        @($result.KeptNames) | Should -Be @('WrapperC')
    }

    It 'strips only the culprit when nothing depends on it' {
        $cfg = Track (New-DscConfigFile -Path (Join-Path $TestDrive 'leaf.yaml') -Wrappers @(
                @{ Name = 'WrapperA' }
                @{ Name = 'WrapperB'; DependsOn = @('WrapperA') }
                @{ Name = 'WrapperC' }
            ))

        # WrapperC has no dependents and depends on nothing.
        $result = New-StrippedConfigExcludingResources -SourcePath $cfg -ExcludeResourceNames @('WrapperC')
        $null = Track $result.Path

        @($result.ExcludedNames) | Should -Be @('WrapperC')
        @($result.KeptNames) | Sort-Object | Should -Be @('WrapperA', 'WrapperB')
        Assert-NoDanglingDependsOn -Path $result.Path
    }

    It 'strips multiple culprits and each of their reverse closures' {
        # Two independent chains: B<-A and D<-C; plus independent E.
        $cfg = Track (New-DscConfigFile -Path (Join-Path $TestDrive 'multi.yaml') -Wrappers @(
                @{ Name = 'WrapperA' }
                @{ Name = 'WrapperB'; DependsOn = @('WrapperA') }
                @{ Name = 'WrapperC' }
                @{ Name = 'WrapperD'; DependsOn = @('WrapperC') }
                @{ Name = 'WrapperE' }
            ))

        $result = New-StrippedConfigExcludingResources -SourcePath $cfg -ExcludeResourceNames @('WrapperA', 'WrapperC')
        $null = Track $result.Path

        @($result.ExcludedNames) | Sort-Object | Should -Be @('WrapperA', 'WrapperB', 'WrapperC', 'WrapperD')
        @($result.KeptNames) | Should -Be @('WrapperE')
        Assert-NoDanglingDependsOn -Path $result.Path
    }

    It 'throws when stripping the culprit and its closure would leave no resources' {
        $cfg = Track (New-DscConfigFile -Path (Join-Path $TestDrive 'empty.yaml') -Wrappers @(
                @{ Name = 'WrapperA' }
                @{ Name = 'WrapperB'; DependsOn = @('WrapperA') }
            ))

        { New-StrippedConfigExcludingResources -SourcePath $cfg -ExcludeResourceNames @('WrapperA') } |
            Should -Throw -ExpectedMessage '*leaves no resources*'
    }

    It 'throws when an excluded name is not present in the source' {
        $cfg = Track (New-DscConfigFile -Path (Join-Path $TestDrive 'absent.yaml') -Wrappers @(
                @{ Name = 'WrapperA' }
                @{ Name = 'WrapperB' }
            ))

        { New-StrippedConfigExcludingResources -SourcePath $cfg -ExcludeResourceNames @('WrapperZ') } |
            Should -Throw -ExpectedMessage "*excluded wrapper 'WrapperZ' is not present*"
    }

    It 'returns a pscustomobject whose temp Path exists and is left for the caller to clean' {
        $cfg = Track (New-DscConfigFile -Path (Join-Path $TestDrive 'contract.yaml') -Wrappers @(
                @{ Name = 'WrapperA' }
                @{ Name = 'WrapperB' }
            ))

        $result = New-StrippedConfigExcludingResources -SourcePath $cfg -ExcludeResourceNames @('WrapperA')
        $null = Track $result.Path

        $result | Should -BeOfType ([pscustomobject])
        $result.PSObject.Properties.Name | Should -Contain 'Path'
        $result.PSObject.Properties.Name | Should -Contain 'ExcludedNames'
        $result.PSObject.Properties.Name | Should -Contain 'KeptNames'
        # Contract: function writes a temp file and returns its path WITHOUT deleting it.
        Test-Path -LiteralPath $result.Path | Should -BeTrue
        $result.Path | Should -BeLike (Join-Path ([System.IO.Path]::GetTempPath()) 'dsc-recovery-*.yaml')
    }
}

Describe 'New-FilteredConfigForResources' {

    AfterEach { Clear-TempArtifacts }

    It 'forward-expands transitive dependsOn (request C -> emits C, B, A)' {
        $cfg = Track (New-DscConfigFile -Path (Join-Path $TestDrive 'fwd.yaml') -Wrappers @(
                @{ Name = 'WrapperA' }
                @{ Name = 'WrapperB'; DependsOn = @('WrapperA') }
                @{ Name = 'WrapperC'; DependsOn = @('WrapperB') }
                @{ Name = 'WrapperD' }
            ))

        $path = Track (New-FilteredConfigForResources -SourcePath $cfg -ResourceNames @('WrapperC'))
        $emitted = Get-EmittedWrapperGraph -Path $path

        @($emitted.Keys) | Sort-Object | Should -Be @('WrapperA', 'WrapperB', 'WrapperC')
        # No surviving dependsOn points outside the emitted set.
        Assert-NoDanglingDependsOn -Path $path
    }

    It 'throws when a referenced wrapper is missing from the source' {
        # WrapperB dependsOn a wrapper that is not in the config -> BFS hits a missing node.
        $cfg = Track (New-DscConfigFile -Path (Join-Path $TestDrive 'missing.yaml') -Wrappers @(
                @{ Name = 'WrapperA' }
                @{ Name = 'WrapperB'; DependsOn = @('WrapperGhost') }
            ))

        { New-FilteredConfigForResources -SourcePath $cfg -ResourceNames @('WrapperB') } |
            Should -Throw -ExpectedMessage "*wrapper 'WrapperGhost' is referenced*"
    }

    It 'emits exactly the named wrappers under -NoDependsOnExpansion' {
        $cfg = Track (New-DscConfigFile -Path (Join-Path $TestDrive 'noexpand.yaml') -Wrappers @(
                @{ Name = 'WrapperA' }
                @{ Name = 'WrapperB'; DependsOn = @('WrapperA') }
                @{ Name = 'WrapperC'; DependsOn = @('WrapperB') }
            ))

        $path = Track (New-FilteredConfigForResources -SourcePath $cfg -ResourceNames @('WrapperC') -NoDependsOnExpansion)
        $emitted = Get-EmittedWrapperGraph -Path $path

        @($emitted.Keys) | Should -Be @('WrapperC')
    }

    It 'returns a temp Path that exists and is left for the caller to clean' {
        $cfg = Track (New-DscConfigFile -Path (Join-Path $TestDrive 'fwd-contract.yaml') -Wrappers @(
                @{ Name = 'WrapperA' }
            ))

        $path = New-FilteredConfigForResources -SourcePath $cfg -ResourceNames @('WrapperA')
        $null = Track $path

        Test-Path -LiteralPath $path | Should -BeTrue
        $path | Should -BeLike (Join-Path ([System.IO.Path]::GetTempPath()) 'dsc-set-subset-*.yaml')
    }

    It 'forward-expands every dependency in an inline resourceId flow list' {
        $cfg = Track (New-FlowDependsOnConfig -Path (Join-Path $TestDrive 'flow-filter.yaml'))
        $path = Track (New-FilteredConfigForResources -SourcePath $cfg -ResourceNames @('WrapperConsumer'))
        $graph = Get-EmittedWrapperGraph -Path $path

        @($graph.Keys | Sort-Object) | Should -Be @('WrapperA', 'WrapperB', 'WrapperConsumer')
        @($graph['WrapperConsumer'] | Sort-Object) | Should -Be @('WrapperA', 'WrapperB')
    }

    It 'reverse-strips wrappers depending on any inline resourceId flow-list entry' {
        $cfg = Track (New-FlowDependsOnConfig -Path (Join-Path $TestDrive 'flow-reverse.yaml'))
        $result = New-StrippedConfigExcludingResources -SourcePath $cfg -ExcludeResourceNames @('WrapperA')
        $null = Track $result.Path

        @($result.ExcludedNames | Sort-Object) | Should -Be @('WrapperA', 'WrapperConsumer')
        @($result.KeptNames) | Should -Be @('WrapperB')
    }
}

Describe 'Get-DriftedTopLevelResourceNames' {

    It 'returns only wrappers that are not in their desired state' {
        # Non-adapter leaf entries: result.inDesiredState drives the verdict.
        # Missing inDesiredState defaults to drifted (included).
        $parsed = [pscustomobject]@{
            Results = @(
                [pscustomobject]@{ name = 'Compliant'; result = [pscustomobject]@{ inDesiredState = $true } }
                [pscustomobject]@{ name = 'Drifted';   result = [pscustomobject]@{ inDesiredState = $false } }
                [pscustomobject]@{ name = 'Unknown';   result = [pscustomobject]@{ } }
            )
        }

        $names = Get-DriftedTopLevelResourceNames -ParsedTest $parsed
        @($names) | Sort-Object | Should -Be @('Drifted', 'Unknown')
        @($names) | Should -Not -Contain 'Compliant'
    }
}

Describe 'Get-WrapperInnerTypeMap' {

    It 'maps an adapter wrapper name to its AdapterType and InnerType' {
        # The fixture generator emits Microsoft.DSC/PowerShell wrappers nesting a single
        # PSDscResources/Script inner resource — exactly the composed-fragment shape.
        $cfg = New-DscConfigFile -Path (Join-Path $TestDrive 'innertype-wrapper.yaml') -Wrappers @(
                @{ Name = 'WrapperA' }
            )

        $map = Get-WrapperInnerTypeMap -ConfigFilePath $cfg

        @($map.Keys) | Should -Be @('WrapperA')
        $map['WrapperA'].AdapterType | Should -Be 'Microsoft.DSC/PowerShell'
        $map['WrapperA'].InnerType | Should -Be 'PSDscResources/Script'
    }

    It 'yields no entry for a non-wrapper (no nested resources:) root resource' {
        # Mix a real wrapper with a plain leaf resource that has no nested resources: list.
        # Detection is structural, so only the wrapper is mapped; the leaf is excluded.
        $text = New-DscConfigText -Wrappers @(@{ Name = 'WrapperA' })
        $leaf = @'
  - name: PlainLeaf
    type: PSDscResources/Script
    properties:
      Ensure: Present
'@
        $path = Join-Path $TestDrive 'innertype-mixed.yaml'
        [System.IO.File]::WriteAllText($path, ($text + $leaf), [System.Text.UTF8Encoding]::new($false))

        $map = Get-WrapperInnerTypeMap -ConfigFilePath $path

        @($map.Keys) | Should -Be @('WrapperA')
        @($map.Keys) | Should -Not -Contain 'PlainLeaf'
    }

    It 'returns an empty hashtable for a missing file (no throw)' {
        $missing = Join-Path $TestDrive 'innertype-does-not-exist.yaml'

        # Should not throw, and should yield a zero-entry collection.
        $map = Get-WrapperInnerTypeMap -ConfigFilePath $missing

        @($map.Keys).Count | Should -Be 0
    }
}
