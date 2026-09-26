# Requesting a reboot

DSC resources must request a reboot rather than call `Restart-Computer` during a `Set`. The agent finishes the current operation, records its result and resume state, then performs the reboot while holding the enforcement mutex.

Import the packaged helper module and request the reboot:

```powershell
Import-Module DscOrchestrator.Reboot
Request-DscReboot -Kind Immediate -RequestedBy 'ExampleModule.Resource'
```

- `Immediate` requests a reboot after the current fragment completes and before later fragments run.
- `Eventual` lets reachable fragments finish and requests a coalesced reboot at the end of the run.
- `RequestedBy` is a stable identifier made of letters, digits, dots, underscores, or hyphens. Repeating a request with the same value overwrites only that requester's entry.

## Registry contract

The default root is `HKLM:\SOFTWARE\DscOrchestrator\Reboot`. The agent publishes the current run under `Context\` and resources write to their own subkey under `Requests\`:

```text
HKLM:\SOFTWARE\DscOrchestrator\Reboot\
  Context\
    EnforcementId  REG_SZ
    ConfigVersion  REG_SZ
    RunId          REG_SZ
  Requests\
    <RequestedBy>\
      Kind          REG_SZ       Immediate | Eventual
      RequestedBy   REG_SZ       Requester identifier
      EnforcementId REG_SZ       Value read from Context
      ConfigVersion REG_SZ       Value read from Context
      RunId         REG_SZ       Value read from Context
      RequestedAt   REG_SZ       ISO-8601 UTC
      Complete      REG_DWORD    1
```

The writer reads `Context` immediately before writing. On first write it creates the request key; on an update it clears `Complete` to `0`, writes all request fields, and writes `Complete = 1` last. `Complete = 1` is the commit marker. The agent ignores incomplete requests and requests whose enforcement/configuration context does not match the current run.

Do not modify `Context` or another requester's subkey. The agent clears the `Requests` inbox at the run boundary and owns restart-state persistence, retry limits, and the actual reboot.

## Custom registry root

The agent accepts `-RegistryRoot` during bootstrap and passes it to its scheduled run. `Invoke-Enforcement.ps1` also accepts the parameter directly. The agent sets `DSC_ORCHESTRATOR_REBOOT_REGISTRY_ROOT` for the DSC process; `Request-DscReboot` uses that value when `-RegistryRoot` is omitted. A resource can also pass `-RegistryRoot` explicitly, which must match the agent's configured root.
