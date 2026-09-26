<#
.SYNOPSIS
    Child-process harness that runs the real bootstrap.ps1 against a fake package with the
    scheduled-task cmdlets replaced by an in-memory task, recording every call.
.DESCRIPTION
    bootstrap.ps1 is not injectable. PowerShell resolves functions before cmdlets and module scopes
    fall back to the global scope, so global functions defined here shadow the real cmdlets for
    bootstrap.ps1 AND for the Dsc.Bootstrap.* modules it imports -- one mechanism, both scopes, no
    real scheduled task and no administrator rights. State lives in environment variables and a JSON
    file rather than global variables (PSAvoidGlobalVars).

    Failure-injection seams, each a production failure observed in the field:
      swap     - Move-Item 'current.new' -> 'current' throws (Step 6, after 'current' was removed).
      register - Register-ScheduledTask throws (Step 9, last statement inside the disable window).
      start    - Start-ScheduledTask throws (Step 9, after registration closed the window).
      -EnableFails - the restore's Enable-ScheduledTask throws.

    Task-state semantics encoded in the fakes were verified against the live Task Scheduler.

    Exit codes: 0 = bootstrap returned; 3 = bootstrap threw (message written to ErrorFile).
.NOTES
    Not a Pester file and not discovered by Invoke-PesterTests.ps1.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PackageRoot,
    [Parameter(Mandatory = $true)][string]$DscRoot,
    [Parameter(Mandatory = $true)][string]$CallLog,
    [Parameter(Mandatory = $true)][string]$ErrorFile,
    [Parameter(Mandatory = $true)][string]$StateFile,
    [ValidateSet('none', 'swap', 'register', 'start')][string]$FailAt = 'none',
    [switch]$TaskExists,
    [switch]$TaskInitiallyDisabled,
    [switch]$EnableFails,
    [string]$Version = '1.0.0'
)

$ErrorActionPreference = 'Stop'

# Import first: module auto-loading later in the run would import the genuine cmdlets over the fakes
# and the harness would reach the live task store.
Import-Module ScheduledTasks -ErrorAction SilentlyContinue
Import-Module CimCmdlets     -ErrorAction SilentlyContinue

$env:HARNESS_LOG           = $CallLog
$env:HARNESS_STATE         = $StateFile
$env:HARNESS_FAIL_AT       = $FailAt
$env:HARNESS_ENABLE_FAILS  = if ($EnableFails) { '1' } else { '0' }
$env:HARNESS_ALLUSERS_ROOT = 'C:\Program Files\WindowsPowerShell\Modules'
$env:HARNESS_DSC_ROOT      = [System.IO.Path]::GetFullPath($DscRoot)

([ordered]@{
    exists  = [bool]$TaskExists
    enabled = -not [bool]$TaskInitiallyDisabled
    state   = if ($TaskInitiallyDisabled) { 'Disabled' } else { 'Ready' }
} | ConvertTo-Json -Compress) | Set-Content -LiteralPath $StateFile -Encoding UTF8

function global:New-HarnessDirectoryAcl {
    param([string[]]$Sids)

    $acl = [System.Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner([System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    foreach ($sidValue in $Sids) {
        $sid = [System.Security.Principal.SecurityIdentifier]::new($sidValue)
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            $sid,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
                [System.Security.AccessControl.InheritanceFlags]::ObjectInherit,
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        $acl.AddAccessRule($rule)
    }
    return $acl
}

function global:Get-Acl {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$LiteralPath)

    $fullPath = [System.IO.Path]::GetFullPath($LiteralPath)
    $parentPath = [System.IO.Directory]::GetParent($env:HARNESS_DSC_ROOT).FullName
    if ([string]::Equals($fullPath, $env:HARNESS_DSC_ROOT, [System.StringComparison]::OrdinalIgnoreCase)) {
        return New-HarnessDirectoryAcl -Sids @('S-1-5-18', 'S-1-5-32-544')
    }
    if ([string]::Equals($fullPath, $parentPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        return New-HarnessDirectoryAcl -Sids @(
            'S-1-5-18',
            'S-1-5-32-544',
            'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
        )
    }

    Microsoft.PowerShell.Security\Get-Acl -LiteralPath $LiteralPath -ErrorAction Stop
}

function global:Set-Acl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)][System.Security.AccessControl.ObjectSecurity]$AclObject
    )
}

function global:Get-HarnessTaskState {
    Get-Content -LiteralPath $env:HARNESS_STATE -Raw | ConvertFrom-Json
}

function global:Set-HarnessTaskState {
    param([Parameter(Mandatory = $true)][hashtable]$Change)
    $state = Get-HarnessTaskState
    $updated = [ordered]@{
        exists  = [bool]$state.exists
        enabled = [bool]$state.enabled
        state   = [string]$state.state
    }
    foreach ($key in $Change.Keys) { $updated[$key] = $Change[$key] }
    ($updated | ConvertTo-Json -Compress) | Set-Content -LiteralPath $env:HARNESS_STATE -Encoding UTF8
}

function global:Write-HarnessCall {
    param([Parameter(Mandatory = $true)][string]$Name, [hashtable]$Data = @{})
    $record = [ordered]@{ call = $Name }
    foreach ($key in $Data.Keys) { $record[$key] = $Data[$key] }
    Add-Content -LiteralPath $env:HARNESS_LOG -Value ($record | ConvertTo-Json -Compress -Depth 5)
}

# No harness run may write into or delete from the machine-wide AllUsers module root:
# bootstrap calls Sync-AllUsersModules without -TargetModulesPath, which defaults there.
function global:Assert-NotAllUsersPath {
    param([string]$Path, [string]$Action)
    if ($Path -and $Path.StartsWith($env:HARNESS_ALLUSERS_ROOT, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Harness guard: refused AllUsers module $Action at '$Path'."
    }
}

# --- scheduled-task fakes -------------------------------------------------------------------

function global:Get-ScheduledTask {
    [CmdletBinding()]
    param([string]$TaskName)
    $state = Get-HarnessTaskState
    if (-not $state.exists) { return $null }
    # Live shape (S1/S2): enabled-ness lives on the nested Settings object; State is 'Ready'/'Disabled'.
    [pscustomobject]@{
        TaskName = $TaskName
        State    = [string]$state.state
        Enabled  = [bool]$state.enabled
        Settings = [pscustomobject]@{ Enabled = [bool]$state.enabled }
    }
}

function global:Disable-ScheduledTask {
    [CmdletBinding()]
    param([string]$TaskName)
    Write-HarnessCall -Name 'disable' -Data @{ taskName = $TaskName }
    # Live semantics (S2/S3): disabling an already-disabled task succeeds.
    Set-HarnessTaskState -Change @{ enabled = $false; state = 'Disabled' }
}

function global:Enable-ScheduledTask {
    [CmdletBinding()]
    param([string]$TaskName)
    Write-HarnessCall -Name 'enable' -Data @{ taskName = $TaskName }
    if ($env:HARNESS_ENABLE_FAILS -eq '1') { throw 'Access is denied enabling the scheduled task (injected).' }
    # Live semantics (S6/S7): enabling an already-enabled task is a successful no-op.
    Set-HarnessTaskState -Change @{ enabled = $true; state = 'Ready' }
}

function global:Register-ScheduledTask {
    [CmdletBinding()]
    param(
        [string]$TaskName,
        $Action,
        $Trigger,
        $Principal,
        $Settings,
        [string]$Description,
        [switch]$Force
    )
    Write-HarnessCall -Name 'register' -Data @{
        taskName           = $TaskName
        execute            = [string]$Action.Execute
        arguments          = [string]$Action.Arguments
        force              = [bool]$Force
        description        = [string]$Description
        userId             = [string]$Principal.UserId
        logonType          = [string]$Principal.LogonType
        runLevel           = [string]$Principal.RunLevel
        repetitionInterval = [string]$Trigger.Repetition.Interval
        multipleInstances  = [string]$Settings.MultipleInstances
        executionTimeLimit = [string]$Settings.ExecutionTimeLimit
    }
    if ($env:HARNESS_FAIL_AT -eq 'register') {
        throw 'Access is denied registering the scheduled task (injected).'
    }
    # Live semantics (S4b/S10): -Force over a disabled task returns it enabled, because
    # New-ScheduledTaskSettingsSet defaults Enabled=$true and bootstrap never passes -Disable.
    Set-HarnessTaskState -Change @{ exists = $true; enabled = $true; state = 'Ready' }
}

function global:Unregister-ScheduledTask {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$TaskName)
    if ($PSCmdlet.ShouldProcess($TaskName, 'Unregister scheduled task')) {
        Write-HarnessCall -Name 'unregister' -Data @{ taskName = $TaskName }
        Set-HarnessTaskState -Change @{ exists = $false }
    }
}

function global:Start-ScheduledTask {
    [CmdletBinding()]
    param([string]$TaskName)
    Write-HarnessCall -Name 'start' -Data @{ taskName = $TaskName }
    if ($env:HARNESS_FAIL_AT -eq 'start') {
        throw 'The task could not be started (injected).'
    }
    Set-HarnessTaskState -Change @{ state = 'Running' }
}

function global:Stop-ScheduledTask {
    [CmdletBinding()]
    param([string]$TaskName)
    Write-HarnessCall -Name 'stop' -Data @{ taskName = $TaskName }
    Set-HarnessTaskState -Change @{ state = 'Ready' }
}

# --- failure-injection and safety seams -------------------------------------------------------

# Stops Stop-DscEnforcementProcess's default provider from enumerating and killing live processes.
function global:Get-CimInstance {
    [CmdletBinding()]
    param([string]$ClassName)
    Write-HarnessCall -Name 'processscan' -Data @{ className = $ClassName }
    @()
}

# Only Replace-CurrentContent moves anything, and only after 'current' has been removed.
function global:Move-Item {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string[]]$Path,
        [string[]]$LiteralPath,
        [Parameter(Position = 1)][string]$Destination,
        [switch]$Force
    )
    Write-HarnessCall -Name 'moveitem' -Data @{ destination = $Destination }
    if ($env:HARNESS_FAIL_AT -eq 'swap') {
        throw "Access to the path '$Destination' is denied (injected)."
    }
    $forward = @{ Destination = $Destination }
    if ($LiteralPath) { $forward.LiteralPath = $LiteralPath } else { $forward.Path = $Path }
    if ($Force) { $forward.Force = $true }
    Microsoft.PowerShell.Management\Move-Item @forward
}

function global:Remove-Item {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string[]]$Path,
        [string[]]$LiteralPath,
        [switch]$Recurse,
        [switch]$Force
    )
    $target = if ($LiteralPath) { [string]$LiteralPath[0] } elseif ($Path) { [string]$Path[0] } else { '' }
    Assert-NotAllUsersPath -Path $target -Action 'delete'
    $forward = @{}
    if ($LiteralPath) { $forward.LiteralPath = $LiteralPath } elseif ($Path) { $forward.Path = $Path }
    if ($Recurse) { $forward.Recurse = $true }
    if ($Force) { $forward.Force = $true }
    Microsoft.PowerShell.Management\Remove-Item @forward
}

function global:New-Item {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string]$Path,
        [string]$ItemType,
        $Value,
        [switch]$Force
    )
    Assert-NotAllUsersPath -Path $Path -Action 'root creation'
    $forward = @{ Path = $Path }
    if ($ItemType) { $forward.ItemType = $ItemType }
    if ($PSBoundParameters.ContainsKey('Value')) { $forward.Value = $Value }
    if ($Force) { $forward.Force = $true }
    Microsoft.PowerShell.Management\New-Item @forward
}

function global:Copy-Item {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string[]]$Path,
        [string[]]$LiteralPath,
        [Parameter(Position = 1)][string]$Destination,
        [switch]$Recurse,
        [switch]$Force
    )
    Assert-NotAllUsersPath -Path $Destination -Action 'write'
    $forward = @{ Destination = $Destination }
    if ($LiteralPath) { $forward.LiteralPath = $LiteralPath } else { $forward.Path = $Path }
    if ($Recurse) { $forward.Recurse = $true }
    if ($Force) { $forward.Force = $true }
    Microsoft.PowerShell.Management\Copy-Item @forward
}

# --- run ------------------------------------------------------------------------------------

$exitCode = 0
try {
    & (Join-Path $PackageRoot 'bootstrap.ps1') -Version $Version -Update -DscRoot $DscRoot
}
catch {
    Set-Content -LiteralPath $ErrorFile -Value $_.Exception.Message -NoNewline
    $exitCode = 3
}

exit $exitCode
