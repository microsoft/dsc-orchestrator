# Basic example

This sample uses DSC's built-in `Microsoft.Windows/Registry` resource to set:

`HKLM:\SOFTWARE\DscOrchestratorSample\ManagedBy` = `DSC Orchestrator sample`

The package does not need an additional resource module. See the [quickstart](../../docs/quickstart.md) to build, publish, deploy, and verify the sample.

## Check the value

On the target VM, open an elevated PowerShell session and run:

```powershell
(Get-ItemProperty -Path 'HKLM:\SOFTWARE\DscOrchestratorSample' -Name 'ManagedBy').ManagedBy
```

Expected output:

```text
DSC Orchestrator sample
```

## Undo the sample

After removing the VM Application assignment, remove the sample's dedicated registry key from elevated PowerShell:

```powershell
Remove-Item -LiteralPath 'HKLM:\SOFTWARE\DscOrchestratorSample' -Recurse -Force
```

This removes the sample configuration only; it does not remove Orchestrator from the VM.
