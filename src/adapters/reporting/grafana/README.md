# DSC Orchestrator Grafana dashboard

The dashboard reads the Azure Monitor reporting tables and shows:

- Current VM and resource compliance, grouped by Group, Role, resource type, and fragment.
- Compliance trends and history, per-VM status, drift details, and run investigations.
- Bootstrap health, stage history, errors, and resource timing.
- VM inventory and tag counts from Azure Resource Graph.
- Optional module error and warning rows in the collapsed **Module logs (optional)** section. Module log collection must be enabled for this section to return data.

## Prerequisites

- Azure Managed Grafana with an Azure Monitor data source.
- The data source identity needs **Log Analytics Reader** on the workspace and **Reader** on the subscriptions used for Resource Graph inventory.
- The Azure Monitor reporting adapter must be deployed and writing the `Custom-DscOrchestrator_*` streams into the `DscOrchestrator_*_CL` tables.

## Set up Azure Managed Grafana

```powershell
az extension add --name amg
az grafana create --resource-group '<resource-group>' --name '<grafana-name>' --location '<azure-region>'
$grafanaPrincipalId = az grafana show --resource-group '<resource-group>' --name '<grafana-name>' --query identity.principalId -o tsv
New-AzRoleAssignment -ObjectId $grafanaPrincipalId -RoleDefinitionName 'Log Analytics Reader' -Scope '<workspace-resource-id>'
New-AzRoleAssignment -ObjectId $grafanaPrincipalId -RoleDefinitionName 'Reader' -Scope '/subscriptions/<subscription-id>'
```

- `az grafana create` makes the creator a Grafana Admin and adds the default "Azure Monitor" data source using the instance's managed identity.
- Creation takes about 4 minutes.
- The endpoint is shown by `az grafana show ... --query properties.endpoint -o tsv`.

## Import

**Grafana UI:** Open **Dashboards** -> **New** -> **Import**, upload `dsc-orchestrator-compliance-dashboard.json`, select the Azure Monitor data source, then import. In dashboard settings, set the hidden `la_resource_id` variable to the workspace resource ID and select the subscription for Resource Graph panels.

**Deploy script:** From this directory, run the script with your Grafana endpoint, workspace resource ID, and subscription:

```powershell
& .\Deploy-DscOrchestratorDashboard.ps1 `
  -GrafanaEndpoint '<grafana-endpoint>' `
  -LaWorkspaceResourceId '<workspace-resource-id>' `
  -SubscriptionId '<subscription-id>' `
  -DashboardUid '<dashboard-uid>' `
  -DashboardTitle '<dashboard-title>' `
  -DashboardFolderTitle '<folder-title>'
```

- The script needs Azure CLI signed in with the `amg` extension.
- It does not change your default subscription.
- The signed-in identity needs permission to update dashboards in the instance.
- It prints the dashboard URL as `<endpoint>/d/<dashboard-uid>/...`.

## Variables

Use **Subscription** and **Resource Group** to scope the inventory panels. **Group**, **Role**, **VM**, **Config Version**, **Resource Type**, **Fragment**, and **Compliance State** filter reporting data. **Run ID** and **Resource** narrow the investigation panels. The data source and workspace resource ID variables are hidden from the filter bar.
