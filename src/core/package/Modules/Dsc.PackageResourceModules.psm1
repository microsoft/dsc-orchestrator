Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-DSCv3ComparableVersion {
    [CmdletBinding()]
    [OutputType([version])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Version
    )

    $parsedVersion = $null
    if (-not [version]::TryParse($Version, [ref]$parsedVersion)) {
        return $null
    }

    $build = $parsedVersion.Build
    if ($build -lt 0) {
        $build = 0
    }
    $revision = $parsedVersion.Revision
    if ($revision -lt 0) {
        $revision = 0
    }

    return [version]::new($parsedVersion.Major, $parsedVersion.Minor, $build, $revision)
}

function Find-DSCv3ModuleVersionFolder {
    [CmdletBinding()]
    [OutputType([System.IO.DirectoryInfo])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ModuleRoot,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Version
    )

    $requestedVersion = ConvertTo-DSCv3ComparableVersion -Version $Version
    if ($null -eq $requestedVersion) {
        throw "Module version '$Version' is not a valid numeric version."
    }
    if (-not (Test-Path -LiteralPath $ModuleRoot -PathType Container)) {
        return $null
    }

    $matchingFolders = [System.Collections.Generic.List[System.IO.DirectoryInfo]]::new()
    foreach ($candidateFolder in Get-ChildItem -LiteralPath $ModuleRoot -Directory -ErrorAction Stop) {
        $candidateVersion = ConvertTo-DSCv3ComparableVersion -Version $candidateFolder.Name
        if ($null -ne $candidateVersion -and $candidateVersion.CompareTo($requestedVersion) -eq 0) {
            $matchingFolders.Add($candidateFolder)
        }
    }

    if ($matchingFolders.Count -gt 1) {
        $folderNames = @($matchingFolders | ForEach-Object { $_.Name }) -join ', '
        throw "Module '$ModuleRoot' has multiple version folders numerically equivalent to '$Version': $folderNames."
    }
    if ($matchingFolders.Count -eq 0) {
        return $null
    }

    return $matchingFolders[0]
}

function Resolve-DSCv3ResourceModules {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Resolves every declared resource module for a package.')]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [string]$ModulesPath,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$ResourceModules
    )

    $resolvedModules = [System.Collections.Generic.List[object]]::new()
    foreach ($module in $ResourceModules) {
        $moduleName = [string]$module.name
        $declaredVersion = [string]$module.version
        $moduleRoot = Join-Path $ModulesPath $moduleName
        $versionFolder = Find-DSCv3ModuleVersionFolder -ModuleRoot $moduleRoot -Version $declaredVersion
        if ($null -eq $versionFolder) {
            throw "Declared module '$moduleName' version '$declaredVersion' is not staged in a numerically equivalent version folder under '$moduleRoot'."
        }

        $resolvedModules.Add([pscustomobject]@{
            Name        = $moduleName
            Version     = $versionFolder.Name
            ModuleRoot  = $moduleRoot
            VersionPath = $versionFolder.FullName
        })
    }

    return $resolvedModules.ToArray()
}

function Copy-DSCv3ResourceModulesToPackage {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Copies every declared resource module into the package.')]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$ResolvedModules,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$DestinationPath
    )

    $manifestModules = [System.Collections.Generic.List[object]]::new()
    foreach ($module in $ResolvedModules) {
        $moduleName = [string]$module.Name
        $moduleVersion = [string]$module.Version
        $versionPath = [string]$module.VersionPath
        if (-not (Test-Path -LiteralPath $versionPath -PathType Container)) {
            throw "Resolved module '$moduleName' version '$moduleVersion' is no longer staged at '$versionPath'."
        }

        $modulePackageRoot = Join-Path $DestinationPath $moduleName
        $packageVersionPath = Join-Path $modulePackageRoot $moduleVersion
        if (-not $PSCmdlet.ShouldProcess($packageVersionPath, "Copy resource module '$moduleName' version '$moduleVersion' to the package")) {
            continue
        }
        if (-not (Test-Path -LiteralPath $DestinationPath -PathType Container)) {
            New-Item -ItemType Directory -Path $DestinationPath -Force -ErrorAction Stop | Out-Null
        }
        if (-not (Test-Path -LiteralPath $modulePackageRoot -PathType Container)) {
            New-Item -ItemType Directory -Path $modulePackageRoot -Force -ErrorAction Stop | Out-Null
        }
        Copy-Item -LiteralPath $versionPath -Destination $modulePackageRoot -Recurse -Force -ErrorAction Stop
        if (-not (Test-Path -LiteralPath $packageVersionPath -PathType Container)) {
            throw "Resource module '$moduleName' version '$moduleVersion' was not copied to '$packageVersionPath'."
        }

        $manifestModules.Add([ordered]@{
            name    = $moduleName
            version = $moduleVersion
        })
    }

    return $manifestModules.ToArray()
}

function Test-DSCv3ModuleAlignment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$ModuleNames
    )

    $declaredModules = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($moduleName in $ModuleNames) {
        [void]$declaredModules.Add($moduleName)
    }

    $content = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop
    $resourceTypes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($match in [regex]::Matches($content, '(?m)^\s*type:\s*["'']?(?<type>[^"''\s#]+)')) {
        [void]$resourceTypes.Add($match.Groups['type'].Value)
    }

    $missingModules = [System.Collections.Generic.List[string]]::new()
    foreach ($resourceType in $resourceTypes) {
        if ($resourceType -notmatch '^(?<module>[^/]+)/[^/]+$') {
            continue
        }

        $moduleName = $Matches.module
        if ($moduleName -like 'Microsoft.*') {
            continue
        }
        if (-not $declaredModules.Contains($moduleName)) {
            $missingModules.Add("$moduleName (resource type '$resourceType')")
        }
    }

    if ($missingModules.Count -gt 0) {
        throw "DSCv3 config references resource module(s) not present in the staged module package: $($missingModules -join ', '). Declare and stage these modules in dsc-orchestrator.config.json."
    }
}

Export-ModuleMember -Function Find-DSCv3ModuleVersionFolder, Resolve-DSCv3ResourceModules, Copy-DSCv3ResourceModulesToPackage, Test-DSCv3ModuleAlignment
