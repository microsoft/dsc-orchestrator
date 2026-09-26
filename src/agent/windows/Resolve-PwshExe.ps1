
function Resolve-PwshExe {
    [CmdletBinding()]
    param(
        [string]$PackageRoot = $PSScriptRoot
    )

    $candidates = New-Object System.Collections.Generic.List[object]

    $bundled = Join-Path $PackageRoot 'pwsh\pwsh.exe'
    if (Test-Path -LiteralPath $bundled) {
        [void]$candidates.Add([PSCustomObject]@{ Path = $bundled; Source = 'bundled' })
    }

    $cmd = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) {
        [void]$candidates.Add([PSCustomObject]@{ Path = $cmd.Source; Source = 'path' })
    }

    $seen = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in $candidates) {
        if (-not $seen.Add($candidate.Path)) { continue }
        try {
            $reported = & $candidate.Path -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()' 2>$null
            $versionString = ($reported | Select-Object -First 1)
            $major = 0
            if ($versionString -match '^(?<m>\d+)') { $major = [int]$Matches.m }
            if ($major -ge 7) {
                return [PSCustomObject]@{
                    Path    = $candidate.Path
                    Source  = $candidate.Source
                    Version = [string]$versionString
                }
            }
        } catch {
            Write-Verbose "Resolve-PwshExe: probe of '$($candidate.Path)' failed: $($_.Exception.Message)"
        }
    }

    $probed = @($candidates | ForEach-Object { $_.Path }) -join '; '
    $searched = if ($probed) {
        "Searched candidates that did not verify as PS 7+: $probed."
    } else {
        "No pwsh candidates found at: '$bundled'; PATH."
    }
    throw "Resolve-PwshExe: no PowerShell 7 found. DSCv3 must run on PowerShell 7. The VM App package is expected to ship a bundled pwsh at '$bundled'; verify the package contract. $searched"
}
