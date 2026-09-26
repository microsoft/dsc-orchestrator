#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
    $ciScriptPath = Join-Path $script:RepoRoot 'build\Invoke-CI.ps1'
    $tokens = $null
    $parseErrors = $null
    $ciScriptAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $ciScriptPath,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if ($parseErrors.Count -gt 0) {
        throw "Could not parse CI script: $($parseErrors -join '; ')"
    }

    $gateFunction = $ciScriptAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Assert-CIPesterResult'
    }, $true)
    if ($null -eq $gateFunction) {
        throw "Could not find Assert-CIPesterResult in $ciScriptPath"
    }

    . ([scriptblock]::Create($gateFunction.Extent.Text))
}

Describe 'CI Pester result gate' {
    It 'accepts a passed result with no failures' {
        $result = [pscustomobject]@{
            Result                = 'Passed'
            FailedCount           = 0
            FailedBlocksCount     = 0
            FailedContainersCount = 0
        }

        { Assert-CIPesterResult -Result $result } | Should -Not -Throw
    }

    It 'rejects a failed result when no individual test failures are counted' {
        $result = [pscustomobject]@{
            Result                = 'Failed'
            FailedCount           = 0
            FailedBlocksCount     = 0
            FailedContainersCount = 1
        }

        { Assert-CIPesterResult -Result $result } | Should -Throw '*Pester failed*'
    }

    It 'rejects failed blocks even if the overall result is Passed' {
        $result = [pscustomobject]@{
            Result                = 'Passed'
            FailedCount           = 0
            FailedBlocksCount     = 1
            FailedContainersCount = 0
        }

        { Assert-CIPesterResult -Result $result } | Should -Throw '*failed block*'
    }

    It 'rejects failed containers even if the overall result is Passed' {
        $result = [pscustomobject]@{
            Result                = 'Passed'
            FailedCount           = 0
            FailedBlocksCount     = 0
            FailedContainersCount = 1
        }

        { Assert-CIPesterResult -Result $result } | Should -Throw '*failed container*'
    }

    It 'rejects failed tests even if the overall result is Passed' {
        $result = [pscustomobject]@{
            Result                = 'Passed'
            FailedCount           = 1
            FailedBlocksCount     = 0
            FailedContainersCount = 0
        }

        { Assert-CIPesterResult -Result $result } | Should -Throw '*failed test*'
    }
}
