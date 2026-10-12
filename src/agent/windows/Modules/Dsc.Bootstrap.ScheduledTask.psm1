# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

# Dsc.Bootstrap.ScheduledTask — Orchestrator enforcement scheduled-task quiesce/wait.
# Phase D extraction from bootstrap.ps1.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Stop-DscEnforcementProcess {
    <#
    .SYNOPSIS
        Terminates any DSCv3 enforcement process running from the DSC root so the runtime binaries
        are unlocked before a runtime swap.
    .DESCRIPTION
        Stop-ScheduledTask ends only the task's action process, not the Start-Process dsc.exe
        grandchild that keeps the runtime locked. This stops dsc.exe and the enforcement PowerShell
        hosts under the DSC root, re-scanning until they exit. Never targets this process or the
        bootstrap. ProcessProvider/StopProcess are injectable seams for tests.
    .PARAMETER DscRoot
        DSC install root. Only processes running from it are stopped.
    .PARAMETER TimeoutSeconds
        Maximum seconds to wait for the stopped processes to disappear before failing.
    .PARAMETER ProcessProvider
        Returns the current process list (Win32_Process shape: ProcessId, Name, ExecutablePath,
        CommandLine). Inject a fixed list for tests.
    .PARAMETER StopProcess
        Invoked with a process id to terminate it. Inject a recorder for tests.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Bootstrap progress is captured by the installation transcript.')]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$DscRoot,

        [ValidateRange(1, 3600)]
        [int]$TimeoutSeconds = 120,

        [ValidateNotNull()]
        [scriptblock]$ProcessProvider = { Get-CimInstance -ClassName Win32_Process },

        [ValidateNotNull()]
        [scriptblock]$StopProcess = { param($ProcessId) Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue }
    )

    $selfId = $PID
    $rootPrefix = $DscRoot.TrimEnd('\') + '\'   # trailing '\' so 'DSCv3-old' can't match

    # dsc.exe running from the root, or an enforcement host whose command line references it -- but
    # never this process or the bootstrap.
    $isTarget = {
        param($Proc)
        $cmd = [string]$Proc.CommandLine
        $exe = [string]$Proc.ExecutablePath
        if ($Proc.ProcessId -eq $selfId -or $cmd -like '*bootstrap.ps1*') { return $false }
        ($Proc.Name -eq 'dsc.exe' -and $exe -like "$rootPrefix*") -or
        ($cmd -like "*$rootPrefix*" -and ($cmd -like '*Run-Enforcement.ps1*' -or $cmd -like '*Invoke-Enforcement.ps1*'))
    }

    # Re-scan each pass: killing a host can leave a just-spawned dsc.exe behind.
    $waited = 0
    $killedAny = $false
    while ($true) {
        $targets = @(& $ProcessProvider | Where-Object { & $isTarget $_ })
        if ($targets.Count -eq 0) {
            if ($killedAny) { Write-Host "  Enforcement processes stopped after ${waited}s." -ForegroundColor Green }
            return
        }
        if ($waited -ge $TimeoutSeconds) {
            throw "Enforcement processes under '$DscRoot' still running after ${TimeoutSeconds}s."
        }
        foreach ($proc in $targets) {
            if (-not $PSCmdlet.ShouldProcess(
                    "$($proc.Name) process $($proc.ProcessId) under '$DscRoot'",
                    'Stop enforcement process')) {
                return
            }
            Write-Host "  Stopping enforcement process $($proc.ProcessId) ($($proc.Name))." -ForegroundColor Yellow
            & $StopProcess $proc.ProcessId
        }
        $killedAny = $true
        Start-Sleep -Seconds 2
        $waited += 2
    }
}

function Wait-ForEnforcementTaskQuiet {
    <#
    .SYNOPSIS
        Disables the enforcement scheduled task, waits for any in-flight run to finish, then ensures
        no enforcement process is left holding the runtime.
    .DESCRIPTION
        Waits up to TimeoutSeconds for a running task to finish, else force-stops it. Stop-ScheduledTask
        does not reap the Start-Process dsc.exe grandchild, so Stop-DscEnforcementProcess is then called
        to guarantee nothing is left locking the runtime. Safe when no task is registered.
    .PARAMETER TaskName
        Enforcement scheduled-task name.
    .PARAMETER TimeoutSeconds
        Maximum seconds to wait for a running task to finish before force-stopping it.
    .PARAMETER DscRoot
        DSC install root, forwarded to Stop-DscEnforcementProcess.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Bootstrap progress is captured by the installation transcript.')]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$TaskName,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 86400)]
        [int]$TimeoutSeconds,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$DscRoot
    )

    $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        Disable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null
        Write-Host "  Task disabled." -ForegroundColor Green

        if ($existingTask.State -eq 'Running') {
            Write-Host "  Task is running - waiting up to $TimeoutSeconds seconds..." -ForegroundColor Yellow
            $waited = 0
            $pollInterval = 10
            while ($waited -lt $TimeoutSeconds) {
                Start-Sleep -Seconds $pollInterval
                $waited += $pollInterval
                $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
                if (-not $existingTask -or $existingTask.State -ne 'Running') {
                    Write-Host "  Task finished after ${waited}s." -ForegroundColor Green
                    break
                }
                Write-Host "  Still running (${waited}s / ${TimeoutSeconds}s)..." -ForegroundColor Gray
            }
            if ($existingTask -and $existingTask.State -eq 'Running') {
                Write-Host "  Task still running after timeout - force-stopping." -ForegroundColor Yellow
                Stop-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null
            }
        }
        else {
            Write-Host "  No running task instance detected." -ForegroundColor Green
        }
    }
    else {
        Write-Host "  No existing task found." -ForegroundColor Gray
    }

    # Stop-ScheduledTask leaves the dsc.exe grandchild; kill the tree so the runtime is unlocked.
    Stop-DscEnforcementProcess -DscRoot $DscRoot
}

Export-ModuleMember -Function Stop-DscEnforcementProcess, Wait-ForEnforcementTaskQuiet
