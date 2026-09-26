@{
    # Aggregate manifest for the Phase D bootstrap split.
    # bootstrap.ps1 imports this manifest via a $PSScriptRoot-relative absolute
    # path; PowerShell loads each .psm1 as a nested module and merges exports
    # into the bootstrap script's scope. PSModulePath is NOT reliable inside
    # the VM Application install context — the absolute import path is the
    # contract that makes bootstrap survive that environment. Single
    # Import-Module avoids the cascade-orphaned-export trap (see
    # ps-aggregate-manifest-not-import-cascade skill).
    RootModule        = ''
    ModuleVersion     = '1.0.0'
    GUID              = 'f0c45892-1e6d-4299-bdaa-32f553ef3ede'
    Author            = 'DSC Orchestrator contributors'
    Description       = 'DSC Orchestrator bootstrap helpers.'
    PowerShellVersion = '5.1'

    NestedModules = @(
        'Dsc.Bootstrap.Staging.psm1',
        'Dsc.Bootstrap.ScheduledTask.psm1'
    )

    FunctionsToExport = @(
        # Dsc.Bootstrap.Staging
        'Install-ScopedModule','Wait-ForRuntimeFilesUnlocked','Remove-CurrentPath','Replace-CurrentContent','Sync-AllUsersModules',
        # Dsc.Bootstrap.ScheduledTask
        'Stop-DscEnforcementProcess','Wait-ForEnforcementTaskQuiet'
    )
    CmdletsToExport   = @()
    AliasesToExport   = @()
    VariablesToExport = @()
}
