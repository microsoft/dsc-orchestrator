#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pester v5 unit suite for Dsc.Diagnostics.psm1 — dsc.exe stderr signal extraction.
.DESCRIPTION
    Pure-string coverage (no mocks) for Find-DscErrorSignal, the recovery layer's sole
    attribution mechanism. The branch that sets ResourceName/ResourceType (from the latest
    activity JSON) is what decides whether a failure is attributable, so the four output
    paths are exercised directly:
      - JSON-ERROR-first extraction  -> Tag '[json_extracted]'  (with resource context),
      - non-JSON fallback tail        -> Tag '[fallback_excerpt]',
      - activity-context sentinel     -> "no ERROR-level stderr; last activity: <name>",
      - MaxLines / MaxChars caps on both the JSON and fallback paths.

    See scripts/dscv3/tests/README.md for the CI invocation contract.
#>

Set-StrictMode -Version Latest

BeforeAll {
    Set-StrictMode -Version Latest

    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ModuleRoot = Join-Path $script:RepoRoot 'src\agent\windows\Modules'
    Import-Module (Join-Path $script:ModuleRoot 'Dsc.Diagnostics.psm1') -Force
}

Describe 'Find-DscErrorSignal' {

    Context 'JSON-ERROR-first extraction path' {

        It 'extracts ERROR-level fields.message and tags it [json_extracted]' {
            $stderr = @(
                '{"timestamp":"2026-05-13T00:38:38Z","level":"INFO","fields":{"message":"starting test"}}'
                '{"timestamp":"2026-05-13T00:38:41Z","level":"ERROR","fields":{"message":"value-type conversion failed for property Count"}}'
            )

            $signal = Find-DscErrorSignal -Stderr $stderr

            $signal.Tag | Should -Be '[json_extracted]'
            $signal.Excerpt | Should -Be 'value-type conversion failed for property Count'
        }

        It 'sets ResourceName/ResourceType from the latest activity JSON alongside the ERROR excerpt' {
            # The activity line is what makes the failure attributable; assert both the excerpt
            # (from the ERROR line) and the resource context (from the activity line) are surfaced.
            $stderr = @(
                '{"activity":"test","resourceName":"WrapperA","resourceType":"Microsoft.DSC/PowerShell"}'
                '{"level":"ERROR","fields":{"message":"boom"}}'
            )

            $signal = Find-DscErrorSignal -Stderr $stderr

            $signal.Tag | Should -Be '[json_extracted]'
            $signal.Excerpt | Should -Be 'boom'
            $signal.ResourceName | Should -Be 'WrapperA'
            $signal.ResourceType | Should -Be 'Microsoft.DSC/PowerShell'
        }

        It 'falls back to the top-level message when an ERROR line has no fields.message' {
            $stderr = @('{"level":"ERROR","message":"top-level only error"}')

            $signal = Find-DscErrorSignal -Stderr $stderr

            $signal.Tag | Should -Be '[json_extracted]'
            $signal.Excerpt | Should -Be 'top-level only error'
        }

        It 'joins multiple ERROR messages with "; "' {
            $stderr = @(
                '{"level":"ERROR","fields":{"message":"first"}}'
                '{"level":"ERROR","fields":{"message":"second"}}'
            )

            $signal = Find-DscErrorSignal -Stderr $stderr

            $signal.Tag | Should -Be '[json_extracted]'
            $signal.Excerpt | Should -Be 'first; second'
        }
    }

    Context 'non-JSON fallback-tail path' {

        It 'returns the tail of non-JSON lines tagged [fallback_excerpt] with empty resource context' {
            $stderr = @(
                'Error: failed to parse configuration document'
                'caused by: unexpected token at line 12'
            )

            $signal = Find-DscErrorSignal -Stderr $stderr

            $signal.Tag | Should -Be '[fallback_excerpt]'
            $signal.Excerpt | Should -Be 'Error: failed to parse configuration document; caused by: unexpected token at line 12'
            $signal.ResourceName | Should -Be ''
            $signal.ResourceType | Should -Be ''
        }

        It 'drops PowerShell stack-trace artifact lines (At ... / + ...) from the fallback excerpt' {
            $stderr = @(
                'Exception: You cannot call a method on a null-valued expression.'
                'At C:\Users\test\foo.ps1:42 char:5'
                '+     bad-line'
            )

            $signal = Find-DscErrorSignal -Stderr $stderr

            $signal.Tag | Should -Be '[fallback_excerpt]'
            $signal.Excerpt | Should -Be 'Exception: You cannot call a method on a null-valued expression.'
        }
    }

    Context 'activity-context sentinel (no ERROR JSON, no usable non-JSON lines)' {

        It 'returns the "last activity" sentinel when only an activity JSON line is present' {
            $stderr = @('{"activity":"test","resourceName":"WrapperA","resourceType":"Microsoft.DSC/PowerShell"}')

            $signal = Find-DscErrorSignal -Stderr $stderr

            $signal.Tag | Should -Be '[fallback_excerpt]'
            $signal.Excerpt | Should -Be 'no ERROR-level stderr; last activity: WrapperA'
            $signal.ResourceName | Should -Be 'WrapperA'
            $signal.ResourceType | Should -Be 'Microsoft.DSC/PowerShell'
        }

        It 'returns the stable empty shape for empty stderr' {
            $signal = Find-DscErrorSignal -Stderr @()

            $signal.Tag | Should -Be '[fallback_excerpt]'
            $signal.Excerpt | Should -Be ''
            $signal.ResourceName | Should -Be ''
            $signal.ResourceType | Should -Be ''
        }
    }

    Context 'MaxLines / MaxChars caps' {

        It 'caps JSON ERROR extraction to the first MaxLines messages' {
            $stderr = 1..5 | ForEach-Object { '{"level":"ERROR","fields":{"message":"err' + $_ + '"}}' }

            $signal = Find-DscErrorSignal -Stderr $stderr -MaxLines 2

            $signal.Tag | Should -Be '[json_extracted]'
            $signal.Excerpt | Should -Be 'err1; err2'
        }

        It 'caps the fallback path to the last MaxLines lines' {
            $stderr = 1..5 | ForEach-Object { "line$_" }

            $signal = Find-DscErrorSignal -Stderr $stderr -MaxLines 2

            $signal.Tag | Should -Be '[fallback_excerpt]'
            $signal.Excerpt | Should -Be 'line4; line5'
        }

        It 'truncates the excerpt to MaxChars and appends an ellipsis' {
            $longMessage = 'A' * 100
            $stderr = @('{"level":"ERROR","fields":{"message":"' + $longMessage + '"}}')

            $signal = Find-DscErrorSignal -Stderr $stderr -MaxChars 10

            $signal.Tag | Should -Be '[json_extracted]'
            $signal.Excerpt | Should -Be (('A' * 10) + '...')
            $signal.Excerpt.Length | Should -Be 13
        }
    }

    Context 'activity-string ResourceName fallback' {
        # Set/Test progress events frequently name the resource only in the activity STRING
        # ("Set 'X'") with no structured resourceName field. The fallback parses it so set-abort
        # attribution is not lost. It NARROWS the unattributable set; it does not eliminate it.

        It 'parses ResourceName from the activity string when resourceName field is absent' {
            $stderr = @(
                '{"activity":"Set ''WrapperX''"}'
                '{"level":"ERROR","fields":{"message":"boom"}}'
            )

            $signal = Find-DscErrorSignal -Stderr $stderr

            $signal.Tag | Should -Be '[json_extracted]'
            $signal.Excerpt | Should -Be 'boom'
            $signal.ResourceName | Should -Be 'WrapperX'
        }

        It 'parses ResourceName from a Test-verb activity string' {
            $stderr = @('{"activity":"Test ''WrapperT''"}')

            $signal = Find-DscErrorSignal -Stderr $stderr

            $signal.ResourceName | Should -Be 'WrapperT'
        }

        It 'leaves ResourceName empty for a no-activity error stderr (residual unattributable gap)' {
            # DscError::Command / pre-resource load path emits no activity event at all -> the
            # fallback cannot attribute it; ResourceName stays empty -> unattributable bail.
            $stderr = @('{"level":"ERROR","fields":{"message":"boom"}}')

            $signal = Find-DscErrorSignal -Stderr $stderr

            $signal.ResourceName | Should -Be ''
        }

        It 'prefers the structured resourceName field over the activity string' {
            # Fallback fires ONLY when resourceName is missing; a present field always wins.
            $stderr = @(
                '{"activity":"Set ''ActivityName''","resourceName":"StructuredName"}'
                '{"level":"ERROR","fields":{"message":"boom"}}'
            )

            $signal = Find-DscErrorSignal -Stderr $stderr

            $signal.ResourceName | Should -Be 'StructuredName'
        }
    }
}
