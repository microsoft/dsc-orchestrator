# Advanced example

This example exercises multiple configuration fragments, module packaging, resource ordering, and scalar parameters. It makes only these changes:

- `registry-base` writes several values under `HKLM:\SOFTWARE\DscOrchestratorSampleAdvanced`. Registry resources use `dependsOn` so the baseline value is applied before the parameterized release label and the dependent option.
- `machine-environment` uses `PSDscResources` 2.12.0 through DSC v3's `Microsoft.Windows/WindowsPowerShell` adapter to set the machine environment variable `DSC_ORCHESTRATOR_SAMPLE=advanced`. It depends on `registry-base`.
- `registry-verification` writes a completion value under the same dedicated registry key and depends on `machine-environment`.

The config sets `group=advanced-example`, `role=test-host`, and renders the `RegistryReleaseLabel` parameter into the registry fragment. Fragment dependencies are declared in `metadata.platform.dependsOn`; the package manifest preserves the declared fragment order and dependency gate.

## Prerequisite: WinRM

The `machine-environment` fragment uses PSDscResources through the Windows PowerShell adapter, which needs the WinRM service running. It's on by default on Windows Server and off by default on Windows 11. To enable it, run in an elevated PowerShell session:

```powershell
Set-Service -Name WinRM -StartupType Automatic
Start-Service -Name WinRM
```

## Build, publish, and deploy

Use the same PowerShell 7 session, Azure context, gallery, storage account, and permissions as the [quickstart](../../docs/quickstart.md). Run these commands from the repository root:

```powershell
$packageOutput = Join-Path $env:TEMP ('dsc-orchestrator-advanced-' + [guid]::NewGuid().ToString('N'))
$package = .\build\New-DscOrchestratorPackage.ps1 -ConfigPath .\examples\advanced\dsc-orchestrator.config.json -OutputPath $packageOutput
$package | Format-List Name, Version, PackagePath
```

You should see `Name: advanced-sample`, `Version: 1.0.1`, and a ZIP `PackagePath`.

The package declares the exact PSGallery module pin `PSDscResources` 2.12.0. The builder normalizes the PSGallery version `2.12.0.0` to the config's three-part pin and bundles that resource module with the package. `PSDscResources/Environment` is a Windows PowerShell DSC resource, so this example uses the Windows PowerShell adapter rather than the class-based `Microsoft.DSC/PowerShell` adapter.

Publish as a separate VM Application so the quickstart's basic application remains independent:

```powershell
$publishParameters = @{
    PackagePath = $package.PackagePath
    StorageAccountName = '<storage-account-name>'
    StorageAccountResourceGroup = '<storage-account-resource-group>'
    ContainerName = 'packages'
    GalleryName = '<gallery-name>'
    GalleryResourceGroup = '<gallery-resource-group>'
    ApplicationName = 'dsc-orchestrator-advanced'
    Version = $package.Version
    Location = '<storage-account-region>'
    TargetRegions = @('<target-region>')
    IfExists = 'Skip'
}
$published = .\src\adapters\delivery\azure-vmapp\Publish-DSCv3VMApp.ps1 @publishParameters
$published | Format-List ApplicationName, Version, VMAppVersionId, Action
```

You should see application `dsc-orchestrator-advanced`, version `1.0.1`, and `Action: published`.

Deploy it to one Windows VM:

```powershell
$deployParameters = @{
    ResourceGroupName = '<vm-resource-group>'
    VMNames = @('<windows-server-vm-name>')
    VMAppVersionResourceId = $published.VMAppVersionId
}
$deployment = .\src\adapters\delivery\azure-vmapp\Deploy-DSCv3VMApp.ps1 @deployParameters
$deployment | Format-List
```

You should see `VmCount: 1`, VM `<windows-server-vm-name>`, and `Skipped: False`. Wait for the VM Application installation and its first enforcement run to finish before verifying values.

## Verify on the VM

After the VM Application install succeeds, run these checks in elevated PowerShell on the VM or through Azure VM Run Command.

### `registry-base`

```powershell
$sampleRoot = 'HKLM:\SOFTWARE\DscOrchestratorSampleAdvanced'
(Get-ItemProperty -LiteralPath $sampleRoot -Name Baseline).Baseline
(Get-ItemProperty -LiteralPath $sampleRoot -Name ReleaseLabel).ReleaseLabel
(Get-ItemProperty -LiteralPath (Join-Path $sampleRoot 'Options') -Name Enabled).Enabled
```

You should see `DSC Orchestrator advanced`, `advanced-v1`, and `1`. The `advanced-v1` value proves that the `RegistryReleaseLabel` parameter was rendered.

### `machine-environment`

```powershell
[Environment]::GetEnvironmentVariable('DSC_ORCHESTRATOR_SAMPLE', 'Machine')
```

You should see `advanced`.

### `registry-verification`

```powershell
$sampleRoot = 'HKLM:\SOFTWARE\DscOrchestratorSampleAdvanced'
(Get-ItemProperty -LiteralPath $sampleRoot -Name Verification).Verification
```

You should see `DSC Orchestrator advanced is ready`.

Check the latest run, compare its hash with `current\metadata.json`, and list that run's resource rows:

```powershell
$logRoot = 'C:\ProgramData\DscOrchestrator\logs'
$currentRoot = 'C:\ProgramData\DscOrchestrator\current'
$run = Get-Content -LiteralPath (Join-Path $logRoot 'runs.jsonl') -Tail 1 | ConvertFrom-Json
$metadata = Get-Content -LiteralPath (Join-Path $currentRoot 'metadata.json') | ConvertFrom-Json
$run | Format-List outcome, failed_count, skipped_count, config_version, configuration_hash, group, role
$metadata | Format-List configuration_hash
Get-Content -LiteralPath (Join-Path $logRoot 'resources.jsonl') |
    ForEach-Object { $_ | ConvertFrom-Json } |
    Where-Object run_id -eq $run.run_id |
    Format-Table fragment, resource_name, result, in_desired_state, group, role, configuration_hash
```

You should see a successful `outcome`, `failed_count: 0`, `skipped_count: 0`, `group: advanced-example`, and `role: test-host`. The run's `configuration_hash` should match `current\metadata.json`. The resource rows should include `registry-base`, `machine-environment`, and `registry-verification` for that run.

To verify drift correction across all fragments, change one setting from each fragment in one Run Command, then force enforcement:

```powershell
$driftScript = @'
$sampleRoot = 'HKLM:\SOFTWARE\DscOrchestratorSampleAdvanced'
Remove-ItemProperty -LiteralPath $sampleRoot -Name Baseline -Force
[Environment]::SetEnvironmentVariable('DSC_ORCHESTRATOR_SAMPLE', 'wrong', 'Machine')
Set-ItemProperty -LiteralPath $sampleRoot -Name Verification -Value 'wrong'
Start-ScheduledTask -TaskName 'DscOrchestrator-Enforcement'
'@
Invoke-AzVMRunCommand -ResourceGroupName '<vm-resource-group>' -VMName '<windows-server-vm-name>' -CommandId RunPowerShellScript -ScriptString $driftScript
```

Wait for the new run record, then repeat the value and log checks above. You should see all desired values restored and the new run's `resources.jsonl` rows showing the drifted resources were changed.

## Undo the example

Before removing the VM Application assignment, run the package's `remove.ps1` in elevated PowerShell on the VM:

```powershell
$zip = Get-ChildItem 'C:\Packages\Plugins\Microsoft.CPlat.Core.VMApplicationManagerWindows\*\Downloads\dsc-orchestrator-advanced\1.0.1\*.zip' | Select-Object -First 1
$extractDir = Join-Path $env:TEMP 'dsc-orchestrator-remove'
New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
tar.exe -xf $zip.FullName -C $extractDir remove.ps1
& (Join-Path $extractDir 'remove.ps1')
Remove-Item -LiteralPath $extractDir -Recurse -Force
```

remove.ps1 unregisters the scheduled task and removes the `current` and `staging` folders. Logs are kept. Add `-Purge` to remove logs too.

Then remove the VM Application assignment from the VM using the Azure portal or your normal ARM workflow. Removing the assignment does not undo the configuration changes. In elevated PowerShell on the VM, remove the dedicated registry key created by `registry-base` and `registry-verification`, then clear the machine variable created by `machine-environment`:

```powershell
Remove-Item -LiteralPath 'HKLM:\SOFTWARE\DscOrchestratorSampleAdvanced' -Recurse -Force -ErrorAction SilentlyContinue
[Environment]::SetEnvironmentVariable('DSC_ORCHESTRATOR_SAMPLE', $null, 'Machine')
```

Removing the registry key undoes both registry fragments. Clearing the machine variable undoes `machine-environment`.
