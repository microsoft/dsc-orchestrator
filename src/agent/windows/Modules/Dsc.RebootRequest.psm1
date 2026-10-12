# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Request-DscReboot {
    <#
    .SYNOPSIS
        Records a reboot request for the current Orchestrator enforcement run.
    .DESCRIPTION
        Reads the live enforcement context, then writes one requester-owned
        registry subkey. Complete is cleared before updates and committed last
        so the agent never consumes a partially written request.
    .PARAMETER Kind
        Immediate reboots after the current fragment; Eventual reboots after
        all reachable fragments finish.
    .PARAMETER RequestedBy
        Stable resource or module identifier used as the request subkey name.
    .PARAMETER RegistryRoot
        Reboot registry root. Must match the root supplied to the agent.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Immediate', 'Eventual')]
        [string]$Kind,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')]
        [string]$RequestedBy,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$RegistryRoot = $(
            if ([string]::IsNullOrWhiteSpace($env:DSC_ORCHESTRATOR_REBOOT_REGISTRY_ROOT)) {
                'HKLM:\SOFTWARE\DscOrchestrator\Reboot'
            }
            else {
                $env:DSC_ORCHESTRATOR_REBOOT_REGISTRY_ROOT
            }
        )
    )

    $contextKey = Join-Path $RegistryRoot 'Context'
    $enforcementId = ''
    $configVersion = ''
    $runId = ''
    if (Test-Path -LiteralPath $contextKey) {
        $context = Get-ItemProperty -LiteralPath $contextKey -ErrorAction Stop
        if ($context.PSObject.Properties.Name -contains 'EnforcementId') {
            $enforcementId = [string]$context.EnforcementId
        }
        if ($context.PSObject.Properties.Name -contains 'ConfigVersion') {
            $configVersion = [string]$context.ConfigVersion
        }
        if ($context.PSObject.Properties.Name -contains 'RunId') {
            $runId = [string]$context.RunId
        }
    }

    $requestsRoot = Join-Path $RegistryRoot 'Requests'
    if (-not (Test-Path -LiteralPath $requestsRoot)) {
        New-Item -Path $requestsRoot -Force -ErrorAction Stop | Out-Null
    }
    $requestKey = Join-Path $requestsRoot $RequestedBy
    if (-not (Test-Path -LiteralPath $requestKey)) {
        New-Item -Path $requestKey -Force -ErrorAction Stop | Out-Null
    }

    Set-ItemProperty -LiteralPath $requestKey -Name 'Complete' -Value 0 -Type DWord -Force -ErrorAction Stop
    $requestedAt = [DateTime]::UtcNow.ToString('o')
    Set-ItemProperty -LiteralPath $requestKey -Name 'Kind' -Value $Kind -Type String -Force -ErrorAction Stop
    Set-ItemProperty -LiteralPath $requestKey -Name 'RequestedBy' -Value $RequestedBy -Type String -Force -ErrorAction Stop
    Set-ItemProperty -LiteralPath $requestKey -Name 'EnforcementId' -Value $enforcementId -Type String -Force -ErrorAction Stop
    Set-ItemProperty -LiteralPath $requestKey -Name 'ConfigVersion' -Value $configVersion -Type String -Force -ErrorAction Stop
    Set-ItemProperty -LiteralPath $requestKey -Name 'RunId' -Value $runId -Type String -Force -ErrorAction Stop
    Set-ItemProperty -LiteralPath $requestKey -Name 'RequestedAt' -Value $requestedAt -Type String -Force -ErrorAction Stop
    Set-ItemProperty -LiteralPath $requestKey -Name 'Complete' -Value 1 -Type DWord -Force -ErrorAction Stop

    [pscustomobject]@{
        Kind          = $Kind
        RequestedBy   = $RequestedBy
        EnforcementId = $enforcementId
        ConfigVersion = $configVersion
        RunId         = $runId
        RequestedAt   = $requestedAt
        RegistryPath  = $requestKey
    }
}

Export-ModuleMember -Function Request-DscReboot
