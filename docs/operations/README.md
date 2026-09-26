# Operations

The Windows agent installs under `C:\ProgramData\DscOrchestrator`, registers the `DscOrchestrator-Enforcement` task, and writes local JSONL logs under `logs`.

## Force an enforcement run

In an elevated PowerShell session on the VM, start the scheduled task:

```powershell
Start-ScheduledTask -TaskName 'DscOrchestrator-Enforcement'
```

## Local logs

The agent writes one JSON record per line to:

- `C:\ProgramData\DscOrchestrator\logs\runs.jsonl` — run summaries.
- `C:\ProgramData\DscOrchestrator\logs\resources.jsonl` — per-resource results.
- `C:\ProgramData\DscOrchestrator\logs\bootstrap.jsonl` — installation diagnostics.

Run and resource records include `group`, `role`, and `configuration_hash`.

See the [quickstart verification steps](../quickstart.md#step-6-verify-on-the-vm) for task checks and reading log entries. [Requesting a reboot](reboot-requests.md) explains how DSC resources ask the agent for a safe restart.
