# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

# Dsc.Prepare.Assemble — line-based fragment slicing + resource identifier extraction.
#
# Both functions operate on string[] line buffers produced by the line-based
# emit pipeline. Do not introduce structured YAML walking — see Dsc.Prepare.Emit
# for the load-bearing contract.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\..\shared\Dsc.YamlLines.psm1') -Force

Export-ModuleMember -Function Get-TopLevelResourcesBlock, Get-ResourceIdentifier
