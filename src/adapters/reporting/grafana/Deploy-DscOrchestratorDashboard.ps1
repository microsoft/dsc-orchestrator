<#
.SYNOPSIS
    Deploys or updates the DSC Orchestrator compliance dashboard in Azure Managed Grafana.

.DESCRIPTION
    Loads the checked-in dashboard JSON, applies the caller-supplied workspace resource ID,
    dashboard UID, and title, then creates or updates the dashboard in Azure Managed Grafana.

.PARAMETER GrafanaEndpoint
    HTTPS endpoint of the Azure Managed Grafana instance.

.PARAMETER LaWorkspaceResourceId
    Full ARM resource ID of the Log Analytics workspace used by the dashboard.

.PARAMETER SubscriptionId
    Azure subscription passed to each Azure CLI command used by this deployment.

.PARAMETER DashboardUid
    Dashboard UID. Defaults to dsc-orchestrator-compliance.

.PARAMETER DashboardTitle
    Dashboard title. Defaults to DSC Orchestrator Compliance.

.PARAMETER DashboardFolderTitle
    Grafana folder title or UID. Defaults to DSC Orchestrator.

.PARAMETER GrafanaDatasourceUid
    Grafana datasource UID checked during preflight. Defaults to azure-monitor-oob.

.PARAMETER DashboardJsonPath
    Optional override path to the dashboard JSON. Defaults to the sibling dashboard artifact.

.EXAMPLE
    .\Deploy-DscOrchestratorDashboard.ps1 `
        -GrafanaEndpoint '<grafana-endpoint>' `
        -LaWorkspaceResourceId '<workspace-resource-id>' `
        -SubscriptionId '<subscription-id>' `
        -DashboardUid '<dashboard-uid>' `
        -DashboardTitle '<dashboard-title>' `
        -DashboardFolderTitle '<folder-title>'
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Azure DevOps recognizes task.setvariable commands only when written to the host stream.')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$GrafanaEndpoint,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [ValidatePattern('^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.OperationalInsights/workspaces/[a-zA-Z0-9._-]+\z')]
    [string]$LaWorkspaceResourceId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$SubscriptionId,

    [Parameter()]
    [ValidatePattern('(?-i)^[a-z0-9-]+\z')]
    [string]$DashboardUid = 'dsc-orchestrator-compliance',

    [Parameter()]
    [string]$DashboardTitle = 'DSC Orchestrator Compliance',

    [Parameter()]
    [string]$DashboardFolderTitle = 'DSC Orchestrator',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$GrafanaDatasourceUid = 'azure-monitor-oob',

    [Parameter()]
    [string]$DashboardJsonPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:GrafanaAudience = 'ce34e7e5-485f-4d76-964f-b3d2b16d1e4f'
$script:SubscriptionId = $SubscriptionId

$script:LogPrefix = '[Deploy-DscOrchestratorDashboard]'
$deployMessage = 'Deployed via Deploy-DscOrchestratorDashboard.ps1'

function Write-DeployLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Message
    )

    Write-Information "$script:LogPrefix $Message" -InformationAction Continue
}

function Invoke-AzCli {
    <#
    .SYNOPSIS
        Runs Azure CLI with stderr capture and consistent failure handling.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Arguments
    )

    $azCommand = Get-Command 'az' -ErrorAction SilentlyContinue
    if (-not $azCommand) {
        throw 'Azure CLI required. Install from https://aka.ms/azcli.'
    }

    $argumentsWithSubscription = @($Arguments)
    if ($argumentsWithSubscription -notcontains '--subscription') {
        $argumentsWithSubscription += @('--subscription', $script:SubscriptionId)
    }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $azCommand.Source
    foreach ($argument in $argumentsWithSubscription) {
        [void]$psi.ArgumentList.Add($argument)
    }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::Start($psi)
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()

    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()

    if ($process.ExitCode -ne 0) {
        $commandText = 'az {0}' -f ($argumentsWithSubscription -join ' ')
        if ([string]::IsNullOrWhiteSpace($stderr)) {
            $stderr = $stdout
        }
        throw "az CLI failed (exit $($process.ExitCode)) running [$commandText]: $stderr"
    }

    if ([string]::IsNullOrWhiteSpace($stdout)) {
        return $null
    }

    return $stdout
}

function Get-RequiredProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$InputObject,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if (-not $property) {
        throw "Required property '$Name' was not found."
    }

    return $property.Value
}

function Set-ObjectProperty {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)]
        [psobject]$InputObject,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter()]
        [AllowNull()]
        [object]$Value
    )

    if ($PSCmdlet.ShouldProcess("dashboard object property '$Name'", 'Update value')) {
        $property = $InputObject.PSObject.Properties[$Name]
        if ($property) {
            $property.Value = $Value
        } else {
            $InputObject | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
        }
    }
}

function Test-GrafanaEndpointReachable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Endpoint
    )

    $healthUri = '{0}/api/health' -f $Endpoint.TrimEnd('/')
    $lastError = $null

    foreach ($attempt in 1..2) {
        try {
            Invoke-WebRequest -Method Get -Uri $healthUri -TimeoutSec 15 -UseBasicParsing | Out-Null
            return
        } catch {
            if ($_.Exception.Response) {
                return
            }

            $lastError = $_
            if ($attempt -lt 2) {
                Start-Sleep -Seconds 2
            }
        }
    }

    throw "Grafana endpoint unreachable after 1 retry: $Endpoint. Underlying error: $($lastError.Exception.Message)"
}

function Get-GrafanaAccessToken {
    [CmdletBinding()]
    param()

    $resourcesToTry = @($script:GrafanaAudience)
    $lastError = $null

    foreach ($resource in $resourcesToTry) {
        try {
            $token = Invoke-AzCli -Arguments @(
                'account', 'get-access-token',
                '--resource', $resource,
                '--query', 'accessToken',
                '-o', 'tsv'
            )

            if (-not [string]::IsNullOrWhiteSpace($token)) {
                return $token.Trim()
            }
        } catch {
            $lastError = $_
        }
    }

    if ($lastError) {
        throw $lastError
    }

    throw 'Azure CLI returned an empty Grafana access token.'
}

function Invoke-GrafanaRest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('GET', 'POST')]
        [string]$Method,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Uri,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Token,

        [Parameter()]
        [AllowNull()]
        [object]$Body
    )

    $headers = @{ Authorization = "Bearer $Token" }
    $parameters = @{
        Method      = $Method
        Uri         = $Uri
        Headers     = $headers
        ErrorAction = 'Stop'
    }

    if ($null -ne $Body) {
        $parameters['ContentType'] = 'application/json'
        $parameters['Body'] = $Body | ConvertTo-Json -Depth 100
    }

    return Invoke-RestMethod @parameters
}

function Test-LaWorkspaceReachable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$WorkspaceResourceId
    )

    try {
        Invoke-AzCli -Arguments @('resource', 'show', '--ids', $WorkspaceResourceId, '-o', 'none') | Out-Null
    } catch {
        Write-Warning "LA workspace unreachable or not found: $WorkspaceResourceId. Deployment will continue; dashboard queries may fail at view time. Underlying error: $($_.Exception.Message)"
    }
}

function Test-GrafanaDatasource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Endpoint,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Token,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$DatasourceUid
    )

    try {
        $datasourceUri = '{0}/api/datasources/uid/{1}' -f $Endpoint.TrimEnd('/'), [System.Uri]::EscapeDataString($DatasourceUid)
        Invoke-GrafanaRest -Method 'GET' -Uri $datasourceUri -Token $Token | Out-Null
    } catch {
        $statusCode = $null
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }

        if ($statusCode -eq 404) {
            Write-Warning "Datasource '$DatasourceUid' not found. Managed Grafana may auto-provision it on first use; deployment will continue."
        } else {
            Write-Warning "Could not verify datasource '$DatasourceUid'. Deployment will continue. Underlying error: $($_.Exception.Message)"
        }
    }
}

function ConvertTo-GrafanaFolderList {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Response
    )

    if ($null -eq $Response) {
        return
    }

    if ($Response.PSObject.Properties['value']) {
        $Response = $Response.value
    }

    while ($Response -is [System.Array] -and $Response.Count -eq 1 -and $Response[0] -is [System.Array]) {
        $Response = $Response[0]
    }

    return @($Response)
}

function Get-OrCreateGrafanaFolderUid {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Endpoint,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Token,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$FolderTitle
    )

    $foldersUri = '{0}/api/folders' -f $Endpoint.TrimEnd('/')
    $folderResponse = Invoke-GrafanaRest -Method 'GET' -Uri $foldersUri -Token $Token
    $folders = @(ConvertTo-GrafanaFolderList -Response $folderResponse)
    $existing = $folders | Where-Object { $_.title -eq $FolderTitle -or $_.uid -eq $FolderTitle } | Select-Object -First 1
    if ($existing) {
        return [string]$existing.uid
    }

    try {
        $created = Invoke-GrafanaRest -Method 'POST' -Uri $foldersUri -Token $Token -Body @{ title = $FolderTitle }
        return [string]$created.uid
    } catch {
        $folderResponse = Invoke-GrafanaRest -Method 'GET' -Uri $foldersUri -Token $Token
        $folders = @(ConvertTo-GrafanaFolderList -Response $folderResponse)
        $existing = $folders | Where-Object { $_.title -eq $FolderTitle -or $_.uid -eq $FolderTitle } | Select-Object -First 1
        if ($existing) {
            return [string]$existing.uid
        }
        throw
    }
}

function Resolve-GrafanaAzureResource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Endpoint
    )

    $endpointHost = ([System.Uri]$Endpoint).Host
    $grafanaJson = Invoke-AzCli -Arguments @('grafana', 'list', '-o', 'json', '--only-show-errors')
    $grafanaItems = @($grafanaJson | ConvertFrom-Json)
    $match = $grafanaItems |
        Where-Object {
            $itemEndpoint = [string](Get-RequiredProperty -InputObject (Get-RequiredProperty -InputObject $_ -Name 'properties') -Name 'endpoint')
            $itemHost = $itemEndpoint -replace '^https?://', ''
            $itemHost = $itemHost.TrimEnd('/')
            $itemHost -ieq $endpointHost
        } |
        Select-Object -First 1

    if (-not $match) {
        throw "Could not resolve Azure Managed Grafana resource for endpoint '$Endpoint'."
    }

    $resourceGroup = $null
    if ($match.PSObject.Properties['resourceGroup']) {
        $resourceGroup = [string]$match.resourceGroup
    } elseif ($match.PSObject.Properties['id'] -and [string]$match.id -match '/resourceGroups/([^/]+)/') {
        $resourceGroup = $Matches[1]
    }

    if ([string]::IsNullOrWhiteSpace($resourceGroup)) {
        throw "Could not resolve resource group for Azure Managed Grafana endpoint '$Endpoint'."
    }

    return [pscustomobject]@{
        Name          = [string]$match.name
        ResourceGroup = $resourceGroup
    }
}

function Test-AzGrafanaDashboardCreateAvailable {
    [CmdletBinding()]
    param()

    try {
        Invoke-AzCli -Arguments @('grafana', 'dashboard', 'create', '--help') | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Save-DashboardPayloadFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory)]
        [psobject]$Dashboard,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Message
    )

    $payload = [ordered]@{
        dashboard = $Dashboard
        message   = $Message
    }

    $payload | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $Path -Encoding utf8
}

function New-GrafanaFolderWithAzGrafana {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$GrafanaName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ResourceGroup,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$FolderTitle
    )

    try {
        Invoke-AzCli -Arguments @(
            'grafana', 'folder', 'show',
            '--resource-group', $ResourceGroup,
            '--name', $GrafanaName,
            '--folder', $FolderTitle,
            '-o', 'none',
            '--only-show-errors'
        ) | Out-Null
        return
    } catch {
        try {
            if ($PSCmdlet.ShouldProcess("$ResourceGroup/$GrafanaName/$FolderTitle", 'Create Grafana folder')) {
                Invoke-AzCli -Arguments @(
                    'grafana', 'folder', 'create',
                    '--resource-group', $ResourceGroup,
                    '--name', $GrafanaName,
                    '--title', $FolderTitle,
                    '-o', 'none',
                    '--only-show-errors'
                ) | Out-Null
            }
        } catch {
            Invoke-AzCli -Arguments @(
                'grafana', 'folder', 'show',
                '--resource-group', $ResourceGroup,
                '--name', $GrafanaName,
                '--folder', $FolderTitle,
                '-o', 'none',
                '--only-show-errors'
            ) | Out-Null
        }
    }
}

function Invoke-GrafanaDashboardWithAzCli {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Endpoint,

        [Parameter(Mandatory)]
        [psobject]$Dashboard,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Title,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$FolderTitle,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Message,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$WorkingDirectory
    )

    $resource = Resolve-GrafanaAzureResource -Endpoint $Endpoint
    New-GrafanaFolderWithAzGrafana -GrafanaName $resource.Name -ResourceGroup $resource.ResourceGroup -FolderTitle $FolderTitle
    $payloadPath = Join-Path $WorkingDirectory '.Deploy-DscOrchestratorDashboard.payload.json'

    try {
        Save-DashboardPayloadFile -Path $payloadPath -Dashboard $Dashboard -Message $Message
        Invoke-AzCli -Arguments @(
            'grafana', 'dashboard', 'create',
            '--resource-group', $resource.ResourceGroup,
            '--name', $resource.Name,
            '--title', $Title,
            '--folder', $FolderTitle,
            '--definition', $payloadPath,
            '--overwrite', 'true',
            '-o', 'none',
            '--only-show-errors'
        ) | Out-Null
    } finally {
        if (Test-Path -LiteralPath $payloadPath) {
            Remove-Item -LiteralPath $payloadPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-GrafanaDashboardWithRest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Endpoint,

        [Parameter(Mandatory)]
        [psobject]$Dashboard,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$FolderTitle,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Token,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Message
    )

    $folderUid = Get-OrCreateGrafanaFolderUid -Endpoint $Endpoint -Token $Token -FolderTitle $FolderTitle
    $body = [ordered]@{
        overwrite = $true
        dashboard = $Dashboard
        folderUid = $folderUid
        message   = $Message
    }

    Invoke-GrafanaRest -Method 'POST' -Uri ('{0}/api/dashboards/db' -f $Endpoint.TrimEnd('/')) -Token $Token -Body $body | Out-Null
}

# ---------------- Main ----------------

if (-not (Get-Command 'az' -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI required. Install from https://aka.ms/azcli.'
}

$grafanaEndpointNormalized = $GrafanaEndpoint.TrimEnd('/')
if (-not $DashboardJsonPath) {
    $DashboardJsonPath = Join-Path $PSScriptRoot 'dsc-orchestrator-compliance-dashboard.json'
}

Write-DeployLog "Using subscription scope $SubscriptionId for Azure CLI operations."

Write-DeployLog "Checking Grafana endpoint reachability: $grafanaEndpointNormalized"
Test-GrafanaEndpointReachable -Endpoint $grafanaEndpointNormalized

Write-DeployLog "Checking Log Analytics workspace visibility."
Test-LaWorkspaceReachable -WorkspaceResourceId $LaWorkspaceResourceId

if (-not (Test-Path -LiteralPath $DashboardJsonPath)) {
    throw "Dashboard JSON not found: $DashboardJsonPath"
}

$resolvedDashboardJsonPath = (Resolve-Path -LiteralPath $DashboardJsonPath).Path
Write-DeployLog "Loading dashboard JSON: $resolvedDashboardJsonPath"
$dashboardRoot = Get-Content -LiteralPath $resolvedDashboardJsonPath -Raw | ConvertFrom-Json -Depth 100
$dashboard = if ($dashboardRoot.PSObject.Properties['dashboard']) { $dashboardRoot.dashboard } else { $dashboardRoot }

Set-ObjectProperty -InputObject $dashboard -Name 'uid' -Value $DashboardUid
Set-ObjectProperty -InputObject $dashboard -Name 'title' -Value $DashboardTitle

$templating = Get-RequiredProperty -InputObject $dashboard -Name 'templating'
$templateList = @(Get-RequiredProperty -InputObject $templating -Name 'list')
$laVariable = $templateList | Where-Object { $_.name -eq 'la_resource_id' } | Select-Object -First 1
if (-not $laVariable) {
    throw "Dashboard template variable 'la_resource_id' was not found in $resolvedDashboardJsonPath."
}

Set-ObjectProperty -InputObject $laVariable -Name 'query' -Value $LaWorkspaceResourceId
$current = if ($laVariable.PSObject.Properties['current']) { $laVariable.current } else { [pscustomobject]@{} }
Set-ObjectProperty -InputObject $current -Name 'value' -Value $LaWorkspaceResourceId
if (-not $laVariable.PSObject.Properties['current']) {
    Set-ObjectProperty -InputObject $laVariable -Name 'current' -Value $current
}

$grafanaToken = $null
try {
    $grafanaToken = Get-GrafanaAccessToken
    Test-GrafanaDatasource -Endpoint $grafanaEndpointNormalized -Token $grafanaToken -DatasourceUid $GrafanaDatasourceUid
} catch {
    Write-Warning "Could not acquire Grafana REST token for preflight checks. CLI deploy may still succeed. Underlying error: $($_.Exception.Message)"
}

$usedAzGrafana = $false
if (Test-AzGrafanaDashboardCreateAvailable) {
    try {
        Write-DeployLog 'Deploying dashboard via az grafana dashboard create.'
        Invoke-GrafanaDashboardWithAzCli `
            -Endpoint $grafanaEndpointNormalized `
            -Dashboard $dashboard `
            -Title $DashboardTitle `
            -FolderTitle $DashboardFolderTitle `
            -Message $deployMessage `
            -WorkingDirectory (Split-Path -Parent $resolvedDashboardJsonPath)
        $usedAzGrafana = $true
    } catch {
        Write-Warning "az grafana dashboard create path failed; falling back to raw Grafana REST. Underlying error: $($_.Exception.Message)"
    }
} else {
    Write-DeployLog 'az grafana dashboard create unavailable; using raw Grafana REST fallback.'
}

if (-not $usedAzGrafana) {
    if ([string]::IsNullOrWhiteSpace($grafanaToken)) {
        $grafanaToken = Get-GrafanaAccessToken
    }

    Write-DeployLog 'Deploying dashboard via raw Grafana REST.'
    Invoke-GrafanaDashboardWithRest `
        -Endpoint $grafanaEndpointNormalized `
        -Dashboard $dashboard `
        -FolderTitle $DashboardFolderTitle `
        -Token $grafanaToken `
        -Message $deployMessage
}

$dashboardUrl = "$grafanaEndpointNormalized/d/$DashboardUid/$($DashboardTitle.ToLower().Replace(' ', '-'))"
if ($env:TF_BUILD -eq 'True') {
    Write-Host "##vso[task.setvariable variable=dashboardUrl;isOutput=true]$dashboardUrl"
}
Write-DeployLog "Dashboard deployed: $dashboardUrl"
Write-Output $dashboardUrl
