# Package

`Save-DSCv3ResourceModules.ps1` stages the exact modules listed in `dsc-orchestrator.config.json`. Its default source is PSGallery; pass `-RepositoryUri` for a custom repository or `-LocalPath` for a local tree laid out as `<ModuleName>\<Version>\...`.

`Get-DSCv3Tool.ps1` downloads the pinned DSC CLI or PowerShell archive, checks its SHA-256 hash, and verifies the binary signer against `tools-signer-allowlist.json`. It returns an object containing the binary and extraction paths.

`New-DSCv3Package.ps1` validates fragments/modules and DSC schema, assembles the runtime and agent scripts, writes the package manifest and `metadata.json` sidecar, creates a root-layout ZIP, and returns package metadata. The sidecar includes the configuration hash and any configured group/role metadata. It has no ADO output-variable dependency. The stable ZIP and manifest contract is documented in [the package format](../../../docs/package-format/README.md) and [the manifest contract](../contracts/package-manifest.md).

The build-time `powershell-yaml` module must be available in the current PowerShell module path or staged module path. It is not bundled into the runtime ZIP.

Use [`build/New-DscOrchestratorPackage.ps1`](../../../build/New-DscOrchestratorPackage.ps1) to run composition, module staging, pinned runtime downloads, and packaging in one command.
