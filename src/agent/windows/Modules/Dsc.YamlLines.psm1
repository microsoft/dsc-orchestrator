# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sharedModulePath = Join-Path $PSScriptRoot '..\..\..\core\shared\Dsc.YamlLines.psm1'
if (-not (Test-Path -LiteralPath $sharedModulePath -PathType Leaf)) {
    $sharedModulePath = Join-Path $PSScriptRoot 'Shared\Dsc.YamlLines.psm1'
}
if (-not (Test-Path -LiteralPath $sharedModulePath -PathType Leaf)) {
    throw "Shared YAML helper was not found relative to '$PSScriptRoot'."
}

Import-Module -Name $sharedModulePath -Force
Export-ModuleMember -Function Get-TopLevelResourcesBlock, Get-ResourceIdentifier, Get-DeclaredResources
