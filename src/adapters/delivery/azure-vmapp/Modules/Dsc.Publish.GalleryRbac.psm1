# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

# Dsc.Publish.GalleryRbac - Compute Gallery managed identity and storage RBAC.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ARM API version used for direct Invoke-AzRestMethod calls. Module-scoped const
# so callers (and the entry script) need not pass it through every signature.
$script:ComputeGalleryApiVersion = '2024-03-03'

function Get-GalleryManagedIdentityPrincipalId {
    <#
    .SYNOPSIS
        Resolves the principal IDs of the gallery's managed identity (system + user-assigned),
        enabling system-assigned MI on demand if absent. Module-private helper.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$ResourceGroupName
    )

    $ids = [System.Collections.Generic.List[string]]::new()
    $gallery = Get-AzGallery -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction Stop
    if (($gallery.PSObject.Properties.Name -contains 'Identity') -and $null -ne $gallery.Identity) {
        if (($gallery.Identity.PSObject.Properties.Name -contains 'PrincipalId') -and
            -not [string]::IsNullOrWhiteSpace([string]$gallery.Identity.PrincipalId)) {
            $ids.Add([string]$gallery.Identity.PrincipalId)
        }
    }

    if ($ids.Count -gt 0) {
        return $ids.ToArray()
    }

    $ctx = Get-AzContext
    if ($null -eq $ctx -or $null -eq $ctx.Subscription) {
        throw "No Az context available while resolving Compute Gallery managed identity for '$Name'."
    }

    $resourceId = "/subscriptions/$($ctx.Subscription.Id)/resourceGroups/$ResourceGroupName/providers/Microsoft.Compute/galleries/$Name"
    $response = Invoke-AzRestMethod -Method GET -Path "${resourceId}?api-version=$script:ComputeGalleryApiVersion" -ErrorAction Stop
    if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
        throw "Failed to read Compute Gallery '$Name' ARM resource identity. StatusCode=$($response.StatusCode); Content=$($response.Content)"
    }

    $resource = $response.Content | ConvertFrom-Json -ErrorAction Stop
    if (($resource.PSObject.Properties.Name -contains 'identity') -and $null -ne $resource.identity) {
        if (($resource.identity.PSObject.Properties.Name -contains 'principalId') -and
            -not [string]::IsNullOrWhiteSpace([string]$resource.identity.principalId)) {
            $ids.Add([string]$resource.identity.principalId)
        }
        if (($resource.identity.PSObject.Properties.Name -contains 'userAssignedIdentities') -and
            $null -ne $resource.identity.userAssignedIdentities) {
            foreach ($identity in @($resource.identity.userAssignedIdentities.PSObject.Properties.Value)) {
                if ($null -ne $identity -and
                    ($identity.PSObject.Properties.Name -contains 'principalId') -and
                    -not [string]::IsNullOrWhiteSpace([string]$identity.principalId)) {
                    $ids.Add([string]$identity.principalId)
                }
            }
        }
    }

    if ($ids.Count -gt 0) {
        return $ids.ToArray()
    }

    Write-Information "Compute Gallery '$Name' has no managed identity. Enabling system-assigned MI (bootstrap)..."
    $patchBody = @{ identity = @{ type = 'SystemAssigned' } } | ConvertTo-Json -Compress -Depth 5
    try {
        $patchResponse = Invoke-AzRestMethod `
            -Method PATCH `
            -Path "${resourceId}?api-version=$script:ComputeGalleryApiVersion" `
            -Payload $patchBody `
            -ErrorAction Stop
    }
    catch {
        $ex = $_.Exception
        if ($ex.Message -match '(?i)(authorization|forbidden|403|write)') {
            throw "Compute Gallery '$Name' in '$ResourceGroupName' has no managed identity AND the current Azure context lacks permission to enable one (need Microsoft.Compute/galleries/write). Either pre-enable the system-assigned identity on the gallery, or grant the current identity Contributor at the gallery scope. Details: $($ex.Message)"
        }
        throw
    }

    if ($patchResponse.StatusCode -lt 200 -or $patchResponse.StatusCode -ge 300) {
        $content = $patchResponse.Content
        if ($content -match '(?i)(authorization|forbidden|403|write)') {
            throw "Compute Gallery '$Name' in '$ResourceGroupName' has no managed identity AND the current Azure context lacks permission to enable one (need Microsoft.Compute/galleries/write). Either pre-enable the system-assigned identity on the gallery, or grant the current identity Contributor at the gallery scope. StatusCode=$($patchResponse.StatusCode); Content=$content"
        }
        throw "Failed to enable system-assigned managed identity on Compute Gallery '$Name'. StatusCode=$($patchResponse.StatusCode); Content=$content"
    }

    $retryCount = 0  # Re-fetch to capture newly issued principalId
    $maxRetries = 3
    $retryDelay = 2
    while ($retryCount -lt $maxRetries) {
        Start-Sleep -Seconds $retryDelay
        $updatedResponse = Invoke-AzRestMethod -Method GET -Path "${resourceId}?api-version=$script:ComputeGalleryApiVersion" -ErrorAction Stop
        if ($updatedResponse.StatusCode -ge 200 -and $updatedResponse.StatusCode -lt 300) {
            $updatedResource = $updatedResponse.Content | ConvertFrom-Json -ErrorAction Stop
            if (($updatedResource.PSObject.Properties.Name -contains 'identity') -and
                $null -ne $updatedResource.identity -and
                ($updatedResource.identity.PSObject.Properties.Name -contains 'principalId') -and
                -not [string]::IsNullOrWhiteSpace([string]$updatedResource.identity.principalId)) {
                $ids.Add([string]$updatedResource.identity.principalId)
                return $ids.ToArray()
            }
        }
        $retryCount++
    }

    throw "Enabled system-assigned managed identity on Compute Gallery '$Name', but the principalId is not yet available after $maxRetries retries. This may indicate slow Azure AD propagation. Retry the publish operation in a few moments."
}

function Assert-GalleryManagedIdentityBlobAccess {
    <#
    .SYNOPSIS
        Ensures the gallery managed identity has 'Storage Blob Data Reader' (or higher) on
        the package container. Auto-enables system-assigned MI and grants role on miss.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$GalleryName,
        [Parameter(Mandatory = $true)][string]$GalleryResourceGroup,
        [Parameter(Mandatory = $true)][string]$StorageAccountName,
        [Parameter(Mandatory = $true)][string]$StorageAccountResourceGroup,
        [Parameter(Mandatory = $true)][string]$ContainerName
    )

    $principalIds = @(Get-GalleryManagedIdentityPrincipalId -Name $GalleryName -ResourceGroupName $GalleryResourceGroup | ForEach-Object { $_ })

    if (-not (Get-Command Get-AzRoleAssignment -ErrorAction SilentlyContinue)) {
        throw "Get-AzRoleAssignment is unavailable. Import Az.Resources so publish can verify Compute Gallery managed identity RBAC for private blob access."
    }

    $storage = Get-AzStorageAccount -ResourceGroupName $StorageAccountResourceGroup -Name $StorageAccountName -ErrorAction Stop
    $storageScope = $storage.Id
    $containerScope = "$storageScope/blobServices/default/containers/$ContainerName"
    $roles = @()
    foreach ($principalId in $principalIds) {
        $roles += @(Get-AzRoleAssignment -ObjectId $principalId -ErrorAction Stop | Where-Object {
            $_.RoleDefinitionName -in @('Storage Blob Data Reader', 'Storage Blob Data Contributor', 'Storage Blob Data Owner') -and
            ($_.Scope -eq $storageScope -or $_.Scope -eq $containerScope)
        })
    }
    if ($roles.Count -eq 0) {
        Write-Information "Gallery MIs lack 'Storage Blob Data Reader' on container '$ContainerName'. Auto-granting (bootstrap)..."
        $missingPrincipals = @($principalIds)
        foreach ($principalId in $missingPrincipals) {
            Write-Information "Granting 'Storage Blob Data Reader' to gallery MI '$principalId' on container '$ContainerName'..."
            try {
                New-AzRoleAssignment `
                    -ObjectId $principalId `
                    -RoleDefinitionName 'Storage Blob Data Reader' `
                    -Scope $containerScope `
                    -ErrorAction Stop | Out-Null
            }
            catch {
                $ex = $_.Exception
                if ($ex.Message -match '(?i)(RoleAssignmentExists|409|Conflict)') {
                    Write-Information "Role assignment already exists for '$principalId' (concurrent grant). Continuing..."
                }
                elseif ($ex.Message -match '(?i)(authorization|forbidden|403|write)') {
                    throw "Cannot grant 'Storage Blob Data Reader' to gallery managed identity '$principalId' on container '$ContainerName'. The current Azure context lacks 'Microsoft.Authorization/roleAssignments/write'. Either pre-grant the role manually or grant the current identity User Access Administrator (or Owner) at the storage account or container scope. Details: $($ex.Message)"
                }
                else {
                    throw
                }
            }
        }

        $retryCount = 0  # Poll for RBAC propagation (Azure RBAC ~30-60 sec; 5 x 15s cap)
        $maxRetries = 5
        $retryDelay = 15
        $propagated = $false
        while ($retryCount -lt $maxRetries) {
            Start-Sleep -Seconds $retryDelay
            $retryCount++
            Write-Information "Waiting for RBAC propagation (attempt $retryCount of $maxRetries)..."

            $roles = @()
            foreach ($principalId in $principalIds) {
                $roles += @(Get-AzRoleAssignment -ObjectId $principalId -ErrorAction Stop | Where-Object {
                    $_.RoleDefinitionName -in @('Storage Blob Data Reader', 'Storage Blob Data Contributor', 'Storage Blob Data Owner') -and
                    ($_.Scope -eq $storageScope -or $_.Scope -eq $containerScope)
                })
            }

            if ($roles.Count -gt 0) {
                Write-Information "RBAC propagation confirmed. Gallery MI(s) now have 'Storage Blob Data Reader' on container '$ContainerName'."
                $propagated = $true
                break
            }
        }

        if (-not $propagated) {
            throw "Granted 'Storage Blob Data Reader' to gallery MI(s) on container '$ContainerName', but RBAC propagation timed out after $($maxRetries * $retryDelay) seconds. Retry the publish operation in a few moments."
        }
    }
}

Export-ModuleMember -Function Assert-GalleryManagedIdentityBlobAccess
