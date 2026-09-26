# Run and resource JSONL results

[`run-result.schema.json`](run-result.schema.json) defines one JSON object per line in `runs.jsonl` or `resources.jsonl`. The agent writes UTF-8 without a BOM. Every row carries `schema_version: "3.0"`; the schema accepts exactly one run-result or resource-result shape.

The v1 contract keeps `TimeGenerated` and `Computer` in PascalCase and uses snake_case for the other wire fields. `group` and `role` are nullable caller metadata populated from optional `dsc-orchestrator.config.json` fields. `configuration_hash` is the package's lowercase SHA-256 configuration hash, populated from `metadata.json` and `null` when unavailable.

Schema 3.0 is the portable Orchestrator run/resource format. Consumers should use the schema-versioned fields; the agent does not emit legacy identity names. `bootstrap.jsonl` is installer diagnostics and is not covered by this run/resource schema.
