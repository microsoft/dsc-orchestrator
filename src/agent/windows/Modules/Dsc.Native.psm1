
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'


function Invoke-DscNative {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DscExePath,
        [Parameter(Mandatory)][ValidateSet('test','set','get')][string]$Subcommand,
        [Parameter(Mandatory)][string]$ConfigFilePath,
        [Parameter()][AllowNull()][scriptblock]$OnStderrLine = $null,
        [Parameter()][switch]$EnableDebugTrace
    )

    $stdoutFile = [IO.Path]::GetTempFileName()
    $stderrFile = [IO.Path]::GetTempFileName()
    $oldPath = $env:PATH
    $oldPSModulePath = $env:PSModulePath
    $oldTrace = if (Test-Path -LiteralPath 'Env:\DSC_TRACE_LEVEL') { $env:DSC_TRACE_LEVEL } else { $null }
    # StrictMode: streaming path assigns after process exit; fast path reads $proc.ExitCode.
    $exitCode = $null
    try {
        $dscDir  = Split-Path -Parent $DscExePath
        $pwshDir = Join-Path $dscDir 'pwsh'
        # The PowerShell adapter invokes 'pwsh' by name; keep bundled pwsh on PATH.
        $env:PATH = $dscDir + [IO.Path]::PathSeparator + $pwshDir + [IO.Path]::PathSeparator + $env:PATH

        # Bootstrap syncs package modules to WinPS AllUsers; leaving package modules on PSModulePath
        # makes PSDesiredStateConfiguration see duplicate PSModuleInfo rows and fail resource discovery.
        $modulesDir = Join-Path $dscDir 'modules'
        if ((Test-Path -LiteralPath $modulesDir -PathType Container) -and
            (-not [string]::IsNullOrWhiteSpace($env:PSModulePath))) {
            $modulesDirFull = [IO.Path]::GetFullPath($modulesDir).TrimEnd('\')
            $pathEntries = New-Object 'System.Collections.Generic.List[string]'
            foreach ($entry in @($env:PSModulePath -split [IO.Path]::PathSeparator)) {
                if ([string]::IsNullOrWhiteSpace($entry)) { continue }
                try {
                    $entryFull = [IO.Path]::GetFullPath($entry).TrimEnd('\')
                } catch {
                    Write-Verbose "Dsc.Native PSModulePath normalization skipped invalid entry '$entry': $($_.Exception.Message)"
                    $entryFull = $entry.TrimEnd('\')
                }
                if (-not [string]::Equals($entryFull, $modulesDirFull, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $pathEntries.Add($entry)
                }
            }
            $env:PSModulePath = $pathEntries -join [IO.Path]::PathSeparator
        }
        if ($EnableDebugTrace) { $env:DSC_TRACE_LEVEL = 'Debug' }
        $resourcePathState = if (Test-Path -LiteralPath 'Env:\DSC_RESOURCE_PATH') { "set='$($env:DSC_RESOURCE_PATH)'" } else { 'unset' }
        $psModPathHead = (($env:PSModulePath -split [IO.Path]::PathSeparator) | Select-Object -First 3) -join ';'
        Write-NativeStderr "[diag] dsc.exe spawn: DSC_RESOURCE_PATH=$resourcePathState; PATH head=$((($env:PATH -split [IO.Path]::PathSeparator) | Select-Object -First 6) -join ';'); PSModulePath head=$psModPathHead`n"

        if ($null -eq $OnStderrLine) {
            $dscArgs = @('config', $Subcommand, '--output-format', 'json', '--file', $ConfigFilePath)
            $proc = Start-Process -FilePath $DscExePath `
                -ArgumentList $dscArgs `
                -NoNewWindow -Wait -PassThru `
                -RedirectStandardOutput $stdoutFile `
                -RedirectStandardError  $stderrFile `
                -ErrorAction Stop

            $stdout = if (Test-Path -LiteralPath $stdoutFile) { [IO.File]::ReadAllText($stdoutFile) } else { '' }
            $stderr = if (Test-Path -LiteralPath $stderrFile) { [IO.File]::ReadAllText($stderrFile) } else { '' }
        } else {
            $dscArgs = @(
                '--trace-format', 'json',
                '--progress-format', 'json',
                'config', $Subcommand, '--output-format', 'json', '--file', $ConfigFilePath
            )
            # WinPS 5.1: Start-Process -PassThru can leave .ExitCode permanently $null.
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $DscExePath
            $psi.Arguments = ($dscArgs | ForEach-Object {
                if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
            }) -join ' '
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.CreateNoWindow = $true
            $stdoutWriter = New-Object System.IO.StreamWriter($stdoutFile, $false, ([System.Text.UTF8Encoding]::new($false)))
            $stderrWriter = New-Object System.IO.StreamWriter($stderrFile, $false, ([System.Text.UTF8Encoding]::new($false)))
            $stdoutWriter.AutoFlush = $true
            $stderrWriter.AutoFlush = $true

            $proc = New-Object System.Diagnostics.Process
            $proc.StartInfo = $psi

            $stdoutSub = Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -MessageData $stdoutWriter -Action {
                if ($null -ne $EventArgs.Data) { $Event.MessageData.WriteLine($EventArgs.Data) }
            }
            $stderrSub = Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -MessageData $stderrWriter -Action {
                if ($null -ne $EventArgs.Data) { $Event.MessageData.WriteLine($EventArgs.Data) }
            }

            try {
                [void]$proc.Start()
                $proc.BeginOutputReadLine()
                $proc.BeginErrorReadLine()

                $script:__dscStreamLastPos = 0L
                $emitNewLines = {
                    if (-not (Test-Path -LiteralPath $stderrFile)) { return }
                    try {
                        $fs = [System.IO.File]::Open(
                            $stderrFile, [System.IO.FileMode]::Open,
                            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                        try {
                            if ($script:__dscStreamLastPos -ge $fs.Length) { return }
                            $fs.Position = $script:__dscStreamLastPos
                            $reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $true, 4096, $true)
                            try {
                            while ($null -ne ($line = $reader.ReadLine())) {
                                    try { & $OnStderrLine $line }
                                    catch { Write-NativeStderr "[stderr-callback] threw: $($_.Exception.Message)`n" }
                                }
                                $script:__dscStreamLastPos = $fs.Position
                            } finally { $reader.Dispose() }
                        } finally { $fs.Dispose() }
                    } catch {
                        # Writer/read race; next poll resumes from $script:__dscStreamLastPos.
                        Write-Verbose "Dsc.Native stderr stream read swallowed: $($_.Exception.Message)"
                    }
                }.GetNewClosure()

                while (-not $proc.HasExited) {
                    & $emitNewLines
                    Start-Sleep -Milliseconds 250
                }
                [void]$proc.WaitForExit()
                & $emitNewLines

                $exitCode = $proc.ExitCode
            } finally {
                if ($stdoutSub) { Unregister-Event -SourceIdentifier $stdoutSub.Name -ErrorAction SilentlyContinue }
                if ($stderrSub) { Unregister-Event -SourceIdentifier $stderrSub.Name -ErrorAction SilentlyContinue }
                if ($stdoutWriter) { $stdoutWriter.Dispose() }
                if ($stderrWriter) { $stderrWriter.Dispose() }
                if ($proc) { $proc.Dispose() }
            }

            $stdout = if (Test-Path -LiteralPath $stdoutFile) { [IO.File]::ReadAllText($stdoutFile) } else { '' }
            $stderr = if (Test-Path -LiteralPath $stderrFile) { [IO.File]::ReadAllText($stderrFile) } else { '' }
        }

        if ($null -eq $exitCode) { $exitCode = $proc.ExitCode }

        return [pscustomobject]@{
            ExitCode = $exitCode
            Stdout   = $stdout
            Stderr   = $stderr
        }
    }
    finally {
        $env:PATH = $oldPath
        $env:PSModulePath = $oldPSModulePath
        if ($EnableDebugTrace) {
            if ($null -eq $oldTrace) { Remove-Item -LiteralPath 'Env:\DSC_TRACE_LEVEL' -Force -ErrorAction SilentlyContinue }
            else { $env:DSC_TRACE_LEVEL = $oldTrace }
        }
        Remove-Item -LiteralPath $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-DscTestJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DscExePath,
        [Parameter(Mandatory)][string]$ConfigFilePath
    )
    $timing = New-TimingCallback -ActivityVerb 'Test'
    $native = Invoke-DscNative -DscExePath $DscExePath -Subcommand 'test' -ConfigFilePath $ConfigFilePath `
        -OnStderrLine $timing.Callback
    $parsed = ConvertFrom-DscTestJson -Json $native.Stdout
    return [pscustomobject]@{
        Native  = $native
        Parsed  = $parsed
        Timings = $timing.Timings
    }
}

function Invoke-DscSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DscExePath,
        [Parameter(Mandatory)][string]$ConfigFilePath,
        [Parameter()][AllowNull()][string]$ResourcesLogPath = $null,
        [Parameter()][AllowNull()][string]$ResourcesSchemaVersion = $null,
        [Parameter()][AllowNull()][string]$RunId = $null,
        [Parameter()][AllowNull()][string]$HostName = $null,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Group = $null,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Role = $null,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$ConfigurationHash = $null,
        [Parameter()][AllowNull()][string]$ConfigVersion = $null,
        [Parameter()][AllowNull()][string]$RunTrigger = $null,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$FragmentName = '',
        # Drifted seeds (Get-DriftedTopLevelResourceNames) = the abort-signal denominator. Must be the
        # seeds only, never the forward-expanded set config, or a dependsOn-pulled compliant upstream
        # yields a false Unreached. Defaults empty -> Unreached empty / Aborted false.
        [Parameter()][AllowEmptyCollection()][string[]]$DriftedSeedNames = @(),
        # Buffer set-lifecycle rows (returned as BufferedRows) instead of streaming to the file, so the
        # loop can discard a stripped pass's rows and flush only the final set's. Default off = stream.
        [Parameter()][switch]$BufferRows
    )

    $bufferSink = if ($BufferRows) { [System.Collections.Generic.List[object]]::new() } else { $null }
    $callback = $null
    $lifecycle = $null
    $useStreaming = (-not [string]::IsNullOrEmpty($ResourcesLogPath)) -and `
                    (-not [string]::IsNullOrEmpty($ResourcesSchemaVersion)) -and `
                    (-not [string]::IsNullOrEmpty($RunId)) -and `
                    (-not [string]::IsNullOrEmpty($HostName)) -and `
                    (-not [string]::IsNullOrEmpty($ConfigVersion)) -and `
                    (-not [string]::IsNullOrEmpty($RunTrigger))

    if ($useStreaming) {
        # Map wrapper -> inner type so set rows align with test/verify; failure is non-fatal.
        $innerTypeMap = @{}
        try {
            $innerTypeMap = Get-WrapperInnerTypeMap -ConfigFilePath $ConfigFilePath
        } catch {
            Write-NativeStderr "[Invoke-DscSet] Get-WrapperInnerTypeMap failed: $($_.Exception.Message). Set-phase rows will report adapter wrapper type.`n"
        }

        $lifecycle = New-SetLifecycleCallback -Path $ResourcesLogPath -SchemaVersion $ResourcesSchemaVersion `
            -RunId $RunId -HostName $HostName -Group $Group -Role $Role `
            -ConfigVersion $ConfigVersion -ConfigurationHash $ConfigurationHash -RunTrigger $RunTrigger -FragmentName $FragmentName `
            -InnerTypeMap $innerTypeMap -BufferSink $bufferSink
        $callback = $lifecycle.Callback
    }

    $native = Invoke-DscNative -DscExePath $DscExePath -Subcommand 'set' -ConfigFilePath $ConfigFilePath `
        -OnStderrLine $callback

    if ($useStreaming -and $null -ne $lifecycle.State -and $lifecycle.State.InFlight.Count -gt 0) {
        # Synthetic set-end prevents orphan set-start rows; completionKind marks unresolved work.
        $signal = Find-DscErrorSignal -Stderr $native.Stderr -MaxChars 2000
        $syntheticErrorMsg = if (-not [string]::IsNullOrWhiteSpace($signal.Excerpt)) {
            $signal.Excerpt
        } else {
            "dsc.exe exited (exit=$($native.ExitCode))"
        }

        foreach ($name in @($lifecycle.State.InFlight.Keys)) {
            $entry = $lifecycle.State.InFlight[$name]
            $dur = if ($null -ne $entry.StartedAt) {
                $elapsed = (Get-Date).ToUniversalTime() - $entry.StartedAt
                [System.Xml.XmlConvert]::ToString($elapsed)
            } else { $null }
            $syntheticMsgCapped = if ($syntheticErrorMsg.Length -gt 1024) { $syntheticErrorMsg.Substring(0, 1024) } else { $syntheticErrorMsg }
            $lifecycle.State.Errored.Add(@{ type = $entry.Type; name = $name; message = $syntheticMsgCapped; completionKind = 'synthetic' })
            Write-SetLifecycleEvent -Phase 'end' -RunTrigger $RunTrigger -Path $ResourcesLogPath -SchemaVersion $ResourcesSchemaVersion `
                -RunId $RunId -HostName $HostName -Group $Group -Role $Role `
                -ConfigVersion $ConfigVersion -ConfigurationHash $ConfigurationHash `
                -ResourceName $name -ResourceType $entry.Type -Adapter $entry.Adapter `
                -DurationIso $dur -CompletionKind 'synthetic' -Result 'set_failed' `
                -ErrorMessage $syntheticErrorMsg -FragmentName $FragmentName -RecordSink $lifecycle.State.Buffer
        }
    }

    $parsed = ConvertFrom-DscTestJson -Json $native.Stdout
    $errored = @()
    if ($useStreaming -and $null -ne $lifecycle -and $null -ne $lifecycle.State -and $null -ne $lifecycle.State.Errored) {
        $errored = @($lifecycle.State.Errored.ToArray())
    }

    # Abort signal: a drifted seed with no terminal lifecycle event (observed or synthetic) means the
    # fragment died before reaching it. Exit-code/parse/error-signal is a required conjunct so a clean,
    # converging, exit-0 pass can't read as aborted.
    $unreached = @()
    $aborted = $false
    if ($useStreaming -and $null -ne $lifecycle -and $null -ne $lifecycle.State -and $null -ne $DriftedSeedNames) {
        $started = $lifecycle.State.Started
        foreach ($seed in $DriftedSeedNames) {
            if ([string]::IsNullOrWhiteSpace($seed)) { continue }
            if (-not $started.Contains($seed)) { $unreached += $seed }
        }
        if ($unreached.Count -gt 0) {
            $signal = Find-DscErrorSignal -Stderr $native.Stderr -MaxChars 2000
            $hasErrorSignal = -not [string]::IsNullOrWhiteSpace($signal.Excerpt)
            $aborted = ($native.ExitCode -ne 0) -or ($null -eq $parsed) -or $hasErrorSignal
        }
    }

    $bufferedRows = if ($null -ne $bufferSink) { @($bufferSink.ToArray()) } else { @() }

    return [pscustomobject]@{
        Native       = $native
        Parsed       = $parsed
        Errored      = $errored
        Aborted      = $aborted
        Unreached    = [string[]]@($unreached)
        BufferedRows = $bufferedRows
    }
}

function Invoke-DscGetJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DscExePath,
        [Parameter(Mandatory)][string]$ConfigFilePath
    )
    $timing = New-TimingCallback -ActivityVerb 'Get'
    $native = Invoke-DscNative -DscExePath $DscExePath -Subcommand 'get' -ConfigFilePath $ConfigFilePath `
        -OnStderrLine $timing.Callback
    $parsed = ConvertFrom-DscTestJson -Json $native.Stdout
    return [pscustomobject]@{
        Native  = $native
        Parsed  = $parsed
        Timings = $timing.Timings
    }
}

Export-ModuleMember -Function Invoke-DscNative, Invoke-DscTestJson, Invoke-DscSet, Invoke-DscGetJson
