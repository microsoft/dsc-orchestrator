<#
.SYNOPSIS
    Child-process harness that runs remove.ps1 with recording scheduled-task and ACL fakes.
.DESCRIPTION
    The real security and bootstrap modules are imported. Global fakes shadow the Windows
    cmdlets from both scripts and modules so the test never touches the live task store.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RemoveScript,
    [Parameter(Mandatory = $true)][string]$DscRoot,
    [Parameter(Mandatory = $true)][string]$CallLog,
    [Parameter(Mandatory = $true)][string]$StateFile,
    [switch]$TaskExists,
    [switch]$UnregisterFails
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:REMOVE_HARNESS_LOG = $CallLog
$env:REMOVE_HARNESS_STATE = $StateFile
$env:REMOVE_HARNESS_UNREGISTER_FAILS = if ($UnregisterFails) { '1' } else { '0' }

([ordered]@{
    exists  = [bool]$TaskExists
    enabled = [bool]$TaskExists
    state   = if ($TaskExists) { 'Running' } else { 'Ready' }
} | ConvertTo-Json -Compress) | Set-Content -LiteralPath $StateFile -Encoding UTF8

function global:Get-RemoveHarnessTaskState {
    Get-Content -LiteralPath $env:REMOVE_HARNESS_STATE -Raw | ConvertFrom-Json
}

function global:Set-RemoveHarnessTaskState {
    param([Parameter(Mandatory = $true)][hashtable]$Change)
    $state = Get-RemoveHarnessTaskState
    $updated = [ordered]@{
        exists  = [bool]$state.exists
        enabled = [bool]$state.enabled
        state   = [string]$state.state
    }
    foreach ($key in $Change.Keys) { $updated[$key] = $Change[$key] }
    ($updated | ConvertTo-Json -Compress) | Set-Content -LiteralPath $env:REMOVE_HARNESS_STATE -Encoding UTF8
}

function global:Write-RemoveHarnessCall {
    param([Parameter(Mandatory = $true)][string]$Name)
    Add-Content -LiteralPath $env:REMOVE_HARNESS_LOG -Value (@{ call = $Name } | ConvertTo-Json -Compress)
}

function New-RemoveHarnessDirectoryAcl {
    $acl = [System.Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $systemSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $administratorsSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $inheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    foreach ($sid in @($systemSid, $administratorsSid)) {
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            $sid,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        $acl.AddAccessRule($rule)
    }
    $acl.SetOwner($administratorsSid)
    return $acl
}

function global:Get-Acl {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$LiteralPath)
    New-RemoveHarnessDirectoryAcl
}

function global:Set-Acl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)][System.Security.AccessControl.ObjectSecurity]$AclObject
    )
}

function global:Get-ScheduledTask {
    [CmdletBinding()]
    param([string]$TaskName)
    $state = Get-RemoveHarnessTaskState
    if (-not $state.exists) { return $null }
    [pscustomobject]@{ TaskName = $TaskName; State = [string]$state.state }
}

function global:Disable-ScheduledTask {
    [CmdletBinding()]
    param([string]$TaskName)
    Write-RemoveHarnessCall -Name 'disable'
    Set-RemoveHarnessTaskState -Change @{ enabled = $false }
}

function global:Stop-ScheduledTask {
    [CmdletBinding()]
    param([string]$TaskName)
    Write-RemoveHarnessCall -Name 'stop'
    Set-RemoveHarnessTaskState -Change @{ state = 'Ready' }
}

function global:Unregister-ScheduledTask {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$TaskName)
    Write-RemoveHarnessCall -Name 'unregister'
    if ($env:REMOVE_HARNESS_UNREGISTER_FAILS -eq '1') {
        throw 'Injected scheduled-task removal failure.'
    }
    Set-RemoveHarnessTaskState -Change @{ exists = $false }
}

function global:Start-Sleep {
    [CmdletBinding()]
    param([int]$Seconds)
}

function global:Get-CimInstance {
    [CmdletBinding()]
    param([string]$ClassName)
    Write-RemoveHarnessCall -Name 'processscan'
    @()
}

$global:LASTEXITCODE = 0
& $RemoveScript -DscRoot $DscRoot -TaskName 'DscOrchestrator-Enforcement'
if ($?) {
    exit 0
}
$removeExitCode = if ($LASTEXITCODE -gt 0) { $LASTEXITCODE } else { 1 }
exit $removeExitCode
