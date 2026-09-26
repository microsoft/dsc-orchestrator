@{
    # Aggregate manifest for the publisher helper modules.
    # Publish-DSCv3VMApp.ps1 imports this one manifest; PowerShell loads every
    # listed .psm1 as a nested module and merges their exports into the entry
    # script's scope. Single Import-Module avoids the cascade trap where a
    # second top-level path-import re-classifies an already-loaded sibling as
    # nested and orphans its exports.
    RootModule        = ''
    ModuleVersion     = '1.0.0'
    GUID              = 'cbd8927a-d6a9-4dbc-9006-7f91dc9cb6a1'
    Author            = 'DSCv3 Orchestrator Contributors'
    Description       = 'Azure Compute Gallery VM Application publishing helpers.'
    PowerShellVersion = '5.1'

    NestedModules = @(
        'Dsc.Publish.Blob.psm1',
        'Dsc.Publish.GalleryRbac.psm1',
        'Dsc.Publish.GalleryApp.psm1'
    )

    FunctionsToExport = @(
        # Dsc.Publish.Blob
        'Test-BlobUri','Invoke-PackageUpload','Invoke-PackageUploadWithAzureCli',
        # Dsc.Publish.GalleryRbac
        'Assert-GalleryManagedIdentityBlobAccess',
        # Dsc.Publish.GalleryApp
        'ConvertTo-VMApplicationPackageCommand','ConvertTo-VMApplicationRemoveCommand',
        'Get-ExistingGalleryApplicationVersion','Ensure-GalleryApplication','New-DscV3GalleryApplicationVersion'
    )
    CmdletsToExport   = @()
    AliasesToExport   = @()
    VariablesToExport = @()
}
