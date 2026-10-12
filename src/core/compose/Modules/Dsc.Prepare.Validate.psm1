# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

# Dsc.Prepare.Validate — line-based YAML / token / wrapper-structure asserters.
#
# All asserters operate line-by-line on raw fragment content. Do NOT swap any
# of these for a structured YAML walker — unquoted whole-scalar
# `{{ ParameterName }}` tokens mis-parse in powershell-yaml and yq.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-NoUnresolvedToken {
    <#
    .SYNOPSIS
        Throws if the fragment still carries an unresolved template/render token.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$AllowSupportedParameterTokens
    )

    $tokenPatterns = @(
        @{ Pattern = '\$\{\{'; Description = 'pipeline template expression (${{ }})' },
        @{ Pattern = '\$\(';   Description = 'pipeline variable expression ($(...))' },
        @{ Pattern = '\$\[';   Description = 'pipeline expression ($[...])' },
        @{ Pattern = '\$env:'; Description = 'PowerShell environment variable reference ($env:...)' },
        @{ Pattern = '<%';     Description = 'template token (<%...%>)' },
        @{ Pattern = '%>';     Description = 'template token (<%...%>)' },
        @{ Pattern = '(?<![A-Za-z0-9])__[A-Za-z0-9_.-]+__(?![A-Za-z0-9])'; Description = 'double-underscore placeholder (__TOKEN__)' }
    )
    if (-not $AllowSupportedParameterTokens) {
        $tokenPatterns += @(
            @{ Pattern = '\{\{'; Description = 'template token ({{...}})' },
            @{ Pattern = '\}\}'; Description = 'template token ({{...}})' }
        )
    }

    foreach ($entry in $tokenPatterns) {
        if ($Content -match $entry.Pattern) {
            throw "Fragment '$Path' contains unresolved or unsupported $($entry.Description). Native DSCv3 fragments may only use supported {{ ParameterName }} render tokens before platform packaging."
        }
    }
}

function Assert-NoUnsupportedYamlFeature {
    <#
    .SYNOPSIS
        Throws if the fragment uses YAML merge keys, anchors, aliases, or custom tags.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $lines = @($Content -split "`r?`n")
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $lineNumber = $i + 1
        $line = $lines[$i]
        if ($line.TrimStart().StartsWith('#')) {
            continue
        }
        if ($line -match '^\s*<<\s*:') {
            throw "Fragment '$Path' line $lineNumber uses a YAML merge key. DSCv3 fragments must use explicit YAML without merge keys."
        }
        if ($line -match '(^|[\s\[{,])(?<token>[&*][A-Za-z0-9_-]+)(?=\s|$|[,\]}])') {
            throw "Fragment '$Path' line $lineNumber uses YAML anchor or alias token '$($Matches.token)'. DSCv3 fragments must use explicit YAML without anchors or aliases."
        }
        if ($line -match '(^|[\s\[{,])(?<token>![A-Za-z][A-Za-z0-9_/.-]*|!<[^>]+>)(?=\s|$|[,\]}])') {
            throw "Fragment '$Path' line $lineNumber uses YAML custom tag '$($Matches.token)'. DSCv3 fragments must use plain YAML values only."
        }
    }
}

function Assert-RenderTokensAreWholeScalars {
    <#
    .SYNOPSIS
        Throws if a `{{ ParameterName }}` render token appears anywhere other than as a
        whole scalar value (unquoted OR fully quoted with single/double quotes).
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Validates every render token in the fragment.')]
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $supportedTokenPattern = '\{\{\s*[A-Za-z_][A-Za-z0-9_]*\s*\}\}'
    $wholeScalarPattern = '^\s*(?:-\s+)?(?:[A-Za-z0-9_.-]+\s*:\s*)?(?:''' + $supportedTokenPattern + '''|"' + $supportedTokenPattern + '"|' + $supportedTokenPattern + ')\s*(?:#.*)?$'
    $lines = @($Content -split "`r?`n")
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -notmatch $supportedTokenPattern) {
            continue
        }
        if ($line -notmatch $wholeScalarPattern) {
            $lineNumber = $i + 1
            throw "Fragment '$Path' line $lineNumber uses a DSCv3 render token outside a whole scalar value. Use whole-scalar tokens — bare ({{ x }}) or fully quoted ('{{ x }}' or `"{{ x }}`"). Tokens cannot be combined with literal text or appear inside flow-sequence arrays."
        }
    }
}

function Assert-PerResourceWrapperStructure {
    <#
    .SYNOPSIS
        Enforces 1:1 wrapper-to-resource structure for schema 1.7 set-lifecycle observability.
    .DESCRIPTION
        Each Microsoft.DSC/PowerShell wrapper must contain exactly one inner resource.
        Multi-inner wrappers break per-resource progress events and runtime lifecycle hooks.
        Line-based parsing (not yaml-parser based): unquoted {{ ParameterName }} tokens
        mis-parse as flow-mapping syntax in powershell-yaml and yq.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string[]]$ResourceBlock
    )

    $dashLines = @()
    for ($i = 0; $i -lt $ResourceBlock.Count; $i++) {
        if ($ResourceBlock[$i] -match '^(?<indent>\s*)-\s+') {
            $dashLines += [pscustomobject]@{ Index = $i; Indent = ([string]$Matches.indent).Length }
        }
    }
    if ($dashLines.Count -eq 0) { return }

    $rootIndent = ($dashLines | Measure-Object -Property Indent -Minimum).Minimum
    $rootItems = @($dashLines | Where-Object { $_.Indent -eq $rootIndent } | ForEach-Object { $_.Index })

    $childIndent = $rootIndent + 2
    $innerListIndent = $childIndent + 2
    $innerDashIndent = $innerListIndent + 2

    $typePattern = '^\s{' + $childIndent + '}type\s*:\s*(?<value>.+?)\s*(?:#.*)?$'
    $namePattern = '^\s{' + $childIndent + '}name\s*:\s*(?<value>.+?)\s*(?:#.*)?$'
    $propsKeyPattern = '^\s{' + $childIndent + '}properties\s*:\s*(?:#.*)?$'
    $resourcesKeyPattern = '^\s{' + $innerListIndent + '}resources\s*:\s*(?:#.*)?$'
    $innerDashPattern = '^\s{' + $innerDashIndent + '}-\s+'

    for ($n = 0; $n -lt $rootItems.Count; $n++) {
        $itemStart = $rootItems[$n]
        $itemEnd = if ($n -lt ($rootItems.Count - 1)) { $rootItems[$n + 1] - 1 } else { $ResourceBlock.Count - 1 }

        $wrapperType = $null; $wrapperName = $null
        for ($k = $itemStart; $k -le $itemEnd; $k++) {
            $line = $ResourceBlock[$k]
            if ($null -eq $wrapperType -and $line -match $typePattern) {
                $wrapperType = ([string]$Matches.value).Trim().Trim("'`"")
            }
            if ($null -eq $wrapperName -and $line -match $namePattern) {
                $wrapperName = ([string]$Matches.value).Trim().Trim("'`"")
            }
            if ($null -eq $wrapperName -and $k -eq $itemStart -and `
                $line -match '^\s*-\s+name\s*:\s*(?<value>.+?)\s*(?:#.*)?$') {
                $wrapperName = ([string]$Matches.value).Trim().Trim("'`"")
            }
        }

        if ($wrapperType -ne 'Microsoft.DSC/PowerShell') { continue }

        $displayName = if ($wrapperName) { $wrapperName } else { "<unnamed at index $n>" }

        $propsLine = -1; $innerListLine = -1
        for ($k = $itemStart; $k -le $itemEnd; $k++) {
            if ($propsLine -lt 0 -and $ResourceBlock[$k] -match $propsKeyPattern) { $propsLine = $k }
            elseif ($propsLine -ge 0 -and $ResourceBlock[$k] -match $resourcesKeyPattern) { $innerListLine = $k; break }
        }

        $innerCount = 0
        if ($innerListLine -ge 0) {
            for ($k = $innerListLine + 1; $k -le $itemEnd; $k++) {
                $line = $ResourceBlock[$k]
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                if ($line -match '^(\s*)\S' -and ([string]$Matches[1]).Length -lt $innerListIndent) { break }
                if ($line -match $innerDashPattern) { $innerCount++ }
            }
        }

        if ($innerCount -ne 1) {
            throw "Fragment '$Path' wrapper '$displayName' (index $n) contains $innerCount inner resources; the per-resource wrapper structure required for schema 1.7 set-lifecycle observability requires exactly one. Restructure the fragment so each Microsoft.DSC/PowerShell wrapper contains a single inner resource."
        }
    }
}

Export-ModuleMember -Function Assert-NoUnresolvedToken, Assert-NoUnsupportedYamlFeature, Assert-RenderTokensAreWholeScalars, Assert-PerResourceWrapperStructure
