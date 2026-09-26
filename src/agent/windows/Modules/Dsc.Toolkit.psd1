@{
    # Aggregate manifest for the agent runtime modules. The entry script
    # (Invoke-Enforcement.ps1) imports this one manifest; PowerShell then
    # loads all seven .psm1 files as nested modules and merges their exports
    # into the top-level scope. This avoids the "first-imported module's
    # exports get orphaned when a later module re-imports it" trap that
    # happens with seven separate path-based Import-Module calls in a row.
    RootModule        = ''
    ModuleVersion     = '1.0.0'
    GUID              = '59d8d060-de68-48d9-83dd-d5495a22ebf3'
    Author            = 'DSC Orchestrator contributors'
    Description       = 'DSC Orchestrator enforcement runtime.'
    PowerShellVersion = '5.1'

    NestedModules = @(
        'Dsc.HostContext.psm1',
        'Dsc.ResultProjection.psm1',
        'Dsc.ConfigFilter.psm1',
        'Dsc.Lifecycle.psm1',
        'Dsc.Diagnostics.psm1',
        'Dsc.Native.psm1',
        'Dsc.Recovery.psm1',
        'Dsc.Reasons.psm1',
        'Dsc.YamlLines.psm1',
        'Dsc.JsonLog.psm1',
        'Dsc.Reboot.psm1',
        'Dsc.RebootRequest.psm1'
    )

    FunctionsToExport = @(
        # Dsc.HostContext
        'Get-ConfigVersion','Get-ConfigMetadata','Get-DscExeVersion','Get-HostIdentity','Write-NativeStderr',
        # Dsc.ResultProjection
        'Get-NestedProperty','Test-IsDscAdapterWrapper','ConvertFrom-DscTestJson','Get-PowerShellAdapterCompliance',
        'New-ResourceReason','Join-ResourceReasonPhrases','Resolve-ResourceDuration',
        'Get-PowerShellAdapterInnerResources','New-ResourceActionMap',
        'Get-RealResourceSummary','Get-ResourceCompliance','Get-FragmentBucketCounts','Test-ParsedTestHadResourceErrors',
        # Dsc.ConfigFilter
        'Get-DriftedTopLevelResourceNames','Get-WrapperDependsOnNames','New-FilteredConfigForResources',
        'New-StrippedConfigExcludingResources','Get-WrapperInnerTypeMap',
        # Dsc.Lifecycle
        'Write-SetLifecycleEvent','New-SetLifecycleCallback','New-TimingCallback',
        # Dsc.Diagnostics
        'Find-DscErrorSignal',
        # Dsc.Native
        'Invoke-DscNative','Invoke-DscTestJson','Invoke-DscSet','Invoke-DscGetJson',
        # Dsc.Recovery (always-on strip-and-retry; see PowerShell/DSC#656 removal runbook)
        'Invoke-FragmentConvergence',
        # Dsc.Reasons
        'Get-ReasonsFromProperties','Get-PowerShellAdapterInnerReasons','Write-LastFailures',
        # Dsc.YamlLines
        'Get-DeclaredResources',
        # Dsc.JsonLog
        'Write-JsonLine','Rotate-LogFile','Write-ResourceRecords','Write-FinalStateResourceRecords','Write-RunSummary',
        'New-ResourceRecord','Write-ResourceRecord','Write-FragmentUnevaluatedRows','Write-FragmentSkippedRows','Write-FragmentRebootUnreachedRows',
        # Dsc.Reboot (orchestrator-owned reboot handling)
        'Get-CanonicalBootId','Publish-DscRebootContext','Read-DscRebootRequests','Clear-DscRebootRequests',
        'Test-OrchestratorRebootResume','Set-DscRestartStateConsumed','Invoke-OrchestratorRebootLatch','Remove-DscRestartState',
        'Invoke-OrchestratorRebootFinalize','Request-DscReboot'
    )
    CmdletsToExport = @()
    # Back-compat alias for the renamed Invoke-FragmentConvergence.
    AliasesToExport = @()
    VariablesToExport = @()
}
