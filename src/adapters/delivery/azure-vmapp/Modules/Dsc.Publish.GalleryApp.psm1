# Dsc.Publish.GalleryApp - gallery application and version create/get/recreate.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ARM API version for direct Invoke-AzRestMethod calls. Module-scope const.
$script:ComputeGalleryApiVersion = '2024-03-03'

function ConvertTo-VMApplicationPackageCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Install', 'Update')]
        [string]$Action,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$PackageFileName,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^\d+\.\d+\.\d+$')]
        [string]$Version,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$DscRoot
    )

    if ([System.IO.Path]::GetFileName($PackageFileName) -ne $PackageFileName) {
        throw "PackageFileName must be a file name, not a path: '$PackageFileName'."
    }

    $packageLiteral = "'" + $PackageFileName.Replace("'", "''") + "'"
    $versionLiteral = "'" + $Version.Replace("'", "''") + "'"
    $dscRootLiteral = "'" + $DscRoot.Replace("'", "''") + "'"
    $commandParameters = "-PackageArchivePath `$zipPath -Version $versionLiteral -DscRoot $dscRootLiteral"
    if ($Action -eq 'Update') {
        $commandParameters += ' -Update'
    }

    $expr = @"
`$ErrorActionPreference='Stop'; `$zipPath=(Resolve-Path -LiteralPath (Join-Path (Get-Location) $packageLiteral)).Path; Add-Type -AssemblyName System.IO.Compression.FileSystem; `$archive=[System.IO.Compression.ZipFile]::OpenRead(`$zipPath); try { `$entry=`$archive.GetEntry('Install-VmApplicationPackage.ps1'); if (-not `$entry) { throw 'Install-VmApplicationPackage.ps1 missing from package archive' }; `$reader=[System.IO.StreamReader]::new(`$entry.Open()); try { `$entryPoint=`$reader.ReadToEnd() } finally { `$reader.Dispose() } } finally { `$archive.Dispose() }; try { & ([scriptblock]::Create(`$entryPoint)) $commandParameters; exit 0 } catch { [Console]::Error.WriteLine(`$_.Exception.Message); exit 1 }
"@
    return "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `"$expr`""
}

function ConvertTo-VMApplicationRemoveCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$PackageFileName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$DscRoot
    )

    if ([System.IO.Path]::GetFileName($PackageFileName) -ne $PackageFileName) {
        throw "PackageFileName must be a file name, not a path: '$PackageFileName'."
    }

    $packageLiteral = "'" + $PackageFileName.Replace("'", "''") + "'"
    $dscRootLiteral = "'" + $DscRoot.Replace("'", "''") + "'"
    $expr = @"
`$ErrorActionPreference='Stop'; `$zipPath=(Resolve-Path -LiteralPath (Join-Path (Get-Location) $packageLiteral)).Path; Add-Type -AssemblyName System.IO.Compression.FileSystem; `$archive=[System.IO.Compression.ZipFile]::OpenRead(`$zipPath); try { `$entry=`$archive.GetEntry('remove.ps1'); if (-not `$entry) { throw 'remove.ps1 missing from package archive' }; `$reader=[System.IO.StreamReader]::new(`$entry.Open()); try { `$entryPoint=`$reader.ReadToEnd() } finally { `$reader.Dispose() } } finally { `$archive.Dispose() }; try { & ([scriptblock]::Create(`$entryPoint)) -DscRoot $dscRootLiteral; exit 0 } catch { [Console]::Error.WriteLine(`$_.Exception.Message); exit 1 }
"@
    return "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `"$expr`""
}

function Get-ExistingGalleryApplicationVersion {
    <#
    .SYNOPSIS
        Returns existing version or $null. Distinguishes NotFound (expected) from real errors.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$GalleryName,
        [Parameter(Mandatory = $true)][string]$ResourceGroupName,
        [Parameter(Mandatory = $true)][string]$ApplicationName,
        [Parameter(Mandatory = $true)][string]$Version
    )

    try {
        return Get-AzGalleryApplicationVersion `
            -GalleryName            $GalleryName `
            -ResourceGroupName      $ResourceGroupName `
            -GalleryApplicationName $ApplicationName `
            -Name                   $Version `
            -ErrorAction            Stop
    }
    catch {
        $msg = $_.Exception.Message
        if ($msg -match '(?i)NotFound' -or $msg -match '(?i)ResourceNotFound' -or $msg -match '(?i)could not be found' -or $msg -match '(?i)was not found') {
            return $null
        }
        throw
    }
}

function Get-GalleryApplicationTag {
    # Module-private helper: prefer Application.Tags, fall back to ARM REST.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Application,
        [Parameter(Mandatory = $true)][string]$GalleryName,
        [Parameter(Mandatory = $true)][string]$ResourceGroupName,
        [Parameter(Mandatory = $true)][string]$ApplicationName
    )

    if (($Application.PSObject.Properties.Name -contains 'Tags') -and $null -ne $Application.Tags) {
        return $Application.Tags
    }

    $ctx = Get-AzContext
    if ($null -eq $ctx -or $null -eq $ctx.Subscription) {
        return @{}
    }

    $resourceId = "/subscriptions/$($ctx.Subscription.Id)/resourceGroups/$ResourceGroupName/providers/Microsoft.Compute/galleries/$GalleryName/applications/$ApplicationName"
    $response = Invoke-AzRestMethod -Method GET -Path "${resourceId}?api-version=$script:ComputeGalleryApiVersion" -ErrorAction Stop
    if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
        throw "Failed to read Compute Gallery application '$ApplicationName' ARM tags. StatusCode=$($response.StatusCode); Content=$($response.Content)"
    }

    $resource = $response.Content | ConvertFrom-Json -ErrorAction Stop
    if (($resource.PSObject.Properties.Name -contains 'tags') -and $null -ne $resource.tags) {
        return $resource.tags
    }
    return @{}
}

function Ensure-GalleryApplication {
    <#
    .SYNOPSIS
        Ensures parent gallery application exists (creates if missing, validates tags).
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs','', Justification='Keeps the helper name aligned with the gallery application create-or-validate behavior.')]
    param(
        [Parameter(Mandatory = $true)][string]$GalleryName,
        [Parameter(Mandatory = $true)][string]$ResourceGroupName,
        [Parameter(Mandatory = $true)][string]$ApplicationName,
        [Parameter(Mandatory = $true)][string]$Location,
        [Parameter()][hashtable]$ExpectedTags
    )

    $app = $null
    try {
        $app = Get-AzGalleryApplication `
            -GalleryName       $GalleryName `
            -ResourceGroupName $ResourceGroupName `
            -Name              $ApplicationName `
            -ErrorAction       Stop
    }
    catch {
        $msg = $_.Exception.Message
        if ($msg -notmatch '(?i)NotFound' -and $msg -notmatch '(?i)was not found' -and $msg -notmatch '(?i)could not be found') {
            throw
        }
    }

    if ($null -ne $app) {
        if ($ExpectedTags) {
            $actualTags = Get-GalleryApplicationTag -Application $app -GalleryName $GalleryName -ResourceGroupName $ResourceGroupName -ApplicationName $ApplicationName
            foreach ($k in $ExpectedTags.Keys) {
                $actual = $null
                if ($null -ne $actualTags -and ($actualTags.PSObject.Properties.Name -contains $k)) {
                    $actual = $actualTags.$k
                } elseif ($null -ne $actualTags -and $actualTags -is [System.Collections.IDictionary] -and $actualTags.Contains($k)) {
                    $actual = $actualTags[$k]
                }
                if ($actual -ne $ExpectedTags[$k]) {
                    throw "Gallery application name collision for '$ApplicationName'. Existing app tag '$k' is '$actual', expected '$($ExpectedTags[$k])'. Choose another application name or update the existing gallery application intentionally."
                }
            }
        }
        Write-Verbose "Gallery application '$ApplicationName' already exists (id=$($app.Id))."
        return $app
    }

    $target = "gallery $GalleryName / application $ApplicationName (Windows) in $ResourceGroupName"
    if (-not $PSCmdlet.ShouldProcess($target, 'Create gallery application')) {
        throw "Gallery application '$ApplicationName' does not exist and creation was not confirmed (-WhatIf or user declined). Cannot proceed."
    }

    Write-Information "Creating gallery application '$ApplicationName' in '$ResourceGroupName' / '$GalleryName'."
    $newParams = @{
        GalleryName = $GalleryName
        ResourceGroupName = $ResourceGroupName
        Name = $ApplicationName
        Location = $Location
        SupportedOSType = 'Windows'
        ErrorAction = 'Stop'
    }
    if ($ExpectedTags -and (Get-Command New-AzGalleryApplication).Parameters.ContainsKey('Tag')) {
        $newParams['Tag'] = $ExpectedTags
    }
    return New-AzGalleryApplication @newParams
}

function New-DscV3GalleryApplicationVersion {
    <#
    .SYNOPSIS
        Creates gallery-application-version with DSCv3 install/remove/update actions.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$GalleryName,
        [Parameter(Mandatory = $true)][string]$ResourceGroupName,
        [Parameter(Mandatory = $true)][string]$ApplicationName,
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$Location,
        [Parameter(Mandatory = $true)][string]$BlobUri,
        [Parameter(Mandatory = $true)][string]$PackageFileName,
        [Parameter(Mandatory = $true)][string]$DscRoot,
        [Parameter()][string[]]$TargetRegions
    )

    $installCommand = ConvertTo-VMApplicationPackageCommand `
        -Action Install -PackageFileName $PackageFileName -Version $Version -DscRoot $DscRoot
    $updateCommand = ConvertTo-VMApplicationPackageCommand `
        -Action Update -PackageFileName $PackageFileName -Version $Version -DscRoot $DscRoot
    $removeCommand = ConvertTo-VMApplicationRemoveCommand `
        -PackageFileName $PackageFileName -DscRoot $DscRoot

    $target = "gallery-application-version '$ApplicationName/$Version' in $ResourceGroupName/$GalleryName"
    if (-not $PSCmdlet.ShouldProcess($target, 'Create gallery application version')) {
        throw "Operation cancelled (-WhatIf or user declined). Cannot publish $target."
    }

    $effectiveTargetRegions = $TargetRegions
    if ($null -eq $effectiveTargetRegions -or $effectiveTargetRegions.Count -eq 0) {
        $effectiveTargetRegions = @($Location)
    }
    $targetRegion = @($effectiveTargetRegions | ForEach-Object { @{ Name = $_; RegionalReplicaCount = 1 } })

    Write-Information "Creating gallery-application-version '$ApplicationName/$Version' in source region '$Location', targets: $($effectiveTargetRegions -join ', ')."
    $versionCommand = Get-Command New-AzGalleryApplicationVersion -ErrorAction Stop
    $versionParams = @{
        GalleryName            = $GalleryName
        ResourceGroupName      = $ResourceGroupName
        GalleryApplicationName = $ApplicationName
        Name                   = $Version
        Location               = $Location
        TargetRegion           = $targetRegion
        PackageFileName        = $PackageFileName
        ErrorAction            = 'Stop'
    }

    if ($versionCommand.Parameters.ContainsKey('Source') -and
        $versionCommand.Parameters.ContainsKey('ManageAction') -and
        (Get-Command New-AzGalleryApplicationVersionSource -ErrorAction SilentlyContinue) -and
        (Get-Command New-AzGalleryApplicationVersionManageAction -ErrorAction SilentlyContinue)) {
        $versionParams['Source'] = New-AzGalleryApplicationVersionSource -MediaLink $BlobUri
        $versionParams['ManageAction'] = New-AzGalleryApplicationVersionManageAction -Install $installCommand -Remove $removeCommand -Update $updateCommand
    } else {
        $versionParams['PackageFileLink'] = $BlobUri
        $versionParams['Install'] = $installCommand
        $versionParams['Remove'] = $removeCommand
        $versionParams['Update'] = $updateCommand
    }

    if ($versionCommand.Parameters.ContainsKey('TreatFailureAsDeploymentFailure')) {
        $versionParams['TreatFailureAsDeploymentFailure'] = $true
    }
    else {
        $azComputeVersion = (Get-Module Az.Compute | Select-Object -First 1 -ExpandProperty Version) -as [string]
        if ([string]::IsNullOrWhiteSpace($azComputeVersion)) { $azComputeVersion = '<not loaded>' }
        Write-Warning ("Az.Compute $azComputeVersion does not expose -TreatFailureAsDeploymentFailure on New-AzGalleryApplicationVersion; " +
            "publishing without it. Upgrade to a newer Az.Compute (>=8.x exposes this parameter) to restore fail-closed semantics. " +
            "SECURITY IMPACT: VM Application install/update failures on this gallery-application-version will NOT propagate as " +
            "deployment failures; downstream gating logic must compensate (e.g., post-deploy compliance check on resources.jsonl).")
    }

    return New-AzGalleryApplicationVersion @versionParams
}

Export-ModuleMember -Function ConvertTo-VMApplicationPackageCommand, ConvertTo-VMApplicationRemoveCommand, Get-ExistingGalleryApplicationVersion, Ensure-GalleryApplication, New-DscV3GalleryApplicationVersion
