# Contracts

- [dsc-orchestrator-config.schema.json](dsc-orchestrator-config.schema.json) defines the `dsc-orchestrator.config.json` builder input.
- [package-manifest.schema.json](package-manifest.schema.json) defines the root `manifest.json` consumed by delivery adapters; see [package-manifest.md](package-manifest.md) for hash and path rules.
- [run-result.schema.json](run-result.schema.json) defines each JSONL run or resource record; see [run-result.md](run-result.md) for field semantics and compatibility.

The PowerShell contract validator supports Windows PowerShell 5.1 and PowerShell 7 without `Test-Json`.
