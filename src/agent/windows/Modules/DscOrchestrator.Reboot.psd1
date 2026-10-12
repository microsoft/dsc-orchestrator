# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

@{
    RootModule        = 'Dsc.RebootRequest.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'f4207b4f-85d5-4395-871a-fd57c3fddfab'
    Author            = 'DSC Orchestrator contributors'
    Description       = 'Orchestrator reboot-request helper for DSC resources.'
    PowerShellVersion = '5.1'
    FunctionsToExport  = @('Request-DscReboot')
    CmdletsToExport    = @()
    AliasesToExport    = @()
    VariablesToExport  = @()
}
