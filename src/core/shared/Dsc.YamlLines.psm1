# Dsc.YamlLines — line-based YAML enumeration primitives shared by build and runtime.
#
# Avoids powershell-yaml runtime dependency: ConvertFrom-Yaml mis-parses unquoted
# {{ ParameterName }} tokens and is not staged to the VM.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-TopLevelResourcesBlock {
    <#
    .SYNOPSIS
        Returns the line array of the top-level `resources:` sequence in a fragment.
        Throws if the fragment lacks one or contains more than one top-level resources key.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string[]]$Lines
    )

    $resourceIndexes = @()
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^resources:\s*(?:#.*)?$') {
            $resourceIndexes += $i
        }
    }

    if ($resourceIndexes.Count -eq 0) {
        throw "Fragment '$Path' does not contain a top-level resources array."
    }
    if ($resourceIndexes.Count -gt 1) {
        throw "Fragment '$Path' contains multiple top-level resources keys. Keep one resources array per fragment."
    }

    $start = $resourceIndexes[0] + 1
    $block = [System.Collections.Generic.List[string]]::new()
    for ($i = $start; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        if ($line -match '^\S[^:#]*:\s*' -and $line -notmatch '^-') {
            break
        }
        $block.Add($line)
    }

    while ($block.Count -gt 0 -and [string]::IsNullOrWhiteSpace($block[$block.Count - 1])) {
        $block.RemoveAt($block.Count - 1)
    }

    $hasArrayItem = $false
    foreach ($line in $block) {
        if ($line -match '^\s*-\s+') {
            $hasArrayItem = $true
            break
        }
    }
    if (-not $hasArrayItem) {
        throw "Fragment '$Path' has a resources key, but it is not a non-empty YAML sequence."
    }

    return ,$block.ToArray()
}

function Get-ResourceIdentifier {
    <#
    .SYNOPSIS
        Extracts ConfigName/Path/Name identifiers from each top-level resource in a block.
    .DESCRIPTION
        Names are matched line-based; downstream uniqueness uses OrdinalIgnoreCase.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ConfigName,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string[]]$ResourceBlock
    )

    $dashLines = @()
    for ($i = 0; $i -lt $ResourceBlock.Count; $i++) {
        if ($ResourceBlock[$i] -match '^(?<indent>\s*)-\s+') {
            $dashLines += [pscustomobject]@{
                Index = $i
                Indent = ([string]$Matches.indent).Length
            }
        }
    }
    if ($dashLines.Count -eq 0) {
        throw "Fragment '$Path' has no resources array items."
    }

    $rootIndent = ($dashLines | Measure-Object -Property Indent -Minimum).Minimum
    $rootItemIndexes = @($dashLines | Where-Object { $_.Indent -eq $rootIndent } | ForEach-Object { $_.Index })
    $identifiers = [System.Collections.Generic.List[object]]::new()

    for ($n = 0; $n -lt $rootItemIndexes.Count; $n++) {
        $itemStart = $rootItemIndexes[$n]
        $itemEnd = if ($n -lt ($rootItemIndexes.Count - 1)) { $rootItemIndexes[$n + 1] - 1 } else { $ResourceBlock.Count - 1 }
        $itemLines = @($ResourceBlock[$itemStart..$itemEnd])

        $name = $null
        foreach ($line in $itemLines) {
            if ($line -match '^\s*-\s+name:\s*(?<value>.+?)\s*(?:#.*)?$' -or
                $line -match ('^\s{{{0}}}name:\s*(?<value>.+?)\s*(?:#.*)?$' -f ($rootIndent + 2))) {
                $name = ([string]$Matches.value).Trim().Trim("'`"")
                break
            }
        }

        if ([string]::IsNullOrWhiteSpace($name)) {
            throw "Fragment '$Path' contains a top-level resource without a concrete name. Every resource needs a unique name."
        }

        $identifiers.Add([pscustomobject]@{
            ConfigName = $ConfigName
            Path = $Path
            Name = $name
        })
    }

    return ,$identifiers.ToArray()
}

function Get-DeclaredResources {
    <#
    .SYNOPSIS
        Enumerates all declared resources from a fragment YAML file.
    .DESCRIPTION
        Shape-based: any wrapper with properties.resources[] is unwrapped, adapter-agnostic.
        Used by the honesty emitter when dsc.exe fails to produce parseable JSON so
        fragment telemetry isn't lost.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Enumerates the complete resource collection declared in a fragment.')]
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    $lines = [System.IO.File]::ReadAllLines($Path)
    $resourcesBlock = Get-TopLevelResourcesBlock -Path $Path -Lines $lines

    $rootIndent = -1
    $rootItemIndexes = @()
    for ($i = 0; $i -lt $resourcesBlock.Count; $i++) {
        if ($resourcesBlock[$i] -match '^(?<indent>\s*)-\s+') {
            $indent = ([string]$Matches.indent).Length
            if ($rootIndent -lt 0) {
                $rootIndent = $indent
            }
            if ($indent -eq $rootIndent) {
                $rootItemIndexes += $i
            }
        }
    }

    $childIndent = $rootIndent + 2
    $innerListIndent = $childIndent + 2
    $innerDashIndent = $innerListIndent + 2
    $innerKeyIndent = $innerDashIndent + 2

    $typeAtChild      = '^\s{' + $childIndent     + '}type\s*:\s*(?<value>.+?)\s*(?:#.*)?$'
    $nameAtChild      = '^\s{' + $childIndent     + '}name\s*:\s*(?<value>.+?)\s*(?:#.*)?$'
    $typeOnDash       = '^\s*-\s+type\s*:\s*(?<value>.+?)\s*(?:#.*)?$'
    $nameOnDash       = '^\s*-\s+name\s*:\s*(?<value>.+?)\s*(?:#.*)?$'
    $resourcesAtInner = '^\s{' + $innerListIndent + '}resources\s*:\s*(?:#.*)?$'
    $innerTypeAtKey   = '^\s{' + $innerKeyIndent  + '}type\s*:\s*(?<value>.+?)\s*(?:#.*)?$'
    $innerTypeOnDash  = '^\s{' + $innerDashIndent + '}-\s+type\s*:\s*(?<value>.+?)\s*(?:#.*)?$'
    $innerNameAtKey   = '^\s{' + $innerKeyIndent  + '}name\s*:\s*(?<value>.+?)\s*(?:#.*)?$'
    $innerNameOnDash  = '^\s{' + $innerDashIndent + '}-\s+name\s*:\s*(?<value>.+?)\s*(?:#.*)?$'

    $declaredResources = [System.Collections.Generic.List[object]]::new()

    for ($n = 0; $n -lt $rootItemIndexes.Count; $n++) {
        $itemStart = $rootItemIndexes[$n]
        $itemEnd = if ($n -lt ($rootItemIndexes.Count - 1)) { $rootItemIndexes[$n + 1] - 1 } else { $resourcesBlock.Count - 1 }

        $topType = $null
        $topName = $null
        for ($k = $itemStart; $k -le $itemEnd; $k++) {
            $line = $resourcesBlock[$k]
            if ($null -eq $topType -and $line -match $typeAtChild) {
                $topType = ([string]$Matches.value).Trim().Trim("'`"")
            }
            if ($null -eq $topType -and $k -eq $itemStart -and $line -match $typeOnDash) {
                $topType = ([string]$Matches.value).Trim().Trim("'`"")
            }
            if ($null -eq $topName -and $line -match $nameAtChild) {
                $topName = ([string]$Matches.value).Trim().Trim("'`"")
            }
            if ($null -eq $topName -and $k -eq $itemStart -and $line -match $nameOnDash) {
                $topName = ([string]$Matches.value).Trim().Trim("'`"")
            }
        }

        $innerListLine = -1
        for ($k = $itemStart; $k -le $itemEnd; $k++) {
            if ($resourcesBlock[$k] -match $resourcesAtInner) {
                $innerListLine = $k
                break
            }
        }

        $innerDashIndexes = @()
        if ($innerListLine -ge 0) {
            for ($k = $innerListLine + 1; $k -le $itemEnd; $k++) {
                $line = $resourcesBlock[$k]
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                if ($line -match '^(\s*)\S' -and ([string]$Matches[1]).Length -lt $innerListIndent) {
                    break
                }
                if ($line -match ('^\s{{{0}}}-\s+' -f $innerDashIndent)) {
                    $innerDashIndexes += $k
                }
            }
        }

        $innerRows = [System.Collections.Generic.List[object]]::new()
        $hasAdapterShape = ($innerListLine -ge 0 -and $innerDashIndexes.Count -gt 0)
        for ($m = 0; $hasAdapterShape -and $m -lt $innerDashIndexes.Count; $m++) {
            $innerStart = $innerDashIndexes[$m]
            $innerEnd = if ($m -lt ($innerDashIndexes.Count - 1)) { $innerDashIndexes[$m + 1] - 1 } else { $itemEnd }

            $innerType = $null
            $innerName = $null
            for ($k = $innerStart; $k -le $innerEnd; $k++) {
                $line = $resourcesBlock[$k]
                if ($null -eq $innerType -and $line -match $innerTypeAtKey) {
                    $innerType = ([string]$Matches.value).Trim().Trim("'`"")
                }
                if ($null -eq $innerType -and $k -eq $innerStart -and $line -match $innerTypeOnDash) {
                    $innerType = ([string]$Matches.value).Trim().Trim("'`"")
                }
                if ($null -eq $innerName -and $line -match $innerNameAtKey) {
                    $innerName = ([string]$Matches.value).Trim().Trim("'`"")
                }
                if ($null -eq $innerName -and $k -eq $innerStart -and $line -match $innerNameOnDash) {
                    $innerName = ([string]$Matches.value).Trim().Trim("'`"")
                }
            }

            if ([string]::IsNullOrEmpty($innerType)) {
                $hasAdapterShape = $false
                break
            }

            $innerRows.Add([pscustomobject]@{
                Type            = $innerType
                Name            = $innerName
                Adapter         = $topType
                AdapterInstance = $topName
            })
        }

        if ($hasAdapterShape) {
            foreach ($innerRow in $innerRows) {
                $declaredResources.Add($innerRow)
            }
        } else {
            if (-not [string]::IsNullOrEmpty($topType) -or -not [string]::IsNullOrEmpty($topName)) {
                $declaredResources.Add([pscustomobject]@{
                    Type            = $topType
                    Name            = $topName
                    Adapter         = ''
                    AdapterInstance = ''
                })
            }
        }
    }

    return $declaredResources.ToArray()
}

Export-ModuleMember -Function Get-TopLevelResourcesBlock, Get-ResourceIdentifier, Get-DeclaredResources
