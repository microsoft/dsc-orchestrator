# Pipelines

`ci.yaml` declares triggers for pushes to `main` and pull requests targeting
`main`, using only the public `windows-latest` hosted agent. A matrix runs the
same CI script under Windows PowerShell 5.1 and PowerShell 7. Azure Repos Git
requires PR build validation to be configured as a branch policy when the
pipeline is registered; it does not use YAML `pr:` triggers.

The pipeline installs pinned Pester 5.7.1, PSScriptAnalyzer 1.25.0, and
`powershell-yaml` 0.4.12 from PSGallery when needed, analyzes PowerShell files
under `src/`, and runs `*.Tests.ps1` files under `tests/`. NUnit test results
and JaCoCo coverage are published when generated. An empty source or test tree
is logged and skipped.

Run the same checks locally from the repository root:

```powershell
pwsh -NoProfile -File .\build\Invoke-CI.ps1
```

To check Windows PowerShell 5.1 as well, run:

```powershell
powershell.exe -NoProfile -File .\build\Invoke-CI.ps1
```

The script installs the pinned modules into the current user's module scope
only when the required versions are unavailable. Local reports are written to
a unique directory under the system temporary directory.

## Release pipeline example

[`examples/pipelines/azure-vmapp-release.yaml`](../examples/pipelines/azure-vmapp-release.yaml) is a manual, Windows-hosted release flow with three stages:

1. **Build** calls the one-command `build/New-DscOrchestratorPackage.ps1` wrapper to prepare fragments, stage resource modules, download the pinned DSC and PowerShell tools, create the package ZIP, and publish only that ZIP as a pipeline artifact. The call is isolated in [`templates/build-package.yaml`](templates/build-package.yaml) and passes `-ConfigPath`, `-OutputPath`, and `-RepositoryName`. It installs `powershell-yaml` 0.4.12 from PSGallery. `resourceModuleRepositoryName` defaults to `PSGallery`; callers own registration and authentication for any private module feed.

   The local build command matches the [quickstart](../docs/quickstart.md):

   ```powershell
   pwsh -NoProfile -File .\build\New-DscOrchestratorPackage.ps1 -ConfigPath .\examples\basic\dsc-orchestrator.config.json -OutputPath .\out
   ```
2. **Publish** downloads the ZIP, reads `manifest.json` from its root, and passes that manifest version to `Publish-DSCv3VMApp.ps1`. A blank `targetRegions` value lets the adapter discover regions from `targetResourceGroup`; the source region is included automatically. The caller's Azure context is supplied by `AzurePowerShell@5` through `azureServiceConnection`; `subscription` is an optional assertion and never switches context.
3. **Deploy** passes the version resource ID returned by Publish to `Deploy-DSCv3VMApp.ps1`. `vmNames` is an optional comma-separated list; when blank, every VM in `targetResourceGroup` is selected. An empty VM resource group is logged and skipped by the adapter. Both Azure tasks set `FailOnStandardError: false`, so warnings from that successful skip are not treated as failures.

The example uses no internal pool, private feed, or hard-coded service connection and has `trigger: none`. It uses the public `windows-latest` hosted agent and PSGallery. Set these queue-time parameters:

| Parameter | Use |
| --- | --- |
| `configPath` | Orchestrator config path; defaults to `examples/basic/dsc-orchestrator.config.json`. |
| `azureServiceConnection` | Required name of an Azure Resource Manager service connection authorized for the pipeline. |
| `subscription` | Optional subscription ID to assert against the service connection's active context. |
| `resourceModuleRepositoryName` | Registered PowerShell repository name; defaults to `PSGallery`. Private feed setup stays with the caller. |
| `storageAccountName`, `storageAccountResourceGroup`, `containerName` | Package blob destination. |
| `galleryResourceGroup`, `galleryName`, `applicationName` | Azure Compute Gallery destination. A blank gallery resource group defaults to the storage account resource group. |
| `sourceRegion`, `targetRegions` | Gallery source region and optional comma-separated replication regions. |
| `targetResourceGroup` | VM resource group used for region discovery and deployment. |
| `vmNames` | Optional comma-separated VM names within `targetResourceGroup`; blank targets all VMs. |

Grant the identity behind the service connection:

- **Package storage:** `Storage Blob Data Contributor` on the storage account (or package container after it exists) to create the private container and upload the ZIP.
- **Gallery publication:** `Contributor` on the gallery resource group, or a custom role with the gallery/application/version read and write actions described in the [adapter permissions](../src/adapters/delivery/azure-vmapp/README.md#azure-permissions). The pipeline uses the adapter's safe `IfExists=Fail` behavior and does not need version deletion rights.
- **Target VMs:** `Virtual Machine Contributor` on `targetResourceGroup` for VM reads and application-profile updates. Publishing also reads this resource group to discover VM regions when `targetRegions` is blank.

The gallery's managed identity separately needs `Storage Blob Data Reader` on the package container. Pre-enable that identity and grant the data role to avoid giving the pipeline identity `Microsoft.Authorization/roleAssignments/write`; if the adapter configures it, the pipeline identity also needs `Microsoft.Compute/galleries/write` and `Microsoft.Authorization/roleAssignments/write` at the required scopes. See the [adapter prerequisites and permissions](../src/adapters/delivery/azure-vmapp/README.md#azure-permissions).

To register the example in Azure DevOps, create a YAML pipeline from the repository and select `examples/pipelines/azure-vmapp-release.yaml`. Authorize the selected Azure Resource Manager service connection for that pipeline, then queue a manual run with the parameters above. No pipeline definition or service connection is created by this example.
