#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Set-StrictMode -Version Latest

BeforeAll {
    $script:RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..'))
    $script:AdapterRoot = Join-Path $script:RepoRoot 'src\adapters\reporting\azure-monitor'
    $script:BicepPath = Join-Path $script:AdapterRoot 'dcr.bicep'
    $script:ArmPath = Join-Path $script:AdapterRoot 'dcr.json'
    $script:DeployScript = Join-Path $script:AdapterRoot 'Deploy-DscOrchestratorReporting.ps1'
    $script:ConnectScript = Join-Path $script:AdapterRoot 'Connect-DscOrchestratorReporting.ps1'
    $script:ResultSchema = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'src\core\contracts\run-result.schema.json') -Raw |
        ConvertFrom-Json
    $script:ArmTemplate = Get-Content -LiteralPath $script:ArmPath -Raw | ConvertFrom-Json
    $script:DcrResourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/monitoring-rg/providers/Microsoft.Insights/dataCollectionRules/dsc-orchestrator-rule'
    $script:VmResourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/workload-rg/providers/Microsoft.Compute/virtualMachines/vm01'

    $script:ExpectedColumns = [ordered]@{
        DscOrchestrator_Runs_CL = @(
            'schema_version', 'run_id', 'TimeGenerated', 'Computer', 'group', 'role',
            'config_version', 'configuration_hash', 'dsc_exe_version', 'mode', 'trigger',
            'outcome', 'total_resources', 'compliant_resources', 'non_compliant_count',
            'failed_count', 'skipped_count', 'unevaluated_count', 'had_errors',
            'test_duration', 'set_duration', 'verify_duration', 'total_duration', 'exit_code',
            'error', 'non_compliant_resources', 'erroring_resources', 'reboot_count', 'enforcement_id'
        )
        DscOrchestrator_Resources_CL = @(
            'schema_version', 'run_id', 'TimeGenerated', 'Computer', 'group', 'role',
            'config_version', 'configuration_hash', 'fragment', 'trigger', 'phase', 'adapter',
            'adapter_instance_name', 'resource_type', 'resource_name', 'in_desired_state',
            'reasons', 'action', 'event', 'result', 'had_errors', 'error_message', 'duration',
            'duration_source', 'completion_kind'
        )
        DscOrchestrator_Bootstrap_CL = @(
            'TimeGenerated', 'Computer', 'config_version', 'stage', 'status', 'message',
            'pwsh_source', 'pwsh_path', 'pwsh_version', 'error_type', 'error_message'
        )
        DscOrchestrator_ModuleLogs_CL = @(
            'TimeGenerated', 'Computer', 'schema_version', 'run_id', 'level', 'app_context',
            'module_name', 'function_name', 'message', 'pid'
        )
    }
    $script:ColumnVariables = @{
        DscOrchestrator_Runs_CL = 'runsColumns'
        DscOrchestrator_Resources_CL = 'resourcesColumns'
        DscOrchestrator_Bootstrap_CL = 'bootstrapColumns'
        DscOrchestrator_ModuleLogs_CL = 'moduleLogsColumns'
    }

    function Get-BicepColumnDetails {
        param(
            [Parameter(Mandatory = $true)]
            [string]$VariableName
        )

        $source = [System.IO.File]::ReadAllText($script:BicepPath)
        $pattern = '(?s)var\s+' + [regex]::Escape($VariableName) + '\s*=\s*\[(?<columns>.*?)\r?\n\]'
        $match = [regex]::Match($source, $pattern)
        if (-not $match.Success) {
            throw "Could not find Bicep column array '$VariableName'."
        }

        @([regex]::Matches($match.Groups['columns'].Value, "name:\s*'([^']+)'\s*,?\s*type:\s*'([^']+)'") |
            ForEach-Object {
                [pscustomobject]@{
                    Name = $_.Groups[1].Value
                    Type = $_.Groups[2].Value
                }
            })
    }

    function Get-ExpectedColumnType {
        param(
            [Parameter(Mandatory = $true)]
            [string]$TableName,

            [Parameter(Mandatory = $true)]
            [string]$ColumnName
        )

        if ($TableName -eq 'DscOrchestrator_Bootstrap_CL') {
            if ($ColumnName -eq 'TimeGenerated') { return 'datetime' }
            return 'string'
        }
        if ($TableName -eq 'DscOrchestrator_ModuleLogs_CL') {
            if ($ColumnName -eq 'TimeGenerated') { return 'datetime' }
            if ($ColumnName -eq 'pid') { return 'int' }
            return 'string'
        }

        $schemaTitle = if ($TableName -eq 'DscOrchestrator_Runs_CL') { 'Run result' } else { 'Resource result' }
        $definition = @($script:ResultSchema.oneOf | Where-Object { $_.title -eq $schemaTitle })[0].properties.$ColumnName
        if ($null -eq $definition) {
            throw "Column '$ColumnName' was not found in the $schemaTitle schema."
        }

        $schemaType = if ($definition.type -is [array]) {
            @($definition.type | Where-Object { $_ -ne 'null' })[0]
        }
        else {
            [string]$definition.type
        }
        if ($definition.format -eq 'date-time') { return 'datetime' }

        switch ($schemaType) {
            'integer' { return 'int' }
            'number' { return 'real' }
            'boolean' { return 'boolean' }
            { $_ -in @('array', 'object') } { return 'dynamic' }
            default { return 'string' }
        }
    }

    function New-TestContext {
        [pscustomobject]@{
            Subscription = [pscustomobject]@{ Id = 'test-subscription' }
            Account = [pscustomobject]@{ Id = 'test-identity' }
        }
    }

    function New-TestVm {
        param(
            [string]$Name = 'vm01',
            [string]$IdentityType = 'SystemAssigned'
        )

        [pscustomobject]@{
            Name = $Name
            Id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/workload-rg/providers/Microsoft.Compute/virtualMachines/vm01'
            Identity = [pscustomobject]@{
                Type = $IdentityType
                UserAssignedIdentities = $null
            }
        }
    }
}

Describe 'DSC Orchestrator Azure Monitor reporting template' {
    It 'keeps each table column list exact in Bicep and the compiled ARM template' {
        foreach ($tableName in $script:ExpectedColumns.Keys) {
            $variableName = $script:ColumnVariables[$tableName]
            $expectedNames = @($script:ExpectedColumns[$tableName])
            $bicepColumns = @(Get-BicepColumnDetails -VariableName $variableName)
            $armColumns = @($script:ArmTemplate.variables.$variableName)

            (($bicepColumns | ForEach-Object { $_.Name }) -join '|') | Should -Be ($expectedNames -join '|')
            (($armColumns | ForEach-Object { $_.name }) -join '|') | Should -Be ($expectedNames -join '|')

            foreach ($columnName in $expectedNames) {
                $expectedType = Get-ExpectedColumnType -TableName $tableName -ColumnName $columnName
                $bicepType = @($bicepColumns | Where-Object { $_.Name -eq $columnName })[0].Type
                $armType = @($armColumns | Where-Object { $_.name -eq $columnName })[0].type
                $bicepType | Should -Be $expectedType
                $armType | Should -Be $expectedType
            }
        }

        $streamDeclarations = [string]$script:ArmTemplate.variables.streamDeclarations
        foreach ($tableName in $script:ExpectedColumns.Keys) {
            $variableName = $script:ColumnVariables[$tableName]
            $streamDeclarations | Should -Match (
                "Custom-{0}.*variables\('{1}'\)" -f [regex]::Escape($tableName),[regex]::Escape($variableName)
            )
        }
    }

    It 'uses each column array for its Log Analytics table schema' {
        $tableDeployment = @($script:ArmTemplate.resources | Where-Object {
            $_.type -eq 'Microsoft.Resources/deployments' -and
            $_.properties.template.resources
        })
        $tableDeployment | Should -HaveCount 1

        foreach ($tableName in $script:ExpectedColumns.Keys) {
            $tableResource = @($tableDeployment[0].properties.template.resources | Where-Object {
                $_.type -eq 'Microsoft.OperationalInsights/workspaces/tables' -and
                $_.properties.schema.name -eq $tableName
            })
            $tableResource | Should -HaveCount 1
            $variableName = $script:ColumnVariables[$tableName]
            [string]$tableResource[0].properties.schema.columns |
                Should -Be ("[parameters('{0}')]" -f $variableName)
            [string]$tableDeployment[0].properties.parameters.$variableName.value |
                Should -Be ("[variables('{0}')]" -f $variableName)
        }
    }

    It 'builds the three agent file patterns under dscRoot' {
        $bicepSource = [System.IO.File]::ReadAllText($script:BicepPath)
        $armText = [System.IO.File]::ReadAllText($script:ArmPath)
        foreach ($fileName in @('runs.jsonl', 'resources.jsonl', 'bootstrap.jsonl')) {
            $escapedName = [regex]::Escape($fileName)
            $bicepPattern = '\$\{dscRoot\}\\\\logs\\\\' + $escapedName
            $bicepSource | Should -Match $bicepPattern
            $armPattern = "format\('\{0\}\\\\logs\\\\$escapedName', parameters\('dscRoot'\)\)"
            $armText | Should -Match $armPattern
        }
        $script:ArmTemplate.parameters.dscRoot.defaultValue | Should -Be 'C:\ProgramData\DscOrchestrator'
    }

    It 'omits module logs by default and includes their table, stream, and source when enabled' {
        $script:ArmTemplate.parameters.enableModuleLogs.defaultValue | Should -BeFalse
        $script:ArmTemplate.parameters.moduleLogPath.defaultValue | Should -Be ''

        $tableDeployment = @($script:ArmTemplate.resources | Where-Object {
            $_.type -eq 'Microsoft.Resources/deployments' -and
            $_.properties.template.resources
        })
        $tableDeployment | Should -HaveCount 1

        $moduleTable = @($tableDeployment[0].properties.template.resources | Where-Object {
            $_.type -eq 'Microsoft.OperationalInsights/workspaces/tables' -and
            $_.properties.schema.name -eq 'DscOrchestrator_ModuleLogs_CL'
        })
        $moduleTable | Should -HaveCount 1
        [string]$moduleTable[0].condition | Should -Be "[parameters('enableModuleLogs')]"

        $bicepSource = [System.IO.File]::ReadAllText($script:BicepPath)
        $armText = [System.IO.File]::ReadAllText($script:ArmPath)
        $bicepSource | Should -Match 'var logFileSources = concat'
        $bicepSource | Should -Match 'moduleLogPath'
        $armText | Should -Match "parameters\('enableModuleLogs'\)"
        $armText | Should -Match "parameters\('moduleLogPath'\)"
        foreach ($variableName in @('logFileSources', 'streamDeclarations', 'dataFlows')) {
            $expression = [string]$script:ArmTemplate.variables.$variableName
            $expression | Should -Match "parameters\('enableModuleLogs'\)"
            $expression | Should -Match 'Custom-DscOrchestrator_ModuleLogs_CL'
        }
        $script:ArmTemplate.variables.moduleLogsColumns | Should -HaveCount 10
    }
}

Describe 'Deploy-DscOrchestratorReporting' {
    BeforeEach {
        Mock Get-AzContext { New-TestContext }
        Mock New-AzResourceGroupDeployment {
            [pscustomobject]@{
                Outputs = @{
                    dcrId = @{ Value = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/monitoring-rg/providers/Microsoft.Insights/dataCollectionRules/dsc-orchestrator-rule' }
                    dceId = @{ Value = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/monitoring-rg/providers/Microsoft.Insights/dataCollectionEndpoints/dsc-orchestrator-endpoint' }
                    tableNames = @{ Value = @('DscOrchestrator_Runs_CL', 'DscOrchestrator_Resources_CL', 'DscOrchestrator_Bootstrap_CL', 'DscOrchestrator_ModuleLogs_CL') }
                }
            }
        }
    }

    It 'deploys the compiled ARM template with the supplied parameters and returns resource IDs' {
        $result = & $script:DeployScript `
            -ResourceGroupName 'monitoring-rg' `
            -WorkspaceResourceId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/workspace-rg/providers/Microsoft.OperationalInsights/workspaces/test-workspace' `
            -Location 'eastus' `
            -DcrName 'dsc-orchestrator-rule' `
            -DceName 'dsc-orchestrator-endpoint' `
            -PublicNetworkAccess Disabled `
            -Tags @{ purpose = 'test' } `
            -RetentionInDays 30 `
            -DscRoot 'D:\Orchestrator' `
            -EnableModuleLogs `
            -ModuleLogPath 'D:\Logs\module.jsonl' `
            -Confirm:$false

        $result.DcrId | Should -Be $script:DcrResourceId
        $result.DceId | Should -Match '/dataCollectionEndpoints/dsc-orchestrator-endpoint$'
        $result.TableNames | Should -Contain 'DscOrchestrator_Bootstrap_CL'
        $result.TableNames | Should -Contain 'DscOrchestrator_ModuleLogs_CL'
        Should -Invoke New-AzResourceGroupDeployment -Times 1 -Exactly -ParameterFilter {
            $ResourceGroupName -eq 'monitoring-rg' -and
            [System.IO.Path]::GetFileName($TemplateFile) -eq 'dcr.json' -and
            $TemplateParameterObject.workspaceResourceId -like '*/workspaces/test-workspace' -and
            $TemplateParameterObject.location -eq 'eastus' -and
            $TemplateParameterObject.dcrName -eq 'dsc-orchestrator-rule' -and
            $TemplateParameterObject.dceName -eq 'dsc-orchestrator-endpoint' -and
            $TemplateParameterObject.publicNetworkAccess -eq 'Disabled' -and
            $TemplateParameterObject.tags.purpose -eq 'test' -and
            $TemplateParameterObject.retentionInDays -eq 30 -and
            $TemplateParameterObject.dscRoot -eq 'D:\Orchestrator' -and
            $TemplateParameterObject.enableModuleLogs -eq $true -and
            $TemplateParameterObject.moduleLogPath -eq 'D:\Logs\module.jsonl'
        }
    }

    It 'requires a module log path before attempting deployment' {
        {
            & $script:DeployScript `
                -ResourceGroupName 'monitoring-rg' `
                -WorkspaceResourceId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/workspace-rg/providers/Microsoft.OperationalInsights/workspaces/test-workspace' `
                -Location 'eastus' `
                -DcrName 'dsc-orchestrator-rule' `
                -DceName 'dsc-orchestrator-endpoint' `
                -EnableModuleLogs `
                -Confirm:$false
        } | Should -Throw '*-ModuleLogPath is required*'
        Should -Invoke New-AzResourceGroupDeployment -Times 0 -Exactly
    }

    It 'does not deploy when WhatIf is selected' {
        & $script:DeployScript `
            -ResourceGroupName 'monitoring-rg' `
            -WorkspaceResourceId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/workspace-rg/providers/Microsoft.OperationalInsights/workspaces/test-workspace' `
            -Location 'eastus' `
            -DcrName 'dsc-orchestrator-rule' `
            -DceName 'dsc-orchestrator-endpoint' `
            -WhatIf | Out-Null

        Should -Invoke New-AzResourceGroupDeployment -Times 0 -Exactly
    }
}

Describe 'Azure Monitor reporting script preferences' {
    It 'assigns ConfirmPreference with the ConfirmImpact enum in both scripts' {
        foreach ($scriptPath in @($script:DeployScript, $script:ConnectScript)) {
            $tokens = $null
            $parseErrors = $null
            $scriptAst = [System.Management.Automation.Language.Parser]::ParseFile(
                $scriptPath,
                [ref]$tokens,
                [ref]$parseErrors
            )
            $parseErrors | Should -BeNullOrEmpty

            $assignments = @($scriptAst.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $node.Left.VariablePath.UserPath -eq 'ConfirmPreference'
            }, $true))

            $assignments | Should -HaveCount 1
            $assignments[0].Right.Extent.Text |
                Should -Be '[System.Management.Automation.ConfirmImpact]::None'
        }
    }
}

Describe 'Connect-DscOrchestratorReporting' {
    BeforeEach {
        Mock Get-AzContext { New-TestContext }
        Mock Get-AzVM { New-TestVm }
        Mock Get-AzVMExtension {
            [pscustomobject]@{
                Name = 'AzureMonitorWindowsAgent'
                Publisher = 'Microsoft.Azure.Monitor'
                ExtensionType = 'AzureMonitorWindowsAgent'
                EnableAutomaticUpgrade = $true
            }
        }
        Mock Update-AzVM { }
        Mock Set-AzVMExtension { }
        Mock Get-AzDataCollectionRuleAssociation { @() }
        Mock New-AzDataCollectionRuleAssociation { }
    }

    It 'logs and skips an empty resource group successfully' {
        Mock Get-AzVM { @() }

        $result = & $script:ConnectScript `
            -ResourceGroupName 'workload-rg' `
            -DcrResourceId $script:DcrResourceId `
            -Confirm:$false

        $result.Skipped | Should -BeTrue
        $result.VmCount | Should -Be 0
        Should -Invoke Set-AzVMExtension -Times 0 -Exactly
        Should -Invoke New-AzDataCollectionRuleAssociation -Times 0 -Exactly
    }

    It 'does not reinstall an existing Azure Monitor Agent extension' {
        Mock Get-AzDataCollectionRuleAssociation {
            [pscustomobject]@{
                Name = 'existing-association'
                DataCollectionRuleId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/monitoring-rg/providers/Microsoft.Insights/dataCollectionRules/dsc-orchestrator-rule'
            }
        }

        $result = & $script:ConnectScript `
            -ResourceGroupName 'workload-rg' `
            -DcrResourceId $script:DcrResourceId `
            -VMNames @('vm01') `
            -Confirm:$false

        $result.AmaInstalledCount | Should -Be 0
        $result.AssociationExistsCount | Should -Be 1
        Should -Invoke Set-AzVMExtension -Times 0 -Exactly
        Should -Invoke Update-AzVM -Times 0 -Exactly
        Should -Invoke New-AzDataCollectionRuleAssociation -Times 0 -Exactly
    }

    It 'installs AMA with automatic upgrades and creates a Data Collection Rule association' {
        Mock Get-AzVMExtension { @() }
        $result = & $script:ConnectScript `
            -ResourceGroupName 'workload-rg' `
            -DcrResourceId $script:DcrResourceId `
            -VMNames @('vm01') `
            -Confirm:$false

        $result.AmaInstalledCount | Should -Be 1
        $result.AssociationCreatedCount | Should -Be 1
        Should -Invoke Set-AzVMExtension -Times 1 -Exactly -ParameterFilter {
            $Publisher -eq 'Microsoft.Azure.Monitor' -and
            $ExtensionType -eq 'AzureMonitorWindowsAgent' -and
            $EnableAutomaticUpgrade -eq $true
        }
        Should -Invoke New-AzDataCollectionRuleAssociation -Times 1 -Exactly -ParameterFilter {
            $AssociationName -eq 'dsc-orchestrator-reporting' -and
            $ResourceUri -like '*/virtualMachines/vm01' -and
            $DataCollectionRuleId -like '*/dataCollectionRules/dsc-orchestrator-rule'
        }
    }

    It 'enables a system-assigned identity when a VM does not have one' {
        Mock Get-AzVM {
            New-TestVm -IdentityType 'None'
        }
        Mock Get-AzVMExtension { @() }

        & $script:ConnectScript `
            -ResourceGroupName 'workload-rg' `
            -DcrResourceId $script:DcrResourceId `
            -VMNames @('vm01') `
            -Confirm:$false             | Out-Null

            Should -Invoke Update-AzVM -Times 1 -Exactly -ParameterFilter {
                $IdentityType -eq 'SystemAssigned'
            }
    }

    It 'does not run mutations in WhatIf mode' {
        Mock Get-AzVMExtension { @() }

        & $script:ConnectScript `
            -ResourceGroupName 'workload-rg' `
            -DcrResourceId $script:DcrResourceId `
            -VMNames @('vm01') `
            -WhatIf | Out-Null

        Should -Invoke Update-AzVM -Times 0 -Exactly
        Should -Invoke Set-AzVMExtension -Times 0 -Exactly
        Should -Invoke New-AzDataCollectionRuleAssociation -Times 0 -Exactly
    }

    It 'contains no Azure CLI command invocation in reporting adapter files' {
        $violations = @()
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'src\adapters\reporting\azure-monitor') -Recurse -File) {
            $content = [System.IO.File]::ReadAllText($file.FullName)
            if ($content -cmatch '(?m)(?:^|\s)az(?:\.cmd)?\s') {
                $violations += $file.FullName
            }
        }

        $violations | Should -BeNullOrEmpty
    }
}
