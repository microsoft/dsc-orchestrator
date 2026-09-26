# Shared core helpers

- `Dsc.OrchestratorConfig.psm1` validates and normalizes `dsc-orchestrator.config.json` for the composer and resource-module stager.
- `Dsc.JsonSchema.psm1` validates the repository contract schemas with Windows PowerShell 5.1-compatible `ConvertFrom-Json` logic.
- `Dsc.YamlLines.psm1` contains line-based YAML/resource helpers used by fragment composition and the Windows agent.

The Windows agent keeps a thin module shim at `src/agent/windows/Modules/Dsc.YamlLines.psm1`. Package assembly places the shared implementation under `AppModules/Shared/` so both the source tree and runtime ZIP load the same implementation.
