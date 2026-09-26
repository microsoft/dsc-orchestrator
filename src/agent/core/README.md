# Agent core

This folder is reserved for OS-neutral agent logic. Today the agent lives in `src/agent/windows/`, because result emission in `Dsc.JsonLog.psm1` is coupled to Windows host identity, DSC result projection, and the Windows enforcement lifecycle.

The current run/resource result contract is platform-neutral and lives in [run-result.schema.json](../../core/contracts/run-result.schema.json). A later split can move the serializer behind that contract while leaving Windows scheduling, registry paths, and installation under `src/agent/windows/`.
