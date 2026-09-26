# DSC Orchestrator Azure Monitor reporting

This optional DSC Orchestrator adapter deploys Log Analytics custom tables, a Data Collection Endpoint, and a Data Collection Rule. The Azure Monitor Agent reads JSONL files written by the DSC Orchestrator agent and sends run, resource, and bootstrap records to the workspace.

## Prerequisites and permissions

- Windows PowerShell 5.1 or PowerShell 7 with Az.Accounts, Az.Resources, Az.Compute, and Az.Monitor
- A Log Analytics workspace and its full resource ID
- Monitoring Contributor or equivalent DCR, endpoint, and association read/write permissions on the resource groups being changed
- `Microsoft.Resources/deployments/*` permission on each resource group where a deployment runs
- Log Analytics Contributor or equivalent table-write permission on the workspace
- Virtual Machine Contributor or equivalent VM identity and extension permissions on the target VMs
- If the collection rule is in a separate scope, permission to read that rule when creating VM associations
- An active Az PowerShell context with the intended subscription selected. The scripts never sign in or switch subscriptions.

## Deploy and connect

Run these commands from `src\adapters\reporting\azure-monitor`, or use full script paths.

```powershell
$reporting = .\Deploy-DscOrchestratorReporting.ps1 `
    -ResourceGroupName '<monitoring-resource-group>' `
    -WorkspaceResourceId '<workspace-resource-id>' `
    -Location '<azure-region>' `
    -DcrName '<collection-rule-name>' `
    -DceName '<collection-endpoint-name>'

.\Connect-DscOrchestratorReporting.ps1 `
    -ResourceGroupName '<virtual-machine-resource-group>' `
    -DcrResourceId $reporting.DcrId `
    -VMNames @('<vm-name-1>', '<vm-name-2>')
```

Add `-WhatIf` to either command to show its planned changes. Omit `-VMNames` to target every VM in the resource group. An empty resource group is logged and skipped successfully.

To include module logs, add `-EnableModuleLogs -ModuleLogPath '<absolute-path-to-module-jsonl-file>'` to the deployment command. Module logs are off by default, and the file path must be supplied when they are enabled.

## Check for data

The Azure Monitor Agent reads the JSONL files directly. It only picks up lines written after it receives the collection rule, so existing results aren't sent. Force a run (`Start-ScheduledTask -TaskName 'DscOrchestrator-Enforcement'`) to produce new data. Ingestion usually takes 5–10 minutes.

Bootstrap rows appear only after the next install or update.

```kusto
DscOrchestrator_Runs_CL | take 10
DscOrchestrator_Resources_CL | take 10
DscOrchestrator_Bootstrap_CL | take 10
```

When module logs are enabled, check them with:

```kusto
DscOrchestrator_ModuleLogs_CL | take 10
```
