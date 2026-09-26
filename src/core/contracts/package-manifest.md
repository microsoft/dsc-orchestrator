# Package manifest contract

`manifest.json` is stored at the ZIP root and is the package identity and runtime-fragment contract. The Azure delivery adapter should read this file from the archive rather than infer a release from a filename, resource group, or cloud-specific name.

The builder validates the manifest against [package-manifest.schema.json](package-manifest.schema.json). Its `dsc-orchestrator.config.json` input is validated against [dsc-orchestrator-config.schema.json](dsc-orchestrator-config.schema.json).

## Required fields

| Field | Type | Meaning |
| --- | --- | --- |
| `schemaVersion` | string | Manifest schema; currently `1.0`. |
| `name` | string | Configuration/package identifier from `dsc-orchestrator.config.json`. |
| `version` | string | Package release version in `major.minor.patch` form. |
| `configurationHash` | string | Lowercase SHA-256 of rendered fragment names and content hashes. |
| `target.os` | string | `windows` for v1. |
| `target.architecture` | string | `x64` for v1. |
| `runtime.dscVersion` | string | Pinned DSC CLI version. |
| `runtime.powerShellVersion` | string | Pinned PowerShell runtime version. |
| `resourceModules` | array | Resource module names and the actual staged version-folder names included in `modules/`; versions may use three or four numeric components. |
| `agentModules` | array | Orchestrator support modules included in `modules/`. |
| `fragments` | array | Ordered fragment entries, including package-relative path, resource count, resource names, and optional `dependsOn`. |

`requiresRuntimeCapabilities` is optional and lists required agent capabilities, such as `fragmentDependencyGate`.

## Hash and path rules

1. Each rendered fragment is written as UTF-8 without a BOM at `configs/<name>/<name>.dsc.yaml`.
2. For each fragment in input declaration order, calculate SHA-256 over the bytes of that rendered file and format one line as `<fragment-name>:<lowercase-file-sha256>`.
3. Join those lines with a single LF (`\n`), without a trailing LF, encode the joined string as UTF-8 without a BOM, then calculate SHA-256. The lowercase result is `configurationHash`.
4. Every `fragments[].path` is slash-separated and relative to the ZIP root. It must point inside `configs/`.

The package builder fills `target`, `runtime`, and `agentModules` after the composer has written the intermediate manifest. It preserves fragment order and dependency metadata. `metadata.json` and `version.txt` are sidecars; delivery identity is always taken from `manifest.json`. `metadata.json` carries the configuration hash and optional configured `group` and `role` values for runtime result records.

Resource-module input versions may use `major.minor.patch` or `major.minor.patch.revision`. Staging compares numeric versions with missing components treated as zero, then reports and packages the actual directory name (for example, declared `2.12.0` may be staged and recorded as `2.12.0.0`). The manifest version therefore always names the directory present in the ZIP.

## Compatibility

Consumers should reject an unsupported `schemaVersion`, verify the archive's root manifest, and use `name`, `version`, and `configurationHash` as the package identity. Do not assume a cloud-specific delivery mechanism or a remote telemetry schema from this contract.
