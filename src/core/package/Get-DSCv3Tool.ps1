
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'The build helper reports download and signature-verification progress to the operator.')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('dsc', 'pwsh')]
    [string]$ToolName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory,

    [Parameter()]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$ManifestPath = (Join-Path $PSScriptRoot 'tools-manifest.json'),

    [Parameter()]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$SignerAllowListPath = (Join-Path $PSScriptRoot 'tools-signer-allowlist.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Test-AllowedAuthenticodeSigner {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$AllowListPath
    )

    $signature = Get-AuthenticodeSignature -FilePath $Path
    if ($signature.Status -ne 'Valid') {
        throw "Authenticode verification failed for '$Path'. Status=$($signature.Status); Message=$($signature.StatusMessage)"
    }
    if ($null -eq $signature.SignerCertificate) {
        throw "Authenticode verification failed for '$Path': signer certificate is missing."
    }

    $allowList = Get-JsonFile -Path $AllowListPath
    foreach ($allowed in @($allowList.allowedSigners)) {
        $subjectOk = $signature.SignerCertificate.Subject -match $allowed.subjectRegex
        $issuerOk = [string]::IsNullOrWhiteSpace($allowed.issuerRegex) -or
            ($signature.SignerCertificate.Issuer -match $allowed.issuerRegex)
        if ($subjectOk -and $issuerOk) {
            return $true
        }
    }

    throw "Authenticode signer '$($signature.SignerCertificate.Subject)' issued by '$($signature.SignerCertificate.Issuer)' is not in '$AllowListPath'."
}

$manifest = Get-JsonFile -Path $ManifestPath
if (-not ($manifest.PSObject.Properties.Name -contains 'tools')) {
    throw "Tools manifest '$ManifestPath' is missing the 'tools' object."
}
$tool = $manifest.tools.$ToolName
if ($null -eq $tool) {
    throw "Tools manifest '$ManifestPath' has no entry for tool '$ToolName'."
}
foreach ($required in 'version', 'sourceUrl', 'archiveSha256', 'binaryPath') {
    if (-not ($tool.PSObject.Properties.Name -contains $required) -or [string]::IsNullOrWhiteSpace($tool.$required)) {
        throw "Tool '$ToolName' in manifest '$ManifestPath' is missing required property '$required'."
    }
}

if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}

$archivePath = Join-Path $OutputDirectory ("{0}-{1}.zip" -f $ToolName, $tool.version)
$extractPath = Join-Path $OutputDirectory ("{0}-{1}" -f $ToolName, $tool.version)
$binaryPath = Join-Path $extractPath $tool.binaryPath

Write-Host "Downloading pinned $ToolName $($tool.version) from $($tool.sourceUrl)"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri $tool.sourceUrl -OutFile $archivePath -UseBasicParsing

$actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
$expectedHash = ([string]$tool.archiveSha256).ToLowerInvariant()
if ($actualHash -ne $expectedHash) {
    throw "$ToolName archive SHA256 mismatch for '$archivePath'. Expected $expectedHash from '$ManifestPath'; actual $actualHash. Refusing to unzip."
}

if (Test-Path -LiteralPath $extractPath) {
    Remove-Item -LiteralPath $extractPath -Recurse -Force
}
New-Item -ItemType Directory -Path $extractPath -Force | Out-Null
Expand-Archive -Path $archivePath -DestinationPath $extractPath -Force

if (-not (Test-Path -LiteralPath $binaryPath -PathType Leaf)) {
    throw "Pinned $ToolName archive did not contain '$($tool.binaryPath)' at '$binaryPath'."
}

[void](Test-AllowedAuthenticodeSigner -Path $binaryPath -AllowListPath $SignerAllowListPath)

Write-Host "$ToolName binary verified: $binaryPath"

[pscustomobject]@{
    ToolName      = $ToolName
    Version       = $tool.version
    SourceUrl     = $tool.sourceUrl
    ArchiveSha256 = $actualHash
    BinaryPath    = $binaryPath
    ExtractPath   = $extractPath
}
