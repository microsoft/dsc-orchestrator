#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'Azure Pipelines templates' {
    BeforeAll {
        $script:RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
        $script:PipelineRoot = Join-Path $script:RepoRoot 'pipelines'
        $script:TemplateRoot = Join-Path $script:PipelineRoot 'templates'
        $script:ExampleRoot = Join-Path $script:RepoRoot 'examples\pipelines'
        $yamlModule = Get-Module -ListAvailable -Name powershell-yaml |
            Where-Object { $_.Version -eq [version]'0.4.12' } |
            Select-Object -First 1
        if ($yamlModule) {
            $yamlModulePath = $yamlModule.Path
        }
        elseif (Get-Command -Name Get-InstalledModule -ErrorAction SilentlyContinue) {
            $installedYamlModule = Get-InstalledModule -Name powershell-yaml `
                -RequiredVersion 0.4.12 -ErrorAction Stop
            $yamlModulePath = Join-Path $installedYamlModule.InstalledLocation 'powershell-yaml.psd1'
        }
        else {
            throw 'powershell-yaml 0.4.12 is required to validate pipeline YAML.'
        }
        Import-Module -Name $yamlModulePath -Force -ErrorAction Stop

        $script:YamlFiles = @(
            Get-ChildItem -LiteralPath $script:PipelineRoot -Filter '*.yaml' -Recurse -File -ErrorAction Stop
            Get-ChildItem -LiteralPath $script:ExampleRoot -Filter '*.yaml' -Recurse -File -ErrorAction Stop
        )
        $script:ScriptPaths = @{
            'New-DscOrchestratorPackage.ps1' = Join-Path $script:RepoRoot 'build\New-DscOrchestratorPackage.ps1'
            'Publish-DSCv3VMApp.ps1' = Join-Path $script:RepoRoot 'src\adapters\delivery\azure-vmapp\Publish-DSCv3VMApp.ps1'
            'Deploy-DSCv3VMApp.ps1' = Join-Path $script:RepoRoot 'src\adapters\delivery\azure-vmapp\Deploy-DSCv3VMApp.ps1'
        }
        $script:ExpectedScriptCalls = @(
            [pscustomobject]@{
                Template = 'build-package.yaml'
                Script = 'New-DscOrchestratorPackage.ps1'
                ParameterSets = @('configpath,outputpath,repositoryname')
            }
            [pscustomobject]@{
                Template = 'publish-vmapp.yaml'
                Script = 'Publish-DSCv3VMApp.ps1'
                ParameterSets = @('applicationname,containername,galleryname,galleryresourcegroup,ifexists,location,packagepath,storageaccountname,storageaccountresourcegroup,subscriptionid,targetregions,version,vmresourcegroupname')
            }
            [pscustomobject]@{
                Template = 'deploy-vmapp.yaml'
                Script = 'Deploy-DSCv3VMApp.ps1'
                ParameterSets = @('resourcegroupname,subscriptionid,vmappversionresourceid,vmnames')
            }
        )

        function Get-YamlInlineScripts {
            [CmdletBinding()]
            param([Parameter()][AllowNull()][object]$Node)

            if ($null -eq $Node -or $Node -is [string]) {
                return
            }
            if ($Node -is [System.Collections.IDictionary]) {
                foreach ($key in $Node.Keys) {
                    $value = $Node[$key]
                    if (($key -ieq 'script' -or $key -ieq 'inline') -and $value -is [string]) {
                        $value
                    }
                    else {
                        Get-YamlInlineScripts -Node $value
                    }
                }
                return
            }
            if ($Node -is [System.Collections.IEnumerable]) {
                foreach ($item in $Node) {
                    Get-YamlInlineScripts -Node $item
                }
                return
            }
            if ($Node -isnot [pscustomobject]) {
                return
            }
            foreach ($property in $Node.PSObject.Properties) {
                $value = $property.Value
                if (($property.Name -ieq 'script' -or $property.Name -ieq 'inline') -and $value -is [string]) {
                    $value
                }
                else {
                    Get-YamlInlineScripts -Node $value
                }
            }
        }

        function Get-ScriptInvocationParameterNames {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true)]
                [System.Management.Automation.Language.CommandAst]$Invocation,

                [Parameter(Mandatory = $true)]
                [System.Management.Automation.Language.ScriptBlockAst]$TemplateAst
            )

            $parameterNames = @()
            foreach ($element in $Invocation.CommandElements) {
                if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
                    if ($parameterNames -notcontains $element.ParameterName) {
                        $parameterNames += $element.ParameterName
                    }
                    continue
                }
                if ($element -isnot [System.Management.Automation.Language.VariableExpressionAst] -or -not $element.Splatted) {
                    continue
                }

                $splatName = $element.VariablePath.UserPath
                $assignments = @(
                    $TemplateAst.FindAll({
                        param($node)
                        if ($node -isnot [System.Management.Automation.Language.AssignmentStatementAst]) {
                            return $false
                        }
                        $left = $node.Left
                        if ($left -is [System.Management.Automation.Language.VariableExpressionAst]) {
                            return $left.VariablePath.UserPath -ieq $splatName
                        }
                        if ($left -is [System.Management.Automation.Language.MemberExpressionAst] -and
                            $left.Expression -is [System.Management.Automation.Language.VariableExpressionAst]) {
                            return $left.Expression.VariablePath.UserPath -ieq $splatName
                        }
                        return $false
                    }, $true)
                )
                foreach ($assignment in $assignments) {
                    $hashtableAsts = @(
                        $assignment.Right.FindAll({
                            param($node)
                            $node -is [System.Management.Automation.Language.HashtableAst]
                        }, $true)
                    )
                    foreach ($hashtableAst in $hashtableAsts) {
                        foreach ($pair in $hashtableAst.KeyValuePairs) {
                            $name = $pair.Item1.Extent.Text.Trim([char[]]@("'", '"'))
                            if (-not [string]::IsNullOrWhiteSpace($name) -and $parameterNames -notcontains $name) {
                                $parameterNames += $name
                            }
                        }
                    }
                    if ($assignment.Left -is [System.Management.Automation.Language.MemberExpressionAst]) {
                        $name = $assignment.Left.Member.Extent.Text.Trim([char[]]@("'", '"'))
                        if (-not [string]::IsNullOrWhiteSpace($name) -and $parameterNames -notcontains $name) {
                            $parameterNames += $name
                        }
                    }
                }
            }

            return @($parameterNames | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object)
        }
    }

    It 'parses every pipeline YAML file' {
        $script:YamlFiles.Count | Should -BeGreaterThan 0
        foreach ($yamlFile in $script:YamlFiles) {
            $yamlText = Get-Content -LiteralPath $yamlFile.FullName -Raw -ErrorAction Stop
            {
                $null = ConvertFrom-Yaml -Yaml $yamlText -ErrorAction Stop
            } | Should -Not -Throw
        }
    }

    It 'passes only parameters declared by each invoked PowerShell script' {
        $templateNames = @('build-package.yaml', 'publish-vmapp.yaml', 'deploy-vmapp.yaml')
        foreach ($templateName in $templateNames) {
            $templatePath = Join-Path $script:TemplateRoot $templateName
            $yamlText = Get-Content -LiteralPath $templatePath -Raw -ErrorAction Stop
            $document = ConvertFrom-Yaml -Yaml $yamlText -ErrorAction Stop
            $inlineScripts = @(Get-YamlInlineScripts -Node $document)
            $inlineScripts.Count | Should -BeGreaterThan 0

            $tokens = $null
            $parseErrors = $null
            $templateAst = [System.Management.Automation.Language.Parser]::ParseInput(
                ($inlineScripts -join [Environment]::NewLine),
                [ref]$tokens,
                [ref]$parseErrors
            )
            $parseErrors | Should -BeNullOrEmpty

            $expectedCalls = @($script:ExpectedScriptCalls | Where-Object { $_.Template -eq $templateName })
            foreach ($expectedCall in $expectedCalls) {
                $scriptPath = $script:ScriptPaths[$expectedCall.Script]
                if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
                    throw "Expected PowerShell script was not found: $scriptPath"
                }

                $scriptTokens = $null
                $scriptParseErrors = $null
                $scriptAst = [System.Management.Automation.Language.Parser]::ParseFile(
                    $scriptPath,
                    [ref]$scriptTokens,
                    [ref]$scriptParseErrors
                )
                $scriptParseErrors | Should -BeNullOrEmpty
                $scriptAst.ParamBlock | Should -Not -BeNullOrEmpty
                $validParameters = @(
                    $scriptAst.ParamBlock.Parameters |
                        ForEach-Object { $_.Name.VariablePath.UserPath.ToLowerInvariant() }
                )

                $scriptCalls = @(
                    $templateAst.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.CommandAst] -and
                            $node.Extent.Text.IndexOf(
                                $expectedCall.Script,
                                [System.StringComparison]::OrdinalIgnoreCase
                            ) -ge 0
                    }, $true) |
                        Where-Object {
                            @($_.CommandElements | Where-Object {
                                $_ -is [System.Management.Automation.Language.CommandParameterAst] -or
                                ($_ -is [System.Management.Automation.Language.VariableExpressionAst] -and $_.Splatted)
                            }).Count -gt 0
                        }
                )
                $scriptCalls.Count | Should -Be $expectedCall.ParameterSets.Count

                $actualParameterSets = @()
                foreach ($scriptCall in $scriptCalls) {
                    $callParameters = @(
                        Get-ScriptInvocationParameterNames -Invocation $scriptCall -TemplateAst $templateAst
                    )
                    foreach ($parameterName in $callParameters) {
                        $validParameters | Should -Contain $parameterName
                    }
                    $actualParameterSets += $callParameters -join ','
                }
                (@($actualParameterSets | Sort-Object) -join ';') |
                    Should -Be (@($expectedCall.ParameterSets | Sort-Object) -join ';')
            }
        }
    }
}
