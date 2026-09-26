# Architecture overview

The repository separates package construction, host integration, and delivery:

- **Core (`src/core/`):** Read `dsc-orchestrator.config.json`, render and validate fragments, stage resource modules, and build versioned packages. Shared configuration and YAML-line helpers live in `src/core/shared/`.
- **Windows agent (`src/agent/windows/`):** Install and update package contents, register the scheduled task, run enforcement, handle reboot requests, and emit local JSONL.
- **Delivery (`src/adapters/delivery/azure-vmapp/`):** Azure VM Application publication and deployment are an adapter, not a core dependency.
- **Reporting:** The v1 agent writes local JSONL only. No Azure Monitor, DCR, Log Analytics, or Grafana ingestion is implemented here.

The Windows enforcement implementation lives under `src/agent/windows/`. A separate OS-neutral `src/agent/core/` is planned; see [its README](../../src/agent/core/README.md).

## Package contract

The input and produced ZIP layout are specified by the [package format](../package-format/README.md), [package manifest contract](../../src/core/contracts/package-manifest.md), and their JSON schemas in `src/core/contracts/`. The package manifest includes configuration identity and hash, target OS/architecture, DSC and PowerShell versions, resource modules, and ordered fragments. Delivery adapters should consume that manifest rather than infer package identity from cloud-specific names.

The v1 agent writes local JSONL using the portable [run/resource result contract](../../src/core/contracts/run-result.md), including optional `group` and `role` metadata and the package configuration hash.
