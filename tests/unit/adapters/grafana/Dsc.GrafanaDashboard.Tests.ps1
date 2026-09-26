#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..'))
    $script:DashboardPath = Join-Path $script:RepoRoot 'src\adapters\reporting\grafana\dsc-orchestrator-compliance-dashboard.json'
    $script:DeployScriptPath = Join-Path $script:RepoRoot 'src\adapters\reporting\grafana\Deploy-DscOrchestratorDashboard.ps1'
    $script:DashboardText = Get-Content -LiteralPath $script:DashboardPath -Raw
    $script:DeployScriptText = Get-Content -LiteralPath $script:DeployScriptPath -Raw

    function Get-DashboardPanels {
        param(
            [Parameter(Mandatory)]
            [object[]]$Panels
        )

        foreach ($panel in $Panels) {
            $panel
            if ($panel.panels) {
                Get-DashboardPanels -Panels @($panel.panels)
            }
        }
    }

    function Get-JsonStringValues {
        param(
            [Parameter()]
            [AllowNull()]
            [object]$Value
        )

        if ($null -eq $Value) {
            return
        }

        if ($Value -is [string]) {
            $Value
            return
        }

        if ($Value -is [System.Collections.IDictionary]) {
            foreach ($entry in $Value.Values) {
                Get-JsonStringValues -Value $entry
            }
            return
        }

        if ($Value -is [System.Collections.IEnumerable]) {
            foreach ($entry in $Value) {
                Get-JsonStringValues -Value $entry
            }
            return
        }

        foreach ($property in $Value.PSObject.Properties) {
            Get-JsonStringValues -Value $property.Value
        }
    }

    function Get-ModuleLogPanelLocations {
        param(
            [Parameter(Mandatory)]
            [object[]]$Panels,

            [Parameter()]
            [bool]$InsideOptionalModuleLogRow = $false
        )

        foreach ($panel in $Panels) {
            $inOptionalModuleLogRow = $InsideOptionalModuleLogRow -or
                ($panel.type -eq 'row' -and $panel.title -eq 'Module logs (optional)')
            $targetText = @(Get-JsonStringValues -Value @($panel.targets)) -join "`n"

            if ($panel.type -ne 'row' -and $targetText -match 'DscOrchestrator_ModuleLogs_CL') {
                [pscustomobject]@{
                    Title                = $panel.title
                    InOptionalModuleRow  = $InsideOptionalModuleLogRow
                }
            }

            if ($panel.panels) {
                Get-ModuleLogPanelLocations `
                    -Panels @($panel.panels) `
                    -InsideOptionalModuleLogRow $inOptionalModuleLogRow
            }
        }
    }
}

Describe 'DSC Orchestrator Grafana dashboard' {
    It 'parses as strict JSON' {
        if ($PSVersionTable.PSEdition -eq 'Core') {
            $document = [System.Text.Json.JsonDocument]::Parse($script:DashboardText)
            $document.Dispose()
        }
        else {
            $pwsh = Get-Command -Name pwsh -ErrorAction Stop
            $quotedPath = "'" + $script:DashboardPath.Replace("'", "''") + "'"
            $command = "`$json = [System.IO.File]::ReadAllText($quotedPath); `$document = [System.Text.Json.JsonDocument]::Parse(`$json); `$document.Dispose()"
            $output = & $pwsh.Source -NoLogo -NoProfile -NonInteractive -Command $command 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Strict JSON parsing failed in PowerShell 7: $($output -join ' ')"
            }
        }
    }

    It 'contains no legacy identifiers' {
        $forbiddenTerms = @(
            'Dsc' + 'Fleet',
            'DSC' + 'v3' + '_',
            'host' + '_' + 'pool',
            'service' + '_' + 'type',
            'desktop' + 'virtualization'
        )
        $dashboardText = $script:DashboardText.ToLowerInvariant()

        foreach ($term in $forbiddenTerms) {
            $dashboardText | Should -Not -Match ([regex]::Escape($term.ToLowerInvariant()))
        }
    }

    It 'references only the four reporting contract tables' {
        $dashboard = $script:DashboardText | ConvertFrom-Json
        $allText = @(Get-JsonStringValues -Value $dashboard) -join "`n"
        $tableNames = @(
            [regex]::Matches($allText, '\b[A-Za-z][A-Za-z0-9_]*_CL\b') |
                ForEach-Object { $_.Value } |
                Sort-Object -Unique
        )
        $expectedTables = @(
            'DscOrchestrator_Bootstrap_CL',
            'DscOrchestrator_ModuleLogs_CL',
            'DscOrchestrator_Resources_CL',
            'DscOrchestrator_Runs_CL'
        )

        ($tableNames -join ',') | Should -Be ($expectedTables -join ',')
    }

    It 'retains the recorded visualization panel count and collapses optional module logs' {
        $dashboard = $script:DashboardText | ConvertFrom-Json
        $panels = @(Get-DashboardPanels -Panels @($dashboard.panels))
        $visualPanels = @($panels | Where-Object { $_.type -ne 'row' })
        $rows = @($panels | Where-Object { $_.type -eq 'row' })
        $moduleRow = $rows | Where-Object { $_.title -eq 'Module logs (optional)' }

        $visualPanels | Should -HaveCount 32
        $moduleRow | Should -Not -BeNullOrEmpty
        $moduleRow.collapsed | Should -BeTrue
        $moduleRow.panels | Should -HaveCount 2
        $moduleRow.panels[0].description | Should -Match 'requires module log collection to be enabled'
        $moduleRow.panels[1].description | Should -Be $moduleRow.panels[0].description

        $firstPosition = $moduleRow.panels[0].gridPos
        $secondPosition = $moduleRow.panels[1].gridPos
        $horizontalOverlap = $firstPosition.x -lt ($secondPosition.x + $secondPosition.w) -and
            $secondPosition.x -lt ($firstPosition.x + $firstPosition.w)
        $verticalOverlap = $firstPosition.y -lt ($secondPosition.y + $secondPosition.h) -and
            $secondPosition.y -lt ($firstPosition.y + $firstPosition.h)
        ($horizontalOverlap -and $verticalOverlap) | Should -BeFalse
    }

    It 'keeps every module-log query inside the optional module row' {
        $dashboard = $script:DashboardText | ConvertFrom-Json
        $moduleLogPanels = @(Get-ModuleLogPanelLocations -Panels @($dashboard.panels))

        $moduleLogPanels | Should -HaveCount 2
        @($moduleLogPanels | Where-Object { -not $_.InOptionalModuleRow }) | Should -BeNullOrEmpty
        $moduleLogPanels.Title | Should -Contain 'Full Trace for Run ID (paste/click run_id above)'
    }

    It 'uses the approved token audience and contains no other hard-coded GUID' {
        $audience = 'ce34e7e5-485f-4d76-964f-b3d2b16d1e4f'
        $script:DeployScriptText | Should -Match ([regex]::Escape($audience))
        $script:DeployScriptText | Should -Match '\$resourcesToTry\s*=\s*@\(\$script:GrafanaAudience\)'

        $guidMatches = @([regex]::Matches($script:DeployScriptText, '(?i)\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b'))
        $guidMatches | Should -HaveCount 1
        $guidMatches[0].Value | Should -Be $audience
    }

    It 'normalizes folder responses after assigning the REST response' {
        $script:DeployScriptText | Should -Match 'function ConvertTo-GrafanaFolderList'
        $script:DeployScriptText | Should -Match '\$folderResponse\s*=\s*Invoke-GrafanaRest'
        $script:DeployScriptText | Should -Not -Match '@\(\s*Invoke-(?:GrafanaRest|RestMethod)'
    }

    It 'does not change the default Azure CLI subscription' {
        $script:DeployScriptText | Should -Not -Match '(?i)\baccount\s+set\b'
        $script:DeployScriptText | Should -Match '\$argumentsWithSubscription\s*\+=\s*@\(''--subscription'',\s*\$script:SubscriptionId\)'
    }

    It 'gates the Azure DevOps variable and prints the dashboard URL' {
        $script:DeployScriptText | Should -Match '\$env:TF_BUILD\s*-eq\s*''True'''
        $script:DeployScriptText | Should -Match 'Write-Host "##vso\[task\.setvariable variable=dashboardUrl;isOutput=true\]\$dashboardUrl"'
        $script:DeployScriptText | Should -Match 'Write-Output \$dashboardUrl'
    }
}
