@{
    # Aggregate manifest for the fragment-renderer module split.
    # New-DSCv3PreparedFragments.ps1 imports this manifest; PowerShell loads
    # the listed .psm1 files as nested modules and merges their exports into
    # the entry script's scope. Single Import-Module avoids the
    # cascade-orphaned-export trap (see ps-aggregate-manifest-not-import-cascade
    # skill).
    #
    # Helpers render the DSCv3 document line-by-line on purpose to avoid the
    # render-token mis-parse that powershell-yaml / yq exhibit on unquoted
    # whole-scalar `{{ ParameterName }}` tokens. The Emit / Validate / Assemble
    # split preserves that line-based contract — none of these modules calls
    # into a YAML serialiser.
    RootModule        = ''
    ModuleVersion     = '1.0.0'
    GUID              = '1e20e2e4-43ad-40d7-abe0-19f2cde59dc2'
    Author            = 'DSC Orchestrator contributors'
    Description       = 'DSC Orchestrator fragment renderer.'
    PowerShellVersion = '5.1'

    NestedModules = @(
        'Dsc.Prepare.Emit.psm1',
        'Dsc.Prepare.Parse.psm1',
        'Dsc.Prepare.Assemble.psm1',
        'Dsc.Prepare.Validate.psm1',
        'Dsc.Prepare.Dependencies.psm1'
    )

    FunctionsToExport = @(
        # Dsc.Prepare.Emit
        'ConvertTo-YamlScalar','Invoke-DSCv3ParameterRendering',
        # Dsc.Prepare.Parse
        'Get-RenderParameterMap',
        # Dsc.Prepare.Assemble
        'Get-TopLevelResourcesBlock','Get-ResourceIdentifier',
        # Dsc.Prepare.Validate
        'Assert-NoUnresolvedToken','Assert-NoUnsupportedYamlFeature',
        'Assert-RenderTokensAreWholeScalars','Assert-PerResourceWrapperStructure',
        # Dsc.Prepare.Dependencies
        'Get-FragmentDependencies','Assert-DependsOnShape','Test-DependencyCycle'
    )
    CmdletsToExport   = @()
    AliasesToExport   = @()
    VariablesToExport = @()
}
