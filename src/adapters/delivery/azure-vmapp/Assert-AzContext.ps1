# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

<#
.SYNOPSIS
    Verifies an Az PowerShell context is present and optionally matches a subscription.
.DESCRIPTION
    Guard helper for mutating delivery operations. Throws if no Az context exists or
    if the active subscription differs from -ExpectedSubscriptionId. Never
    silently switches context; the caller is responsible for authentication and selection.
.PARAMETER ExpectedSubscriptionId
    Subscription GUID the caller expects the active context to target. Empty
    string skips the comparison and only validates that *some* context exists.
.EXAMPLE
    . $PSScriptRoot\Assert-AzContext.ps1
    Assert-AzContext -ExpectedSubscriptionId $ExpectedSubscriptionId
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-AzContext {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowEmptyString()]
        [string]$ExpectedSubscriptionId
    )

    $ctx = Get-AzContext
    if ($null -eq $ctx -or $null -eq $ctx.Subscription) {
        throw 'No Az context is available. Authenticate and select the target context before invoking this script.'
    }

    if (-not [string]::IsNullOrEmpty($ExpectedSubscriptionId)) {
        if ($ctx.Subscription.Id -ne $ExpectedSubscriptionId) {
            throw "Az context is on subscription '$($ctx.Subscription.Id)' but -ExpectedSubscriptionId '$ExpectedSubscriptionId' was specified. The adapter never switches context; select the expected subscription before invoking it."
        }
    }

    return $ctx
}
