# Quickstart

Build the checked-in sample locally first; step 1 does not need Azure. Then publish it as an Azure Compute Gallery VM Application, deploy it to one Windows VM, and verify enforcement.

## Prerequisites

### Local package build

- PowerShell 7 (`pwsh`). The package builder explicitly rejects PowerShell 5.1.
- The `powershell-yaml` module in the same PowerShell 7 environment. CI and release builds use version 0.4.12.
- HTTPS access to PSGallery and the pinned DSC and PowerShell GitHub release downloads.

Install the build module from PowerShell 7:

```powershell
Install-Module -Name powershell-yaml -RequiredVersion 0.4.12 -Scope CurrentUser -Repository PSGallery -Force
```

The builder checks that the module is available; it does not enforce a version. Use 0.4.12 to match CI and release builds.

### Publish and deploy

- Az PowerShell modules installed in the environment used to publish and deploy.
- A selected Azure subscription. Create the Compute Gallery, storage account, and package container before publishing.
- An x64 Windows Server 2019 or later, or Windows 11 (tested on Windows 11 25H2), with a healthy Azure VM Agent and `tar.exe`.
- Resources from PowerShell DSC modules such as `PSDscResources` that run through the `Microsoft.Windows/WindowsPowerShell` adapter need the WinRM service running. WinRM is on by default on Windows Server and off by default on Windows 11.

The Azure end-to-end test used Windows 11 Pro 25H2 (build 26200), Trusted Launch, a healthy Azure VM Agent, and no public IP. Windows Server was not tested.

The blocks below assume you keep one PowerShell 7 session open from the repository root for steps 1-5. Run step 6 in an elevated PowerShell session on the target VM.

## Step 1: Build the sample package

This command downloads the pinned DSC and PowerShell runtimes, validates the sample, and creates a ZIP in a unique temporary directory.

```powershell
$packageOutput = Join-Path $env:TEMP ('dsc-orchestrator-quickstart-' + [guid]::NewGuid().ToString('N'))
$package = .\build\New-DscOrchestratorPackage.ps1 -ConfigPath .\examples\basic\dsc-orchestrator.config.json -OutputPath $packageOutput
$package | Format-List Name, Version, PackagePath
```

You should see `Name: basic-sample`, `Version: 1.0.0`, and a `PackagePath` ending in `dsc-orchestrator-basic-sample-1.0.0.zip`. The builder returns the ZIP path in `$package.PackagePath`.

The sample uses the built-in `Microsoft.Windows/Registry` resource; no extra resource module is needed. It sets `HKLM:\SOFTWARE\DscOrchestratorSample\ManagedBy` to `DSC Orchestrator sample`. See the [basic example guide](../examples/basic/README.md).

## Step 2: Sign in to Azure

Set the subscription in which you will create or use the gallery and storage account:

```powershell
$subscriptionId = '<subscription-id>'
Connect-AzAccount
Set-AzContext -SubscriptionId $subscriptionId
Get-AzContext | Select-Object Account, Subscription
```

You should see the intended account and subscription. The Orchestrator scripts use the current Az context; they do not sign in or switch subscriptions for you.

## Step 3: Create the Azure resources

Skip this step if you already have a Compute Gallery, storage account, and container.

The publish step needs a Compute Gallery, a Storage Account, and a private package container. The gallery and storage account must be in the same region. This example creates them in one resource group. Gallery names allow letters, numbers, periods, and underscores, but not hyphens. Storage Account names must be 3–24 lowercase letters and numbers, and globally unique.

The signed-in identity must be allowed to create these resources and role assignments. Use the same `$location` for the gallery and storage account:

```powershell
$resourceGroupName = '<resource-group-name>'
$location = '<azure-region>'
$storageAccountName = '<unique-storage-account-name>'
$galleryName = '<gallery_name>'
$containerName = 'packages'

New-AzResourceGroup -Name $resourceGroupName -Location $location
$storageAccount = New-AzStorageAccount `
    -ResourceGroupName $resourceGroupName `
    -Name $storageAccountName `
    -Location $location `
    -SkuName Standard_LRS `
    -Kind StorageV2 `
    -AllowBlobPublicAccess $false
New-AzGallery -ResourceGroupName $resourceGroupName -Name $galleryName -Location $location
New-AzRoleAssignment `
    -SignInName (Get-AzContext).Account.Id `
    -RoleDefinitionName 'Storage Blob Data Contributor' `
    -Scope $storageAccount.Id
```

After the role assignment has propagated, create the private container using the signed-in identity:

```powershell
$storageContext = New-AzStorageContext -StorageAccountName $storageAccountName -UseConnectedAccount
New-AzStorageContainer -Name $containerName -Context $storageContext
```

Use these resource names and region for the placeholders in Step 4.

## Permissions

Use compatible Az modules in the PowerShell environment that runs the delivery scripts. Az.Resources: any recent version.

| Module | Minimum version |
| --- | --- |
| Az.Accounts | 2.13.0 |
| Az.Compute | 7.1.1 (8.x or later recommended) |
| Az.Storage | 6.0.0 |

The active Az identity needs:

- `Storage Blob Data Contributor` on the Storage Account to create the package container and upload the ZIP. Uploads use Entra ID; there is no shared-key fallback.
- `Contributor` on the Compute Gallery resource group to publish the application and version.
- `Virtual Machine Contributor` on the target VM resource group to deploy the application.

The gallery's managed identity needs `Storage Blob Data Reader` on the package container. Preconfigure that identity and role to avoid granting the publishing identity permission to change gallery identity or role assignments. For exact actions, scopes, and optional setup permissions, see the [Azure VM Application adapter permissions](../src/adapters/delivery/azure-vmapp/README.md#azure-permissions).

## Step 4: Publish the package

Replace the placeholders with your resource names. `Location` must be the Storage Account's Azure region; include the target VM's region in `TargetRegions`. The source region is added automatically.

```powershell
$publishParameters = @{
    PackagePath = $package.PackagePath
    StorageAccountName = '<storage-account-name>'
    StorageAccountResourceGroup = '<storage-account-resource-group>'
    ContainerName = 'packages'
    GalleryName = '<gallery-name>'
    GalleryResourceGroup = '<gallery-resource-group>'
    ApplicationName = 'dsc-orchestrator-basic'
    Version = $package.Version
    Location = '<storage-account-region>'
    TargetRegions = @('<target-region>')
    IfExists = 'Skip'
}
$published = .\src\adapters\delivery\azure-vmapp\Publish-DSCv3VMApp.ps1 @publishParameters
$published | Format-List ApplicationName, Version, VMAppVersionId, Action
```

You should see application `dsc-orchestrator-basic`, version `1.0.0`, a gallery version resource ID, and `Action` set to `published` or `skipped`. `IfExists = 'Skip'` reuses an existing version without comparing package contents. If the configuration changes, update `version` in `examples/basic/dsc-orchestrator.config.json` and rebuild before publishing.

## Step 5: Deploy to one VM

```powershell
$deployParameters = @{
    ResourceGroupName = '<vm-resource-group>'
    VMNames = @('<windows-server-vm-name>')
    VMAppVersionResourceId = $published.VMAppVersionId
}
$deployment = .\src\adapters\delivery\azure-vmapp\Deploy-DSCv3VMApp.ps1 @deployParameters
$deployment | Format-List
```

The update can take several minutes while Azure applies the VM Application. On success, the result should show `VmCount: 1`, your VM name, and `Skipped: False`.

The agent starts enforcement immediately during installation. Let that first run finish before checking the sample registry value or starting another run.

## Step 6: Verify on the VM

The default install root is `C:\ProgramData\DscOrchestrator`. The agent registers the `DscOrchestrator-Enforcement` scheduled task, which runs every 15 minutes.

In an elevated PowerShell session on the VM, check that the task exists and the sample value was set:

```powershell
Get-ScheduledTask -TaskName 'DscOrchestrator-Enforcement' | Select-Object TaskName, State
(Get-ItemProperty -Path 'HKLM:\SOFTWARE\DscOrchestratorSample' -Name 'ManagedBy').ManagedBy
```

You should see the task and the value `DSC Orchestrator sample`.

To force a run after the current run has finished:

```powershell
Start-ScheduledTask -TaskName 'DscOrchestrator-Enforcement'
```

Run and resource results are written as JSON Lines under `C:\ProgramData\DscOrchestrator\logs`:

- `runs.jsonl` contains run summaries.
- `resources.jsonl` contains per-resource results.
- `bootstrap.jsonl` contains install diagnostics.

Read the latest entries as JSON objects:

```powershell
$logRoot = 'C:\ProgramData\DscOrchestrator\logs'
Get-Content -LiteralPath (Join-Path $logRoot 'runs.jsonl') -Tail 1 | ConvertFrom-Json | Format-List
Get-Content -LiteralPath (Join-Path $logRoot 'resources.jsonl') -Tail 1 | ConvertFrom-Json | Format-List
Get-Content -LiteralPath (Join-Path $logRoot 'bootstrap.jsonl') -Tail 1 | ConvertFrom-Json | Format-List
```

Run and resource records include `group`, `role`, and `configuration_hash`.

## Update to a new version

Change the top-level `version` in `examples/basic/dsc-orchestrator.config.json` and update the desired value in `examples/basic/fragments/baseline.dsc.yaml`. Use a new version for every content change because gallery versions are immutable. In the same PowerShell session used for Steps 1-5, rebuild, publish, and deploy:

```powershell
$packageOutput = Join-Path $env:TEMP ('dsc-orchestrator-update-' + [guid]::NewGuid().ToString('N'))
$package = .\build\New-DscOrchestratorPackage.ps1 -ConfigPath .\examples\basic\dsc-orchestrator.config.json -OutputPath $packageOutput
$package | Format-List Name, Version, PackagePath
$publishParameters.PackagePath = $package.PackagePath
$publishParameters.Version = $package.Version
$published = .\src\adapters\delivery\azure-vmapp\Publish-DSCv3VMApp.ps1 @publishParameters
$published | Format-List ApplicationName, Version, VMAppVersionId, Action
$deployParameters.VMAppVersionResourceId = $published.VMAppVersionId
$deployment = .\src\adapters\delivery\azure-vmapp\Deploy-DSCv3VMApp.ps1 @deployParameters
$deployment | Format-List
```

On the VM, confirm the new version:

```powershell
(Get-Content -LiteralPath 'C:\ProgramData\DscOrchestrator\current\manifest.json' -Raw | ConvertFrom-Json).version
```

## Clean up

Azure runs an app's remove command only when other VM Applications stay on the VM. If DSC Orchestrator is the last VM Application on the VM, Azure removes the VM Application extension instead, and the remove command never runs, so the scheduled task and runtime stay and keep enforcing. To be safe, always run remove.ps1 yourself first, as shown below.

1. Before removing the assignment, on the VM in an elevated PowerShell session, extract and run `remove.ps1` from the downloaded package. Replace `<application-name>` and `<version>` with the values from publish:

   ```powershell
   $zip = Get-ChildItem 'C:\Packages\Plugins\Microsoft.CPlat.Core.VMApplicationManagerWindows\*\Downloads\<application-name>\<version>\*.zip' | Select-Object -First 1
   $extractDir = Join-Path $env:TEMP 'dsc-orchestrator-remove'
   New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
   tar.exe -xf $zip.FullName -C $extractDir remove.ps1
   & (Join-Path $extractDir 'remove.ps1')
   Remove-Item -LiteralPath $extractDir -Recurse -Force
   ```

   remove.ps1 unregisters the scheduled task and removes the `current` and `staging` folders. Logs are kept. Add `-Purge` to remove logs too.

2. Remove the VM Application assignment. In the PowerShell 7 session:

   ```powershell
   $vm = Get-AzVM -ResourceGroupName '<vm-resource-group>' -Name '<windows-server-vm-name>'
   $remaining = @($vm.ApplicationProfile.GalleryApplications | Where-Object { $_.PackageReferenceId -notmatch '/applications/dsc-orchestrator-basic/' })
   $vm.ApplicationProfile.GalleryApplications.Clear()
   foreach ($app in $remaining) { $vm.ApplicationProfile.GalleryApplications.Add($app) }
   Update-AzVM -ResourceGroupName '<vm-resource-group>' -VM $vm
   ```

3. Removing the assignment does not undo the sample registry setting. In elevated PowerShell on the VM, remove only the sample key:

   ```powershell
   Remove-Item -LiteralPath 'HKLM:\SOFTWARE\DscOrchestratorSample' -Recurse -Force
   ```

4. On the build machine, remove the temporary package directory when you no longer need it:

   ```powershell
   Remove-Item -LiteralPath $packageOutput -Recurse -Force
   ```

Delete the gallery version and package blob separately only after confirming the version is no longer assigned to a VM.

## Troubleshooting

- **Enforcement keeps running after you remove the app:** Orchestrator was the last VM Application on the VM, so Azure removed the VM Application extension without running the remove command. Run remove.ps1 as shown in [Clean up](#clean-up).
- **Package install cannot extract the ZIP:** the VM Application installer uses `tar.exe`. Check that it is available on the VM with `Get-Command tar.exe`.
- **Publish fails on `Location`:** `-Location` must match the Storage Account's region. Use `TargetRegions` for gallery replication destinations.
- **Changed content is not published:** gallery versions are immutable. Increment the config `version`, rebuild the ZIP, and publish the new version.
- **DSC reports `Access is denied`:** run manual `dsc` commands and verification from an elevated PowerShell session. The resource writes under `HKLM`, which requires administrator rights.
- **A PowerShell DSC resource reports a WS-Management or WinRM connection error:** WinRM must be running for resources that use the `Microsoft.Windows/WindowsPowerShell` adapter. In an elevated PowerShell session, run:

  ```powershell
  Set-Service -Name WinRM -StartupType Automatic
  Start-Service -Name WinRM
  ```

- **WSMan inspection hangs in a non-interactive session:** do not browse the `WSMan:\` drive while WinRM is stopped. PowerShell prompts to start WinRM, which can hang sessions such as Azure Run Command.
- **Publish warns about `TreatFailureAsDeploymentFailure`:** Az.Compute 10.2.0 lacks the gallery-version `TreatFailureAsDeploymentFailure` parameter. Deploy still sets `treatFailureAsDeploymentFailure` on each VM's assignment, where Azure applies it (seen in testing). Whether a failing install fails the deployment wasn't tested, so check each VM after deploying (see [Verify on the VM](#step-6-verify-on-the-vm)).
