<#
.SYNOPSIS
    Diagnostic helpers for extracting error signals from dsc.exe stderr.
.DESCRIPTION
    Single source of truth for parsing dsc.exe failure diagnostics. Consolidates
    stderr extraction logic into Find-DscErrorSignal with JSON-ERROR-first path
    and fallback to non-JSON excerpt.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'


function Find-DscErrorSignal {
    <#
    .SYNOPSIS
        Extracts error signals from dsc.exe stderr with JSON-ERROR-first parsing and resource context.
    .DESCRIPTION
        Single-pass hybrid algorithm:
        1. Collects all ERROR-level JSON messages (level='ERROR', fields.message)
        2. Collects latest activity JSON line for resource context (resourceName, resourceType)
        3. If ERROR JSON found, returns extracted messages with [json_extracted] tag
        4. Otherwise falls back to non-JSON tail excerpt with [fallback_excerpt] tag
        
        Always returns stable object with 4 fields (never null/missing for StrictMode safety):
        - Excerpt: The extracted error message(s) or fallback excerpt (string)
        - Tag: '[json_extracted]' or '[fallback_excerpt]' (string)
        - ResourceName: Name from activity JSON if found, else empty string
        - ResourceType: Type from activity JSON if found, else empty string
        
        MaxLines and MaxChars caps apply to BOTH JSON extraction AND fallback paths.
    .PARAMETER Stderr
        Raw stderr lines from dsc.exe (string array or single string).
    .PARAMETER MaxLines
        Maximum number of lines to include in excerpt (default 12).
    .PARAMETER MaxChars
        Maximum characters in final excerpt (default 2000).
    .OUTPUTS
        [PSCustomObject] with Excerpt, Tag, ResourceName, ResourceType.
    .EXAMPLE
        $signal = Find-DscErrorSignal -Stderr $testResult.Stderr
        "[$fragmentName]$($signal.Tag) native exit ${nativeExitCode}: $($signal.Excerpt)"
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [AllowEmptyCollection()]
        [string[]]$Stderr,
        
        [Parameter()]
        [ValidateRange(1, 100)]
        [int]$MaxLines = 12,
        
        [Parameter()]
        [ValidateRange(1, 16000)]
        [int]$MaxChars = 2000
    )

    # Initialize stable output shape (all fields always present)
    $result = [PSCustomObject]@{
        Excerpt      = ''
        Tag          = '[fallback_excerpt]'
        ResourceName = ''
        ResourceType = ''
    }

    if ($null -eq $Stderr -or $Stderr.Count -eq 0) {
        return $result
    }

    # Single pass: collect ERROR JSON messages, activity resource context, and non-JSON lines
    $errorMessages = [System.Collections.Generic.List[string]]::new()
    $nonJsonLines = [System.Collections.Generic.List[string]]::new()
    $latestActivity = $null

    # Normalize input to array of lines
    # $Stderr may be: single string, single string[], or pre-split string[]
    if ($Stderr.Count -eq 1 -and $Stderr[0].Contains("`n")) {
        # Single multi-line string (here-string) - split it
        $allLines = @($Stderr[0] -split "`r?`n")
    } elseif ($Stderr -is [string]) {
        # Direct string parameter (shouldn't happen with [string[]] type, but handle it)
        $allLines = @($Stderr -split "`r?`n")
    } else {
        # Already an array of lines
        $allLines = $Stderr
    }

    foreach ($rawLine in $allLines) {
        $line = $rawLine.Trim()
        if ([string]::IsNullOrEmpty($line)) { continue }

        # Attempt JSON parse
        $isJson = $false
        if ($line.Length -gt 0 -and $line[0] -eq '{') {
            try {
                $jsonObj = $line | ConvertFrom-Json -ErrorAction Stop
                $isJson = $true

                # Check for ERROR-level message
                if ($jsonObj.PSObject.Properties['level'] -and $jsonObj.level -eq 'ERROR') {
                    # Try fields.message first (structured), then fallback to top-level message
                    $msg = if ($jsonObj.PSObject.Properties['fields'] -and 
                              $jsonObj.fields.PSObject.Properties['message']) {
                        [string]$jsonObj.fields.message
                    } elseif ($jsonObj.PSObject.Properties['message']) {
                        [string]$jsonObj.message
                    } else {
                        $line
                    }
                    $errorMessages.Add($msg)
                }

                # Check for activity JSON (resource context) - skip if it's also an ERROR (don't double-count)
                if ($jsonObj.PSObject.Properties['activity'] -and 
                    (-not ($jsonObj.PSObject.Properties['level'] -and $jsonObj.level -eq 'ERROR'))) {
                    $latestActivity = $jsonObj
                }
            } catch {
                # Not valid JSON, treat as non-JSON
                $isJson = $false
            }
        }

        # Collect non-JSON diagnostic lines (excluding PowerShell stack trace artifacts)
        if (-not $isJson) {
            # Filter PowerShell error record format: "At line:", "At C:\...", and "+ ..." continuation lines
            if ($line -notmatch '^\s*At\s+' -and $line -notmatch '^\s*\+\s') {
                $nonJsonLines.Add($line)
            }
        }
    }

    # Extract resource context from latest activity JSON
    if ($null -ne $latestActivity) {
        if ($latestActivity.PSObject.Properties['resourceName']) {
            $result.ResourceName = [string]$latestActivity.resourceName
        } elseif ($latestActivity.PSObject.Properties['activity'] -and
                  ([string]$latestActivity.activity) -match "^(Set|Test) '(?<n>[^']+)'") {
            # Fallback: set/test progress often names the resource only in the activity string. A
            # no-activity abort (pre-resource load) still yields empty ResourceName.
            $result.ResourceName = $Matches.n
        }
        if ($latestActivity.PSObject.Properties['resourceType']) {
            $result.ResourceType = [string]$latestActivity.resourceType
        }
    }

    # Decide output based on what we collected
    if ($errorMessages.Count -gt 0) {
        # Primary path: JSON ERROR extraction
        $cappedMessages = @($errorMessages | Select-Object -First $MaxLines)
        $excerpt = $cappedMessages -join '; '
        if ($excerpt.Length -gt $MaxChars) {
            $excerpt = $excerpt.Substring(0, $MaxChars) + '...'
        }
        $result.Excerpt = $excerpt
        $result.Tag = '[json_extracted]'
    } elseif ($nonJsonLines.Count -gt 0) {
        # Fallback path: non-JSON tail excerpt
        $cappedLines = @($nonJsonLines | Select-Object -Last $MaxLines)
        $excerpt = $cappedLines -join '; '
        if ($excerpt.Length -gt $MaxChars) {
            $excerpt = $excerpt.Substring(0, $MaxChars) + '...'
        }
        $result.Excerpt = $excerpt
        $result.Tag = '[fallback_excerpt]'
    } else {
        # Safety net: no ERROR JSON and all lines filtered out
        # Return sentinel mentioning activity if we have resource context
        if (-not [string]::IsNullOrWhiteSpace($result.ResourceName)) {
            $result.Excerpt = "no ERROR-level stderr; last activity: $($result.ResourceName)"
        } else {
            # Absolute fallback: cap tail of original raw lines
            $rawTail = @($allLines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last $MaxLines)
            if ($rawTail.Count -gt 0) {
                $excerpt = ($rawTail -join '; ').Trim()
                if ($excerpt.Length -gt $MaxChars) {
                    $excerpt = $excerpt.Substring(0, $MaxChars) + '...'
                }
                $result.Excerpt = $excerpt
            }
        }
        $result.Tag = '[fallback_excerpt]'
    }

    return $result
}


Export-ModuleMember -Function Find-DscErrorSignal
