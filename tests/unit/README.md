# Unit tests

Pester tests cover the core input/fragment contract, Windows bootstrap behavior, enforcement result projection, filtering, dependency gating, native DSC invocation, reboot handling, recovery, and reconciliation.

`Dsc.ContractSchema.Tests.ps1` and `Dsc.RunResultContract.Tests.ps1` pin the authoring/package JSON schemas and run/resource JSONL v3.0 output.

Each suite uses temporary files, fake native commands, or an isolated test registry provider rather than changing machine-wide runtime state. Run the full Pester suite through `tests/Invoke-PesterTests.ps1` or `build/Invoke-CI.ps1`.
