# Azure VM Application delivery

This adapter publishes package ZIPs as Azure Compute Gallery VM Application versions, assigns a selected version to Windows VMs, reads the latest published version, and prunes old unassigned versions. It doesn't build packages; use the core builder for that.

## Prerequisites

- Windows PowerShell 5.1 or PowerShell 7.
- Caller-installed Az PowerShell modules: Az.Accounts 2.13.0 or later, Az.Compute 7.1.1 or later, Az.Storage 6.0.0 or later, and Az.Resources. Use compatible module versions. The optional gallery-version-level `TreatFailureAsDeploymentFailure` parameter depends on the parameters exposed by the installed Az.Compute version; see [Deployment failure reporting](#deployment-failure-reporting).
- An existing Az PowerShell context selected by the caller. The scripts do not sign in or switch subscriptions. `-SubscriptionId` is an optional assertion against the active context.
- Azure CLI is optional. It is used only as an upload fallback when the Az context uses an access token that Az.Storage cannot use; the CLI must already have a usable sign-in.

The Az modules and Azure CLI are runtime prerequisites only; this repository does not bundle them. Pester tests mock Azure cmdlets and do not require Azure authentication or network access.

## Inputs from the core package

`Publish-DSCv3VMApp.ps1` accepts these explicit package identity inputs:

| Input | Contract |
| --- | --- |
| `PackagePath` | Core builder ZIP named `dsc-orchestrator-<name>-<version>.zip`, with root `manifest.json`, `Install-VmApplicationPackage.ps1`, `bootstrap.ps1`, and `remove.ps1`. The publisher reads the manifest and rejects unsupported schemas or missing entry points. |
| `Version` | Explicit numeric `major.minor.patch` version, such as `1.4.0`; it must match `manifest.json.version`. |
| `ApplicationName` | Explicit caller-provided application name. The adapter normalizes it to lowercase Azure-safe characters and limits it to 80 characters. Use the returned `ApplicationName` for subsequent calls. |

Azure is told to use the ZIP's leaf filename as `PackageFileName`; the generated commands resolve that same local filename and extract `Install-VmApplicationPackage.ps1` or `remove.ps1` from the ZIP. Install/update invoke the core entry point with `-PackageArchivePath`, `-Version`, and `-DscRoot`; update also passes `-Update`. The installer extracts the archive, checks its manifest, then invokes `bootstrap.ps1 -PackageRoot`. The remove action invokes the packaged `remove.ps1` with the same install root.

Azure runs an app's remove command only when other VM Applications stay on the VM. If DSC Orchestrator is the last one, Azure removes the VM Application extension instead and the remove command never runs. Run `remove.ps1` yourself first, as shown in [Clean up](../../../../docs/quickstart.md#clean-up).

`Publish-DSCv3VMApp.ps1 -DscRoot` defaults to `C:\ProgramData\DscOrchestrator`, matching the Windows agent. Override it only when the install, update, and remove actions must all target a non-default root.

## Azure permissions

Grant permissions to the identity represented by the caller's active Az context:

- **Publish:** `Storage Blob Data Contributor` on the storage account to create the private container and upload package blobs. Uploads use Entra ID; there is no shared-key fallback. The caller also needs read/write access to the Compute Gallery application and application version, and read access to target VMs if `VMResourceGroupName` is used for region discovery. `-IfExists Force` and version cleanup also require deleting gallery application versions.
- **Gallery access to the package:** the gallery managed identity needs `Storage Blob Data Reader` on the package container. The publisher verifies this and can enable a system-assigned gallery identity and grant the role. To avoid giving the publisher role-assignment permissions, pre-enable the gallery identity and grant this data role before publishing.
- **Automatic identity/RBAC setup:** if the publisher must enable the gallery identity, its caller needs `Microsoft.Compute/galleries/write`. If it must grant the identity access to storage, its caller needs `Microsoft.Authorization/roleAssignments/write` at the storage account or container scope.
- **Deploy:** read the gallery version and target resource group/VMs, and update the target VMs' application profiles (`Microsoft.Compute/virtualMachines/read` and `write`). Retry verification also reads VM instance view/status.
- **Cleanup:** read VM application profiles and gallery applications/versions, and delete eligible old versions. Assignments are checked across every VM in `VMResourceGroupName` before any deletion; the script fails closed if it cannot determine that set.

Use the narrowest resource scopes that satisfy these actions. The adapter never changes the caller's selected context.

## Deployment failure reporting

Az.Compute 10.2.0 lacks the gallery-version `TreatFailureAsDeploymentFailure` parameter. Deploy still sets `treatFailureAsDeploymentFailure` on each VM's assignment, where Azure applies it (seen in testing). Whether a failing install fails the deployment wasn't tested, so check each VM after deploying (see [Verify on the VM](../../../../docs/quickstart.md#step-6-verify-on-the-vm)).

## Usage

Publish a package:

```powershell
$published = .\src\adapters\delivery\azure-vmapp\Publish-DSCv3VMApp.ps1 `
    -PackagePath .\artifacts\dsc-orchestrator-sample-configuration-1.4.0.zip `
    -StorageAccountName sampleacct `
    -StorageAccountResourceGroup storage-rg `
    -ContainerName packages `
    -GalleryName gallery `
    -GalleryResourceGroup gallery-rg `
    -ApplicationName sample-agent `
    -Version 1.4.0 `
    -Location eastus `
    -DscRoot 'D:\Orchestrator' `
    -TargetRegions @('eastus', 'westus2') `
    -IfExists Skip

$published | Format-List
```

`GalleryResourceGroup` defaults to `StorageAccountResourceGroup`. `Location` is required and sets the VM Application `sourceRegion`; it must match the storage account's region. If `TargetRegions` is omitted, `VMResourceGroupName` can be used to discover target VM regions; an empty resource group or no target resource group publishes to the source region only. With `-IfExists Skip`, an existing gallery version is returned without comparing package contents; publish changed content under a new package version.

Deploy to named VMs, or omit `VMNames` to target every VM in the resource group:

```powershell
$deployment = .\src\adapters\delivery\azure-vmapp\Deploy-DSCv3VMApp.ps1 `
    -ResourceGroupName workload-rg `
    -VMNames @('vm01', 'vm02') `
    -VMAppVersionResourceId $published.VMAppVersionId `
    -WhatIf
```

The deploy adapter supports a resource group with optional VM names; VM scale sets and tag-based selection are not implemented. An empty target resource group logs a skip and returns successfully with `Skipped = $true`.

Read the latest version and prune old unassigned versions:

```powershell
$latest = .\src\adapters\delivery\azure-vmapp\Get-DSCv3LatestVMAppVersion.ps1 `
    -GalleryName gallery `
    -GalleryResourceGroup gallery-rg `
    -ApplicationName sample-agent

.\src\adapters\delivery\azure-vmapp\Remove-OldDscV3GalleryVersions.ps1 `
    -GalleryName gallery `
    -GalleryResourceGroup gallery-rg `
    -ApplicationName $latest.ApplicationName `
    -VMResourceGroupName workload-rg `
    -KeepNewestCount 2 `
    -WhatIf
```

`Remove-OldDscV3GalleryVersions.ps1` always retains the newest semantic versions and every assigned version. An empty VM resource group logs a skip and returns successfully. Deletion failures are reported and do not stop cleanup of other eligible versions.

## Outputs and behavior

- Publish returns an object with `ApplicationName`, `Version`, `VMAppVersionId`, `Action`, and `BlobUri`.
- Latest-version lookup returns `ApplicationName`, `Version`, and `VMAppVersionId`.
- Deployment returns the resource group, version resource ID, updated VM count, selected VM names, and skip status.
- Azure DevOps output variables are emitted only when `TF_BUILD` is `True`; the objects are the neutral output contract.
- `-WhatIf` and `-Confirm` are supported for mutating operations. `-IfExists Force` deletes and recreates an immutable version and should be used deliberately.
