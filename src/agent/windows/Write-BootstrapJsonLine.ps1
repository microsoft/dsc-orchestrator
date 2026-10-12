# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

# WinPS 5.1 compatible. BOM-less UTF-8 keeps JSONL readers compatible.
function Write-BootstrapJsonLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('preflight', 'download', 'extract', 'install', 'register', 'success', 'fatal')]
        [string]$Stage,

        [Parameter(Mandatory = $true)]
        [ValidateSet('ok', 'error')]
        [string]$Status,

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [string]$Path = 'C:\ProgramData\DscOrchestrator\logs\bootstrap.jsonl',
        [string]$ConfigVersion = '',
        [string]$PwshSource = '',
        [string]$PwshPath = '',
        [string]$PwshVersion = '',
        [string]$ErrorType = '',
        [string]$ErrorMessage = ''
    )

    $record = [ordered]@{
        TimeGenerated  = (Get-Date).ToUniversalTime().ToString('o')
        Computer       = $env:COMPUTERNAME
        config_version = $ConfigVersion
        stage          = $Stage
        status         = $Status
        message        = $Message
        pwsh_source    = $PwshSource
        pwsh_path      = $PwshPath
        pwsh_version   = $PwshVersion
        error_type     = $ErrorType
        error_message  = $ErrorMessage
    }

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
    }

    $line = ($record | ConvertTo-Json -Compress -Depth 5)
    [System.IO.File]::AppendAllText(
        $Path,
        $line + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false)
    )
}
