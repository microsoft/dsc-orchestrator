# Windows agent

The Windows agent installs and updates packages under `C:\ProgramData\DscOrchestrator`, registers the `DscOrchestrator-Enforcement` scheduled task, and runs enforcement with the bundled PowerShell 7 and DSC CLI.

- `Install-VmApplicationPackage.ps1` is the Azure VM Application ZIP entry point. It extracts the supplied archive with `tar.exe`, checks `manifest.json.version`, and invokes `bootstrap.ps1`.
- `bootstrap.ps1` accepts an already-extracted `-PackageRoot` and requires its root manifest version to match `-Version` before installation; it then installs modules, swaps the current runtime, and registers the scheduled task.
- `Run-Enforcement.ps1` launches the enforcement process. The agent accepts `-DscRoot`, `-LogDir`, `-TaskName`, `-RegistryRoot`, and `-AllUsersModulesPath` where applicable.
- `Modules/Dsc.RebootRequest.psm1` exports `Request-DscReboot`; the packaged `DscOrchestrator.Reboot` module is installed with the resource modules.
- The agent writes `runs.jsonl`, `resources.jsonl`, and `bootstrap.jsonl` under `<DscRoot>\logs`. Run and resource records follow the [schema 3.0 contract](../../core/contracts/run-result.md); bootstrap records are installer diagnostics. No remote reporting service is called.

The defaults are overridable for isolated installs and tests. Enforcement and host integration intentionally remain together in this directory; see [the agent-core split decision](../core/README.md).
