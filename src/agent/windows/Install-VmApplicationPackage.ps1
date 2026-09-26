[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Version,

    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$PackageArchivePath,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$DscRoot = 'C:\ProgramData\DscOrchestrator',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$TaskName = 'DscOrchestrator-Enforcement',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$RegistryRoot = 'HKLM:\SOFTWARE\DscOrchestrator\Reboot',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$AllUsersModulesPath = 'C:\Program Files\WindowsPowerShell\Modules',

    [Parameter()]
    [switch]$Update,

    [Parameter()]
    [switch]$AuditOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$PackageArchivePath = [System.IO.Path]::GetFullPath($PackageArchivePath)
$DscRoot = [System.IO.Path]::GetFullPath($DscRoot)
$logsRoot = Join-Path $DscRoot 'logs'
$installRoot = Join-Path $DscRoot 'install'
$bootstrapLog = Join-Path $logsRoot 'bootstrap.jsonl'
$bootstrapStarted = $false

if (-not (Test-Path -LiteralPath $logsRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $logsRoot -Force -ErrorAction Stop | Out-Null
}
if (Test-Path -LiteralPath $installRoot) {
    Remove-Item -LiteralPath $installRoot -Recurse -Force -ErrorAction Stop
}
New-Item -ItemType Directory -Path $installRoot -Force -ErrorAction Stop | Out-Null

$logWriterPath = Join-Path $installRoot 'Write-BootstrapJsonLine.ps1'
try {
    & tar.exe -x -f $PackageArchivePath -C $installRoot
    if ($LASTEXITCODE -ne 0) {
        throw "tar.exe extraction failed (exit $LASTEXITCODE)."
    }

    $manifestPath = Join-Path $installRoot 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Package archive '$PackageArchivePath' does not contain manifest.json."
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop |
        ConvertFrom-Json -ErrorAction Stop
    if ([string]$manifest.version -ne $Version) {
        throw "Package version '$($manifest.version)' does not match requested version '$Version'."
    }

    if (-not (Test-Path -LiteralPath $logWriterPath -PathType Leaf)) {
        throw "Package archive is missing '$logWriterPath'."
    }
    . $logWriterPath
    Write-BootstrapJsonLine -Path $bootstrapLog -Stage 'extract' -Status 'ok' `
        -Message "Extracted package to $installRoot" -ConfigVersion $Version

    $bootstrapPath = Join-Path $installRoot 'bootstrap.ps1'
    if (-not (Test-Path -LiteralPath $bootstrapPath -PathType Leaf)) {
        throw "Package archive is missing bootstrap.ps1 at '$bootstrapPath'."
    }

    $bootstrapStarted = $true
    & $bootstrapPath `
        -Version $Version `
        -PackageRoot $installRoot `
        -DscRoot $DscRoot `
        -TaskName $TaskName `
        -RegistryRoot $RegistryRoot `
        -AllUsersModulesPath $AllUsersModulesPath `
        -Update:$Update `
        -AuditOnly:$AuditOnly

    Remove-Item -LiteralPath $installRoot -Recurse -Force -ErrorAction Stop
}
catch {
    $failure = $_
    if ($bootstrapStarted) {
        throw
    }
    if (Test-Path -LiteralPath $logWriterPath -PathType Leaf) {
        . $logWriterPath
        Write-BootstrapJsonLine -Path $bootstrapLog -Stage 'fatal' -Status 'error' `
            -Message "VM Application package installation failed for version $Version" `
            -ConfigVersion $Version `
            -ErrorType $failure.Exception.GetType().Name `
            -ErrorMessage $failure.Exception.Message
    }
    else {
        $record = [ordered]@{
            TimeGenerated  = (Get-Date).ToUniversalTime().ToString('o')
            Computer       = $env:COMPUTERNAME
            config_version = $Version
            stage          = 'extract'
            status         = 'error'
            message        = 'VM Application package extraction failed'
            error_type     = $failure.Exception.GetType().Name
            error_message  = $failure.Exception.Message
        } | ConvertTo-Json -Compress -Depth 5
        [System.IO.File]::AppendAllText(
            $bootstrapLog,
            $record + [Environment]::NewLine,
            [System.Text.UTF8Encoding]::new($false)
        )
    }
    throw
}
