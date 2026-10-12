# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

<#
.SYNOPSIS
    Normalizes an explicit name for use as an Azure Compute Gallery application name.

.DESCRIPTION
    Produces a lowercase Azure-safe name from caller-provided input. Long names are
    truncated with a 12-character SHA-256 suffix to reduce collision risk.

.PARAMETER Name
    Explicit application name supplied by the caller.

.OUTPUTS
    [string] Azure-safe name ^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$. Long inputs
    are truncated with a 12-character SHA-256 suffix.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-AzureSafeGalleryApplicationName {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name
    )

    $raw = $Name.Trim().ToLowerInvariant()
    $safe = [regex]::Replace($raw, '[^a-z0-9._-]+', '-')
    $safe = [regex]::Replace($safe, '-{2,}', '-').Trim('-', '.')
    if ([string]::IsNullOrWhiteSpace($safe) -or $safe -notmatch '^[a-z0-9]') {
        $safe = "app-$safe".Trim('-', '.')
    }
    if ($safe.Length -gt 80) {
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            $hashBytes = $sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($raw))
        }
        finally {
            $sha256.Dispose()
        }
        $suffix = [BitConverter]::ToString($hashBytes).Replace('-', '').Substring(0, 12).ToLowerInvariant()
        $prefix = $safe.Substring(0, [Math]::Min(67, $safe.Length)).Trim('-', '.')
        if ([string]::IsNullOrWhiteSpace($prefix)) {
            $prefix = 'app'
        }
        $safe = $prefix + '-' + $suffix
    }
    if ($safe -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$') {
        throw "Normalized gallery application name '$safe' is not Azure-safe."
    }
    return $safe
}
