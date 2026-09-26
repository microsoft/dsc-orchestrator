# Dsc.Publish.Blob - package upload and blob URI validation.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-BlobUri {
    <#
    .SYNOPSIS
        Validates blob URI shape and rejects SAS tokens (DSCv3 requires plain private URL).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$ExpectedStorageAccount,
        [Parameter(Mandatory = $true)][string]$ExpectedContainer
    )

    $pattern = '^https://{0}\.blob\.core\.(windows|usgovcloudapi)\.net/{1}/' -f [regex]::Escape($ExpectedStorageAccount), [regex]::Escape($ExpectedContainer)
    if ($Uri -notmatch $pattern) {
        throw "Blob URI '$Uri' does not match the expected storage account and container. Refusing to use an unexpected URI in the gallery application version."
    }
    if ($Uri -match '\?' -or $Uri -match '(?i)(^|[?&])sig=') {
        throw "Blob URI '$Uri' contains a query string or SAS signature. Publish requires a private blob URL consumed through the Compute Gallery managed identity."
    }
}

function Invoke-PackageUpload {
    <#
    .SYNOPSIS
        Uploads package to blob via AAD (UseConnectedAccount). No SAS/shared-key fallback.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LocalPath,
        [Parameter(Mandatory = $true)][string]$StorageAccount,
        [Parameter(Mandatory = $true)][string]$StorageResourceGroup,
        [Parameter(Mandatory = $true)][string]$Container,
        [Parameter(Mandatory = $true)][string]$Blob
    )

    Write-Verbose "Creating AAD storage context for '$StorageAccount'."
    try {
        $storageContext = New-AzStorageContext -StorageAccountName $StorageAccount -UseConnectedAccount -ErrorAction Stop
    }
    catch {
        $msg = $_.Exception.Message
        $ctx = Get-AzContext
        $isAccessTokenContext = $null -ne $ctx -and $null -ne $ctx.Account -and $ctx.Account.Type -eq 'AccessToken'
        $isTokenResourceFailure = $msg -match 'StorageOAuthEndpointResourceId'
        if (-not ($isAccessTokenContext -and $isTokenResourceFailure)) {
            throw
        }
        # Az.Storage can't mint storage token from access-token context; fall back to Azure CLI.
        Write-Warning "Access-token Az context detected; falling back to Azure CLI AAD upload."
        return Invoke-PackageUploadWithAzureCli `
            -LocalPath            $LocalPath `
            -StorageAccount       $StorageAccount `
            -StorageResourceGroup $StorageResourceGroup `
            -Container            $Container `
            -Blob                 $Blob
    }

    try {
        $existingContainer = Get-AzStorageContainer -Name $Container -Context $storageContext -ErrorAction SilentlyContinue
        if (-not $existingContainer) {
            Write-Information "Container '$Container' missing; creating with private access (first DSCv3 publish)."
            New-AzStorageContainer -Name $Container -Context $storageContext -Permission Off -ErrorAction Stop | Out-Null
        }

        Set-AzStorageBlobContent `
            -File      $LocalPath `
            -Container $Container `
            -Blob      $Blob `
            -Context   $storageContext `
            -Force `
            -ErrorAction Stop | Out-Null
    }
    catch {
        $msg  = $_.Exception.Message
        $is403 = ($msg -match '(?i)\b403\b') -or
                 ($msg -match '(?i)AuthorizationFailure') -or
                 ($msg -match '(?i)AuthorizationPermissionMismatch') -or
                 ($msg -match '(?i)does not have authorization')

        if (-not $is403) { throw }

        throw "Blob upload returned 403 on AAD (UseConnectedAccount). Grant the current identity '$( (Get-AzContext).Account.Id )' the 'Storage Blob Data Contributor' role on storage account '$StorageAccount'. Publish does not allow SAS or shared-key fallback. Original error: $msg"
    }

    $blobObj = Get-AzStorageBlob -Container $Container -Blob $Blob -Context $storageContext -ErrorAction Stop
    return $blobObj.ICloudBlob.Uri.AbsoluteUri
}

function Invoke-PackageUploadWithAzureCli {
    <#
    .SYNOPSIS
        Azure CLI AAD upload fallback for access-token Az contexts (local testing).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LocalPath,
        [Parameter(Mandatory = $true)][string]$StorageAccount,
        [Parameter(Mandatory = $true)][string]$StorageResourceGroup,
        [Parameter(Mandatory = $true)][string]$Container,
        [Parameter(Mandatory = $true)][string]$Blob
    )

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw "Azure CLI is required for access-token local publish fallback, but 'az' was not found. Use a normal Connect-AzAccount session or install Azure CLI."
    }

    $uploadArgs = @(
        'storage', 'blob', 'upload',
        '--account-name', $StorageAccount,
        '--container-name', $Container,
        '--name', $Blob,
        '--file', $LocalPath,
        '--auth-mode', 'login',
        '--overwrite', 'true',
        '--only-show-errors',
        '--output', 'none'
    )
    $uploadOutput = & az @uploadArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI AAD blob upload failed for '$StorageAccount/$Container/$Blob'. Output: $uploadOutput"
    }

    $endpoint = & az storage account show `
        --resource-group $StorageResourceGroup `
        --name $StorageAccount `
        --query 'primaryEndpoints.blob' `
        --output tsv 2>&1
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$endpoint)) {
        throw "Azure CLI failed to resolve blob endpoint for storage account '$StorageAccount'. Output: $endpoint"
    }

    $encodedBlob = [uri]::EscapeDataString($Blob) -replace '%2F', '/'
    return ("{0}/{1}/{2}" -f ([string]$endpoint).TrimEnd('/'), $Container, $encodedBlob)
}

Export-ModuleMember -Function Test-BlobUri, Invoke-PackageUpload, Invoke-PackageUploadWithAzureCli
